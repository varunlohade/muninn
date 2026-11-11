import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';

const script = new URL('../scripts/fake-server.ts', import.meta.url).pathname;

test('fake server: suggest, invoice, remind, refund and /_paid work with the fixed token and no network', async (t) => {
  const child = spawn(process.execPath, [script], { env: { ...process.env, PORT: '0', PAYPAL_ENV: '', NODE_ENV: '' }, stdio: ['ignore', 'pipe', 'inherit'] });
  t.after(() => child.kill());
  let out = '';
  child.stdout.setEncoding('utf8');
  while (!/127\.0\.0\.1:(\d+)/.test(out)) out += (await once(child.stdout, 'data'))[0];
  const base = `http://127.0.0.1:${/127\.0\.0\.1:(\d+)/.exec(out)![1]}`;
  let k = 0;
  const call = async (path: string, body?: unknown, action = false) => {
    const res = await fetch(base + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {
        'Content-Type': 'application/json', Authorization: 'Bearer pkd_fake',
        ...(action ? { 'X-User-Action': 'tap', 'Idempotency-Key': `fake-test-${++k}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: res.status, json: (await res.json()) as any };
  };

  const s = await call('/v1/suggest', { text: 'that is $45 for the haircut, sam@example.com' });
  assert.equal(s.status, 200);
  const invoice = s.json.chips.find((c: any) => c.kind === 'invoice');
  assert.ok(invoice, JSON.stringify(s.json));
  assert.equal(invoice.needs_confirm, true);
  const inv = await call('/v1/actions/invoice', { ...invoice.payload, confirm_recipient: invoice.payload.client_email, confirm_amount: invoice.payload.amount }, true);
  assert.equal(inv.status, 200);
  assert.match(inv.json.pay_link, /^https:\/\/paypal\.test\//);

  await call('/_next', { cls: { intent: 'send_reminder' } });
  const r = await call('/v1/suggest', { text: 'remind Jordan Ray about the color' });
  const remind = r.json.chips.find((c: any) => c.kind === 'remind');
  assert.ok(remind, JSON.stringify(r.json));
  assert.equal((await call('/v1/actions/remind', remind.payload, true)).json.ok, true);

  await call('/_next', { cls: { intent: 'refund' } });
  const f = await call('/v1/suggest', { text: 'refund Maya Lopez for the haircut' });
  const refund = f.json.chips.find((c: any) => c.kind === 'refund');
  assert.ok(refund, JSON.stringify(f.json));
  const ask = await call('/v1/actions/refund', refund.payload, true);
  assert.ok(ask.json.confirm_token);
  const done = await call('/v1/actions/refund', { confirm_token: ask.json.confirm_token }, true);
  assert.equal(done.json.status, 'COMPLETED');

  assert.equal((await call('/_paid/INV2-TEST-1', {})).status, 200);
  const pays = await call('/v1/payments');
  assert.equal(pays.json.payments.find((i: any) => i.id === 'INV2-TEST-1').state, 'paid');

  await call('/_next', { group: { group: 'info' }, route: { route: 'who_paid' } });
  const asked = await call('/v1/ask', { text: "who hasn't paid" }, true);
  assert.equal(asked.json.route, 'who_paid');
  assert.ok(asked.json.result.payments.length >= 3, JSON.stringify(asked.json));

  const log = (await call('/_log')).json;
  assert.deepEqual(log.requests[0], { method: 'POST', path: '/v1/suggest', status: 200, body: { text: 'that is $45 for the haircut, sam@example.com' } });
  assert.deepEqual(log.paypal.map((c: any) => c.fn), ['invoice', 'remind', 'refund']);

  await call('/_reset', {});
  assert.equal((await call('/_log')).json.requests.length, 0);
  assert.equal((await call('/v1/suggest', { text: 'hi' })).status, 200);
});

test('fake server: refuses to start for live PayPal or production', () => {
  for (const env of [{ PAYPAL_ENV: 'live' }, { NODE_ENV: 'production' }]) {
    const r = spawnSync(process.execPath, [script], { env: { ...process.env, PORT: '0', ...env }, encoding: 'utf8', timeout: 10_000 });
    assert.equal(r.status, 1, JSON.stringify(env));
    assert.match(r.stderr, /refuses to start/);
  }
});
