import { test } from 'node:test';
import assert from 'node:assert/strict';
import { moneyRequest, payoutAsk, saidAll } from '../src/quick.ts';
import { EVAL } from './natural-eval-data.ts';
import { setup } from './helpers.ts';

test('natural requests: every eval positive reads its amount with no model, and no negative is a request', () => {
  for (const b of EVAL) {
    for (const p of b.pos) assert.equal(moneyRequest(p.say)?.amount.toFixed(2), p.amount, p.say);
    for (const n of b.neg) assert.equal(moneyRequest(n), null, n);
  }
  for (const t of ['table for 2', 'party for 12 tonight', 'sending you 20 now', 'see you at 5', 'I paid 50 for lunch']) assert.equal(moneyRequest(t), null, t);
});

test('a reason never names what the owner did not type', () => {
  assert.equal(saidAll('Logo design', 'two screens for 50'), false);
  assert.equal(saidAll('two screens', 'two screens for 50'), true);
  assert.equal(saidAll('App screens', 'sam owes me 50 for the app screens'), true);
});

test('suggest: "two screens for 50" with a model that answers a catalog name gives the typed reason, not "Logo design"', async () => {
  const s = setup({ cls: { intent: 'none' }, ext: { item: 'Logo design', amount: 350, client_name: null } });
  const { token } = s.device();
  const out = await (await s.call(token, 'POST', '/v1/suggest', { text: 'two screens for 50' })).json();
  assert.deepEqual(out.chips.map((c: any) => [c.kind, c.payload.amount, c.payload.item]), [['paylink', '50.00', 'Two screens'], ['invoice', '50.00', 'Two screens']]);
  // A bare number is not a sure amount: the pay link takes a confirm.
  assert.equal(out.chips[0].needs_confirm, true);
  assert.ok(!s.aiCalls.some((c) => c.fn === 'classify'), 'no intent question for a plain request');
});

test('payouts: a bare number is enough once the sentence is a payout; a request to be paid never is', () => {
  assert.deepEqual(payoutAsk('pay Ritika 20'), { name: 'Ritika', amount: 20, currency: null, email: null, note: null });
  assert.deepEqual(payoutAsk('send $20 to Ritika'), { name: 'Ritika', amount: 20, currency: null, email: null, note: null });
  for (const t of ['send me 45 for the haircut', 'I paid 50 for lunch', 'sending you 20 now', 'pay joe 200 tomorrow']) assert.equal(payoutAsk(t), null, t);
});
