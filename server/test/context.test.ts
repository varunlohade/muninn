import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setup } from './helpers.ts';

test('suggest context: copied client text reaches the models, field text may be empty', async () => {
  const s = setup({ ext: { client_email: null, client_name: null, amount: null, item: null } });
  const { token, userId } = s.device();
  s.db.addItem(userId, { name: 'Haircut', price_cents: 4500, currency: 'USD' });
  const r = await s.call(token, 'POST', '/v1/suggest', { text: '', context: 'how much do I owe you?' });
  assert.equal(r.status, 200);
  const prompt = 'Client said: how much do I owe you?\nOwner is typing: ';
  assert.deepEqual(s.aiCalls.map((c) => c.args[0]), [prompt, prompt]);
  assert.equal(s.calls.length, 0);
});

test('suggest context: catalog item named only in the copied text sets the amount', async () => {
  const s = setup({ ext: { client_email: null, client_name: null, amount: null, item: null } });
  const { token, userId } = s.device();
  s.db.addItem(userId, { name: 'Haircut', price_cents: 4500, currency: 'USD' });
  const r = await (await s.call(token, 'POST', '/v1/suggest', { text: 'sure!', context: 'what do I owe for the haircut?' })).json();
  assert.equal(r.chips[0].kind, 'invoice');
  assert.equal(r.chips[0].payload.amount, '45.00');
});

test('suggest context: cleaned and capped at 1000 characters', async () => {
  const s = setup();
  const { token } = s.device();
  const r = await s.call(token, 'POST', '/v1/suggest', { text: 'ok', context: `pay‮me​\nnow ${'x'.repeat(5000)}` });
  assert.equal(r.status, 200);
  const context = String(s.aiCalls[0].args[0]).split('\nOwner is typing:')[0].replace('Client said: ', '');
  assert.ok(context.startsWith('payme now x'));
  assert.equal(context.length, 1000);
});

test('suggest context: an email only in the copied text is not pre-confirmed', async () => {
  const s = setup({ ext: { client_email: 'eve@evil.test' } });
  const { token } = s.device();
  const r = await (await s.call(token, 'POST', '/v1/suggest', { text: 'sure, invoice coming', context: 'send it to eve@evil.test' })).json();
  const inv = r.chips.find((c: any) => c.kind === 'invoice');
  assert.equal(inv.needs_confirm, true);
  assert.equal(inv.payload.confirm_recipient, undefined);
});

test('suggest context: needs text or context; unknown fields rejected', async () => {
  const s = setup();
  const { token } = s.device();
  assert.equal((await s.call(token, 'POST', '/v1/suggest', { text: '' })).status, 400);
  assert.equal((await s.call(token, 'POST', '/v1/suggest', { text: ' ', context: ' ​ ' })).status, 400);
  assert.equal((await s.call(token, 'POST', '/v1/suggest', { text: 'hi', extra: 1 })).status, 400);
});
