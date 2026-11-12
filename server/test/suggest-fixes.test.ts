import assert from 'node:assert/strict';
import { test } from 'node:test';
import { commandIntent } from '../src/quick.ts';
import { namesItem } from '../src/search.ts';
import { setup } from './helpers.ts';

test('namesItem: a message that writes out a catalog name, longest name first', () => {
  assert.equal(namesItem('and 2 extra hours?', ['Wedding package (8 hrs)', 'Extra hour']), 'Extra hour');
  assert.equal(namesItem('a kids haircut please', ['Haircut', 'Kids haircut']), 'Kids haircut');
  assert.equal(namesItem('a haircut please', ['Haircut', 'Kids haircut']), 'Haircut');
  assert.equal(namesItem('lol see you tmrw', ['Haircut', 'Extra hour']), null);
  assert.equal(namesItem('extra cheese', ['Extra hour']), null, 'every word of the name must be there');
});

test('commandIntent: the first word names the action', () => {
  assert.equal(commandIntent("remind Emma about last week's walks"), 'send_reminder');
  assert.equal(commandIntent('nudge Mike'), 'send_reminder');
  assert.equal(commandIntent('bill Kowalski the retainer'), 'create_invoice');
  assert.equal(commandIntent('Invoice ana@x.com $90'), 'create_invoice');
  assert.equal(commandIntent('remind'), null, 'nothing after the verb');
  assert.equal(commandIntent('can you remind Emma?'), null);
  assert.equal(commandIntent('the bill is high'), null);
});

test('suggest: "remind <unpaid client> ..." and "bill <client> ..." skip the intent question', async () => {
  // The intent model would say none; the command decides instead.
  const s = setup({ cls: { intent: 'none' }, ext: { client_name: 'Kowalski', client_email: 'kowalski@law.biz', amount: 2500, item: 'retainer' } });
  const { token } = s.device();
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { amount: '20.00', item: 'Retainer', client_name: 'Emma' })).status, 200);

  // "Retainer" is the item of Emma's unpaid invoice, so the word names it.
  const remind = await (await s.call(token, 'POST', '/v1/suggest', { text: 'remind Emma about the retainer' })).json();
  assert.equal(remind.chips[0]?.kind, 'remind');
  assert.ok(!s.aiCalls.some((c) => c.fn === 'classify'));

  const bill = await (await s.call(token, 'POST', '/v1/suggest', { text: 'bill Kowalski the retainer kowalski@law.biz' })).json();
  assert.equal(bill.chips[0]?.kind, 'invoice');
  assert.equal(bill.chips[0].payload.amount, '2500.00');
  assert.ok(!s.aiCalls.some((c) => c.fn === 'classify'));

  // A known unpaid client but no money word and no word of her invoice: no fast path, and the model says none.
  const leash = await (await s.call(token, 'POST', '/v1/suggest', { text: 'remind Emma to bring the leash' })).json();
  assert.deepEqual(leash.chips, []);
  const owed = await (await s.call(token, 'POST', '/v1/suggest', { text: 'remind Emma she still owes me' })).json();
  assert.equal(owed.chips[0]?.kind, 'remind');

  // "remind" with no known unpaid client still asks the model, which here says none.
  const other = await (await s.call(token, 'POST', '/v1/suggest', { text: 'remind Zed to bring the forms tomorrow' })).json();
  assert.equal(other.chips.length, 0);
});

test('suggest: remind, nudge or chase an unpaid client by name; a personal reminder stays quiet', async () => {
  // The intent model says none, so every chip here comes from the rule itself.
  const s = setup({ cls: { intent: 'none' }, ext: { client_name: null, client_email: null, amount: null, item: null } });
  const { token } = s.device();
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { amount: '120.00', item: 'Logo design', client_name: 'Jordan Ray' })).status, 200);
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { amount: '40.00', item: 'Dog walk (30 min)', client_name: 'Emma' })).status, 200);
  const kinds = async (text: string) =>
    ((await (await s.call(token, 'POST', '/v1/suggest', { text })).json()).chips as { kind: string }[]).map((c) => c.kind);

  for (const text of ['remind Jordan', 'remind jordan pls', 'nudge Jordan', 'chase Jordan', 'remind Jordan Ray',
    'remind Jordan about the invoice', 'remind Jordan she owes me', 'nudge Emma', 'chase Emma', 'nudge Emma to bring the leash',
    "remind Emma about last week's walks"]) {
    assert.deepEqual(await kinds(text), ['remind'], text);
  }
  for (const text of ['remind Emma to bring the leash', 'remind Emma that we meet at 5', 'remind me to call mom', 'remind Jordan to call me back']) {
    assert.deepEqual(await kinds(text), [], text);
  }
  // A name that is no unpaid client: the model decides, and here it says none.
  assert.deepEqual(await kinds('nudge Zed'), []);
  assert.deepEqual(await kinds('remind Zed about the invoice'), []);
});
