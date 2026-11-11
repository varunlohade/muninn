import { test } from 'node:test';
import assert from 'node:assert/strict';
import { quick } from '../src/quick.ts';
import { setup } from './helpers.ts';

const RATES = [
  'invoice bob@x.com $45x3 haircut', 'three haircuts at $45', '$45/hr for 3 hours', '$45 * 3', '$45 times 3',
  '$45 an hour', '$45/mo for 12 months', '$45 for 2 people', 'invoice bob@x.com 3 haircuts, $45 each',
];

test('rule A: a rate, a multiplier or a second number gives no regex amount', () => {
  for (const t of RATES) assert.equal(quick(t).amount, null, t);
  for (const t of ['$45 for a dozen', '$45 for two', '$45 x 3', '$45 ea', '$45 per person', '$45/h', '45 dollars a month', '$45 for 4 pax']) {
    assert.equal(quick(t).amount, null, t);
  }
  assert.equal(quick('invoice bob@x.com $45 haircut').amount, 45, 'one number and no rate is still a regex amount');
  assert.equal(quick('$1,200.50 for the shoot').amount, 1200.5);
  assert.equal(quick('invoice bob2@x.com $45 haircut').amount, 45, 'digits inside an email are not a number');
});

test('rule B: each rate input ends as an unsure invoice that shows the model total', async () => {
  for (const text of RATES) {
    const s = setup({ ext: { amount: 135, client_email: 'bob@x.com', item: 'haircut' } });
    const { token } = s.device();
    const r = await (await s.call(token, 'POST', '/v1/suggest', { text })).json();
    const inv = r.chips.find((c: { kind: string }) => c.kind === 'invoice');
    assert.equal(inv.payload.amount, '135.00', text);
    assert.equal(inv.needs_confirm, true, text);
    assert.equal(inv.payload.confirm_recipient, undefined, text);
    assert.equal(r.chips.find((c: { kind: string }) => c.kind === 'paylink').needs_confirm, true, `${text}: pay link too`);
  }
});

test('rule C: every emailed invoice needs confirm_recipient and confirm_amount, known client or not', async () => {
  const s = setup();
  const { token } = s.device();
  const body = { amount: 45, item: 'Haircut', client_email: 'bob@x.com' };
  const send = (b: object) => s.call(token, 'POST', '/v1/actions/invoice', b);
  const r = await send({ ...body, confirm_recipient: 'bob@x.com' });
  assert.equal(r.status, 409, 'a recipient confirm alone is not enough');
  assert.deepEqual(await r.json(), { error: 'confirm the amount and recipient', needs_confirm: true, recipient: 'bob@x.com', amount: '45.00', currency: 'USD' });
  assert.equal((await send({ ...body, confirm_recipient: 'bob@x.com', confirm_amount: 4.5 })).status, 409, 'a different amount is refused');
  assert.equal((await send({ ...body, confirm_amount: 45 })).status, 409);
  assert.equal(s.calls.length, 0);
  assert.equal((await send({ ...body, confirm_recipient: 'bob@x.com', confirm_amount: '45.00' })).status, 200);
  assert.equal((await send(body)).status, 409, 'a known client still needs the confirm');
  assert.equal((await send({ ...body, confirm_recipient: 'bob@x.com' })).status, 409);
  assert.equal(s.calls.length, 1);
});

test('rule C: a suggested invoice with a typed email always needs a confirm', async () => {
  const s = setup();
  const { token } = s.device();
  await s.call(token, 'POST', '/v1/catalog', { name: 'Haircut', price: 45 });
  const r = await (await s.call(token, 'POST', '/v1/suggest', { text: '$45 for the haircut, sam@example.com' })).json();
  assert.equal(r.chips[0].needs_confirm, true);
  assert.equal(r.chips[0].payload.confirm_recipient, undefined);
});

test('rule E: Idempotency-Lookup returns the stored answer or 404, and never runs the action', async () => {
  const s = setup();
  const { token } = s.device();
  const body = { amount: 45, item: 'Haircut', client_email: 'bob@x.com', confirm_recipient: 'bob@x.com', confirm_amount: 45 };
  const look = { 'Idempotency-Key': 'pending-key-1', 'Idempotency-Lookup': '1' };
  for (const path of ['/v1/actions/invoice', '/v1/actions/paylink', '/v1/actions/remind', '/v1/actions/refund']) {
    const b = path.endsWith('invoice') ? body : path.endsWith('paylink') ? { amount: 45, item: 'Haircut' } : path.endsWith('remind') ? { invoice_id: 'INV-1' } : { id: 'INV-1' };
    assert.equal((await s.call(token, 'POST', path, b, look)).status, 404, path);
    assert.equal((await s.call(token, 'POST', path, b, { ...look, 'X-User-Action': '' })).status, 404, `${path}: a lookup needs no tap`);
  }
  assert.equal(s.calls.length, 0, 'a lookup never reaches PayPal');
  const sent = await s.call(token, 'POST', '/v1/actions/invoice', body, { 'Idempotency-Key': 'pending-key-1' });
  assert.equal(sent.status, 200);
  const stored = await sent.json();
  const again = await s.call(token, 'POST', '/v1/actions/invoice', body, look);
  assert.equal(again.status, 200);
  assert.deepEqual(await again.json(), stored);
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { ...body, amount: 46, confirm_amount: 46 }, look)).status, 404, 'another body is not this request');
  assert.equal(s.calls.length, 1);
});
