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
