import { test } from 'node:test';
import assert from 'node:assert/strict';
import { paidEvent, setup, subscriptionPaidEvent, webhookHeaders } from './helpers.ts';

const HOOK = 'https://hooks.slack.com/services/T000AAA/B000BBB/abcDEF123secret';

/** Stubs fetch for Slack posts. `answer` is the reply per post: a status code or an Error to throw. */
function stubFetch(answer: () => number | Error = () => 200) {
  const posts: { url: string; body: any }[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    posts.push({ url: String(url), body: JSON.parse(String(init.body)) });
    const a = answer();
    if (a instanceof Error) throw a;
    return new Response('ok', { status: a });
  }) as typeof fetch;
  return { posts, restore: () => { globalThis.fetch = real; } };
}

async function logsOf(fn: () => Promise<void>) {
  const lines: any[] = [];
  const real = console.log;
  console.log = (l: string) => { lines.push(JSON.parse(l)); };
  process.env.LOG_SILENT = '';
  try {
    await fn();
  } finally {
    console.log = real;
    process.env.LOG_SILENT = '1';
  }
  return lines;
}

test('slack: only a Slack incoming webhook URL is accepted; it is stored encrypted and never sent back', async () => {
  const s = setup();
  const a = s.device();
  const put = (webhook_url: unknown) => s.call(a.token, 'PUT', '/v1/integrations/slack', { webhook_url });
  for (const bad of [
    'http://hooks.slack.com/services/T1/B1/abc', 'https://hooks.slack.com.evil.test/services/T1/B1/abc', 'https://evil.test/services/T1/B1/abc',
    'https://hooks.slack.com/workflows/T1/B1/abc', 'https://hooks.slack.com/services/T1/B1/abc?x=1', 'https://hooks.slack.com/services/T1/B1',
    'https://user@hooks.slack.com/services/T1/B1/abc', 'https://hooks.slack.com:444/services/T1/B1/abc', '', 42,
  ]) assert.equal((await put(bad)).status, 400, String(bad));
  assert.equal((await s.call(a.token, 'PUT', '/v1/integrations/slack', { webhook_url: HOOK, extra: 1 })).status, 400);
  assert.equal((await s.call(null, 'PUT', '/v1/integrations/slack', { webhook_url: HOOK })).status, 401);

  const r = await put(HOOK);
  assert.equal(r.status, 200);
  const text = await r.text();
  assert.ok(!text.includes('hooks.slack.com') && !text.includes('secret'));
  assert.equal(JSON.parse(text).integration.status, 'connected');
  const row = s.db.listIntegrations(a.userId).find((x) => x.provider === 'slack')!;
  assert.ok(!row.config_enc!.includes('hooks.slack'));
  assert.match(s.cipher.decrypt(a.userId, row.config_enc!), /hooks\.slack\.com/);
  const list = await (await s.call(a.token, 'GET', '/v1/integrations')).text();
  assert.ok(!list.includes('hooks.slack.com'));

  assert.equal((await put(null)).status, 200);
  assert.equal(s.db.listIntegrations(a.userId).find((x) => x.provider === 'slack')!.config_enc, null);
});

test('slack: a paid invoice, order or repeat bill posts first name, amount and item once, never the email', async () => {
  const s = setup();
  const a = s.device(), b = s.device();
  const { posts, restore } = stubFetch();
  try {
    await s.call(a.token, 'PUT', '/v1/integrations/slack', { webhook_url: HOOK });
    const inv = await (await s.call(a.token, 'POST', '/v1/actions/invoice', {
      amount: 90, currency: 'USD', item: 'Haircut', client_name: 'Ana Lopez', client_email: 'ana@example.com',
      confirm_amount: 90, confirm_currency: 'USD', confirm_recipient: 'ana@example.com',
    })).json() as any;
    const hook = (event: unknown) => s.call(null, 'POST', '/webhooks/paypal', event, webhookHeaders);
    assert.equal((await hook(paidEvent(inv.id))).status, 200);
    assert.equal((await hook(paidEvent(inv.id))).status, 200);
    assert.deepEqual(posts, [{ url: HOOK, body: { text: 'Ana paid $90 · Haircut' } }]);
    assert.ok(!JSON.stringify(posts).includes('ana@example.com'));

    const order = await (await s.call(a.token, 'POST', '/v1/actions/paylink', { amount: 35, item: 'Blowout <b>' })).json() as any;
    await hook({ event_type: 'CHECKOUT.ORDER.APPROVED', resource: { id: order.id } });
    await hook({ event_type: 'PAYMENT.CAPTURE.COMPLETED', resource: { id: 'CAP1', supplementary_data: { related_ids: { order_id: order.id } } } });
    assert.deepEqual(posts.slice(1).map((p) => p.body.text), ['A client paid $35 · Blowout &lt;b&gt;']);

    await s.call(a.token, 'POST', '/v1/actions/subscribe', {
      amount: 40, interval: 'month', item: 'Color', client_name: 'Sam', confirm_amount: 40, confirm_currency: 'USD', confirm_interval: 'month',
    });
    const subId = s.db.listSubscriptions(a.userId)[0].id;
    await hook(subscriptionPaidEvent(subId, 'SALE-1'));
    await hook(subscriptionPaidEvent(subId, 'SALE-1'));
    await hook(subscriptionPaidEvent(subId, 'SALE-2'));
    assert.deepEqual(posts.slice(2).map((p) => p.body.text), ['Sam paid $40 · Color', 'Sam paid $40 · Color']);

    // B never connected Slack: no post.
    const binv = await (await s.call(b.token, 'POST', '/v1/actions/invoice', { amount: 10, item: 'Trim', client_name: 'Bo' })).json() as any;
    await hook(paidEvent(binv.id));
    assert.equal(posts.length, 4);
  } finally {
    restore();
  }
});

test('slack: a failed post is logged with its reason, tried once, and the PayPal event still succeeds', async () => {
  const s = setup();
  const a = s.device();
  let answer: number | Error = 404;
  const { posts, restore } = stubFetch(() => answer);
  try {
    await s.call(a.token, 'PUT', '/v1/integrations/slack', { webhook_url: HOOK });
    const pay = async () => {
      const inv = await (await s.call(a.token, 'POST', '/v1/actions/invoice', { amount: 20, item: 'Trim', client_name: 'Ana' })).json() as any;
      const r = await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv.id), webhookHeaders);
      assert.equal(r.status, 200);
      assert.equal((await r.json() as any).handled, true);
      assert.equal(s.db.getInvoice(a.userId, inv.id)!.status, 'PAID');
    };
    const httpLogs = await logsOf(pay);
    answer = Object.assign(new TypeError('fetch failed'), { cause: { code: 'ENOTFOUND' } });
    const netLogs = await logsOf(pay);
    assert.equal(posts.length, 2);
    const failed = [...httpLogs, ...netLogs].filter((l) => l.event === 'slack_notify_failed');
    assert.deepEqual(failed.map((l) => l.reason), ['HTTP 404', 'ENOTFOUND']);
    assert.ok(!JSON.stringify([...httpLogs, ...netLogs]).includes('hooks.slack.com'));
  } finally {
    restore();
  }
});
