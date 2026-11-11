import { test } from 'node:test';
import assert from 'node:assert/strict';
import { payoutAsk } from '../src/quick.ts';
import { paidEvent, setup, webhookHeaders } from './helpers.ts';

const suggest = async (s: ReturnType<typeof setup>, token: string, text: string, context?: string) =>
  (await (await s.call(token, 'POST', '/v1/suggest', { text, ...(context ? { context } : {}) })).json()) as { chips: any[]; intent: string };

// ---- step 0: copy fixes

test('copy: "pay joe $200" is a payout phrase, never a pay link, and costs no model call', async () => {
  const s = setup({ cls: { intent: 'pay_link' } });
  const { token } = s.device();
  for (const text of ['pay joe $200', 'send my supplier joe $200 joe@x.com', 'send $200 to joe']) {
    const out = await suggest(s, token, text);
    assert.equal(out.chips.some((c) => c.kind === 'paylink' || c.kind === 'invoice'), false, text);
  }
  assert.equal(s.aiCalls.length, 0);
  const ask = await (await s.call(token, 'POST', '/v1/ask', { text: 'pay joe $200' })).json();
  assert.equal(ask.route, 'action');
  assert.equal(s.aiCalls.length, 0);
});

test('copy: payoutAsk reads name, amount and typed email; requests to be paid are not payouts', () => {
  assert.deepEqual(payoutAsk('pay my supplier joe $200 joe@x.com'), { name: 'Joe', amount: 200, currency: null, email: 'joe@x.com' });
  assert.deepEqual(payoutAsk('send $200 to joe'), { name: 'Joe', amount: 200, currency: null, email: null });
  for (const t of ['pay me $45', 'send sam a $45 invoice', 'send you the $45 link', 'pay joe', 'can you pay $45 by friday']) assert.equal(payoutAsk(t), null, t);
});

test('copy: reminder chip says Nudge and owed; who-owes chip; refund confirm says it cannot be undone', async () => {
  const s = setup({ cls: { intent: 'send_reminder' } });
  const { token } = s.device();
  await s.call(token, 'POST', '/v1/actions/invoice', { amount: 90, item: 'Color', client_name: 'Ana' });
  const remind = await suggest(s, token, 'remind ana');
  assert.equal(remind.chips[0].label, 'Nudge Ana · $90 owed');

  const who = setup({ cls: { intent: 'payment_status' } });
  const w = who.device();
  assert.equal((await suggest(who, w.token, 'who paid me')).chips[0].label, 'Who owes you · 0 unpaid');

  const inv = await (await s.call(token, 'POST', '/v1/actions/invoice', { amount: 20, item: 'Trim', client_name: 'Sam' })).json();
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv.id), webhookHeaders);
  const step1 = await (await s.call(token, 'POST', '/v1/actions/refund', { id: inv.id })).json();
  assert.equal(step1.summary, "Refund $20 to Sam? Can't undo.");
});

test('copy: ask with no match gives the neutral hint line with every verb', async () => {
  const s = setup();
  const { token } = s.device();
  const out = await (await s.call(token, 'POST', '/v1/ask', { text: 'hi' })).json();
  assert.equal(out.result.line, 'Try: invoice Sam $45 · nudge Ana · refund Sam $20 · who owes me');
});

// ---- step 1: repeat bills

async function plan(s: ReturnType<typeof setup>, token: string, name: string, email: string, amount = 40, interval = 'month') {
  const sub = await (await s.call(token, 'POST', '/v1/actions/subscribe', {
    amount, interval, client_name: name, client_email: email, confirm_amount: amount, confirm_currency: 'USD', confirm_interval: interval, confirm_recipient: email,
  })).json();
  return sub.id as string;
}
const send = async (s: ReturnType<typeof setup>, token: string, path: string, body: unknown, key?: string) => {
  const res = await s.call(token, 'POST', path, body, key ? { 'Idempotency-Key': key } : {});
  return { status: res.status, json: (await res.json()) as any };
};
const confirmed = (ch: any) => ({ ...ch.payload.body, ...ch.payload.confirm });

test('plans: "what plans do I have" lists them in one line, active count on the chip, no model call', async () => {
  const s = setup();
  const A = s.device();
  const ana = await plan(s, A.token, 'Ana', 'ana@x.com');
  await plan(s, A.token, 'Ben', 'ben@x.com', 20, 'week');
  await plan(s, A.token, 'Cy', 'cy@x.com', 90, 'year');
  s.db.setSubscriptionActive(A.userId, ana, Date.now());
  const out = await suggest(s, A.token, 'what plans do I have');
  assert.equal(out.chips.length, 1);
  assert.equal(out.chips[0].label, 'Repeat bills · 1 active');
  assert.equal(out.chips[0].payload.line, 'Ana $40/mo, Cy $90/yr waiting +1');
  assert.equal(s.aiCalls.length, 0);
  const B = s.device();
  assert.equal((await suggest(s, B.token, 'my plans')).chips[0].label, 'Repeat bills · none yet', 'B never sees A plans');
});

test('plans: pause asks first, checks client, amount and currency, runs once per key, and offers Undo', async () => {
  const s = setup();
  const { token, userId } = s.device();
  const id = await plan(s, token, 'Ana', 'ana@x.com');
  s.db.setSubscriptionActive(userId, id, Date.now());
  const [ch] = (await suggest(s, token, "pause ana's plan")).chips;
  assert.equal(ch.kind, 'plan_pause');
  assert.equal(ch.label, 'Pause $40/mo · Ana');
  assert.equal(ch.needs_confirm, true);
  assert.equal(ch.payload.question, "Pause Ana's $40 monthly bill? PayPal tells Ana.");

  const bare = await send(s, token, '/v1/actions/plan/pause', ch.payload.body);
  assert.equal(bare.status, 409);
  assert.equal(bare.json.needs_confirm, true);
  for (const wrong of [{ confirm_client: 'Ben' }, { confirm_amount: '41.00' }, { confirm_currency: 'EUR' }]) {
    assert.equal((await send(s, token, '/v1/actions/plan/pause', { ...confirmed(ch), ...wrong })).status, 409, JSON.stringify(wrong));
  }
  assert.equal(s.calls.filter((c) => c.fn === 'change_subscription').length, 0, 'nothing reaches PayPal before a matching confirm');

  const done = await send(s, token, '/v1/actions/plan/pause', confirmed(ch), 'pause-key-0001');
  assert.equal(done.status, 200);
  assert.equal(done.json.line, 'Paused ✓');
  assert.equal(done.json.undo.kind, 'plan_resume');
  const again = await send(s, token, '/v1/actions/plan/pause', confirmed(ch), 'pause-key-0001');
  assert.deepEqual(again.json, done.json, 'same key replays the stored answer');
  assert.deepEqual(s.calls.filter((c) => c.fn === 'change_subscription').map((c) => c.args.slice(0, 2)), [[id, 'suspend']]);
  assert.equal(s.db.getSubscription(userId, id)!.status, 'SUSPENDED');

  const undone = await send(s, token, '/v1/actions/plan/resume', done.json.undo.payload.body);
  assert.equal(undone.status, 200);
  assert.equal(undone.json.line, 'Restarted ✓');
  assert.equal(undone.json.undo, null);
  assert.equal(s.db.getSubscription(userId, id)!.status, 'ACTIVE');
});

test('plans: another user cannot pause, resume or read a plan; PayPal state wins over a stale row', async () => {
  const s = setup();
  const A = s.device();
  const id = await plan(s, A.token, 'Ana', 'ana@x.com');
  s.db.setSubscriptionActive(A.userId, id, Date.now());
  const [ch] = (await suggest(s, A.token, 'pause ana')).chips;
  const B = s.device();
  assert.equal((await send(s, B.token, '/v1/actions/plan/pause', confirmed(ch))).status, 404);
  assert.equal((await s.call(B.token, 'GET', `/v1/plans/${id}`)).status, 404);
  assert.equal(s.calls.some((c) => c.fn === 'change_subscription' || c.fn === 'get_subscription'), false);

  s.subStatus.set(id, 'SUSPENDED');
  const stale = await send(s, A.token, '/v1/actions/plan/pause', confirmed(ch));
  assert.equal(stale.status, 409);
  assert.equal(s.db.getSubscription(A.userId, id)!.status, 'SUSPENDED', 'the row now matches PayPal');
  const read = await (await s.call(A.token, 'GET', `/v1/plans/${id}`)).json();
  assert.equal(read.line, 'Ana $40/mo · paused');
});

test('plans: end needs a plan word and says it cannot be undone; a plan waiting for approval gets only a line', async () => {
  const s = setup({ cls: { intent: 'none' } });
  const { token, userId } = s.device();
  const id = await plan(s, token, 'Ana', 'ana@x.com');
  assert.equal((await suggest(s, token, "pause ana's plan")).chips[0].kind, 'show');
  s.db.setSubscriptionActive(userId, id, Date.now());
  const [end] = (await suggest(s, token, "stop ana's plan for good")).chips;
  assert.equal(end.kind, 'plan_cancel');
  assert.equal(end.payload.question, "End Ana's $40 monthly bill? Can't undo.");
  const done = await send(s, token, '/v1/actions/plan/cancel', confirmed(end));
  assert.equal(done.json.line, 'Ended ✓');
  assert.equal(done.json.undo, null);
  assert.equal((await suggest(s, token, 'stop by at 3 ana')).chips.some((c) => c.kind === 'plan_cancel'), false);
  assert.equal((await suggest(s, token, "how is ana's plan")).chips.length, 0, 'an ended plan is no longer open');
});
