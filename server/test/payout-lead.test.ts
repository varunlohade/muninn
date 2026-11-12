import { test } from 'node:test';
import assert from 'node:assert/strict';
import { payoutAsk } from '../src/quick.ts';

test('payout: a short lead-in and an -ing verb still read as a payout', () => {
  for (const [t, name, amount] of [['Cool sending palak $40', 'Palak', 40], ["ok I'll send ritika 20", 'Ritika', 20], ['let me pay joe $50', 'Joe', 50], ["I'm sending sam $25 for tiles", 'Sam', 25]] as const) {
    const p = payoutAsk(t);
    assert.equal(p?.name, name, t);
    assert.equal(p?.amount, amount, t);
  }
});

test('payout: past tense, "you", "me", "it" and invoice words never read as a payout', () => {
  for (const t of ['sent palak $40', 'I paid 50 for lunch', 'send me 45', 'sending you 20 now', 'cool sending it $40', 'sending palak the invoice $40']) {
    assert.equal(payoutAsk(t), null, t);
  }
});
