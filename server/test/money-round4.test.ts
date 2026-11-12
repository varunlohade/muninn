import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setup } from './helpers.ts';

type C = { kind: string; label: string; payload: Record<string, unknown>; needs_confirm: boolean };
type S = ReturnType<typeof setup>;

const unpaid = (s: S, userId: string, id: string, name: string) => s.db.insertInvoice({
  id, user_id: userId, status: 'SENT', amount_cents: 9000, currency: 'USD', item: 'x',
  client_name_enc: s.cipher.encrypt(userId, name), client_email_enc: null, pay_link: 'l', due_at: 0, created_at: 0,
});
const chipsOf = async (r: Response) => ((await r.json()).chips ?? []) as C[];

test('fix 1: a reminder with no client named gives no chip', async () => {
  const s = setup({ cls: { intent: 'send_reminder' }, ext: { client_name: null, amount: null, client_email: null } });
  const { userId, token } = s.device();
  unpaid(s, userId, 'INV-ANA', 'Ana');
  assert.deepEqual(await chipsOf(await s.call(token, 'POST', '/v1/suggest', { text: 'send a reminder' })), []);
  const stranger = await chipsOf(await s.call(token, 'POST', '/v1/suggest', { text: 'send a reminder', context: 'hey its Jordan, did you get my payment?' }));
  assert.deepEqual(stranger, [], 'Jordan has no unpaid invoice: no chip for Ana');
  unpaid(s, userId, 'INV-JOR', 'Jordan');
  const jordan = await chipsOf(await s.call(token, 'POST', '/v1/suggest', { text: 'send a reminder', context: 'hey its Jordan, did you get my payment?' }));
  assert.deepEqual(jordan.map((c) => [c.kind, c.payload.invoice_id, c.needs_confirm]), [['remind', 'INV-JOR', true]]);
});

test('fix 1: a name the model guessed but nobody typed gives no chip', async () => {
  const s = setup({ cls: { intent: 'send_reminder' }, ext: { client_name: 'Ana', amount: null, client_email: null } });
  const { userId, token } = s.device();
  unpaid(s, userId, 'INV-ANA', 'Ana');
  unpaid(s, userId, 'INV-SAM', 'Sam');
  assert.deepEqual(await chipsOf(await s.call(token, 'POST', '/v1/suggest', { text: 'remind her' })), []);
});

test('fix 1: a refund with no client named gives no chip', async () => {
  const s = setup({ cls: { intent: 'refund' }, ext: { client_name: null, amount: null, client_email: null } });
  const { userId, token } = s.device();
  s.db.insertInvoice({ id: 'INV-P', user_id: userId, status: 'PAID', amount_cents: 9000, currency: 'USD', item: 'x', client_name_enc: s.cipher.encrypt(userId, 'Bo'), client_email_enc: null, pay_link: 'l', due_at: 0, created_at: 0 });
  s.db.setInvoiceStatus(userId, 'INV-P', 'PAID', 1, 'CAP-1');
  assert.deepEqual(await chipsOf(await s.call(token, 'POST', '/v1/suggest', { text: 'refund her please' })), []);
});

test('fix 1: every reminder chip asks first, and the server needs the client confirmed', async () => {
  const s = setup({ cls: { intent: 'send_reminder' } });
  const { userId, token } = s.device();
  unpaid(s, userId, 'INV-ANA', 'Ana');
  const [c] = await chipsOf(await s.call(token, 'POST', '/v1/suggest', { text: 'remind Ana about the invoice' }));
  assert.equal(c.kind, 'remind');
  assert.equal(c.needs_confirm, true);
  assert.equal(c.payload.client_name, 'Ana');
  const none = await s.call(token, 'POST', '/v1/actions/remind', { invoice_id: 'INV-ANA' });
  assert.equal(none.status, 409);
  assert.equal((await none.json()).needs_confirm, true);
  assert.equal((await s.call(token, 'POST', '/v1/actions/remind', { invoice_id: 'INV-ANA', confirm_client: 'Sam' })).status, 409);
  assert.equal(s.calls.filter((x) => x.fn === 'remind').length, 0);
  assert.equal((await s.call(token, 'POST', '/v1/actions/remind', { invoice_id: 'INV-ANA', confirm_client: 'Ana' })).status, 200);
  assert.equal(s.calls.filter((x) => x.fn === 'remind').length, 1);
});

test('fix 2: a pay link whose amount the model did not read takes a confirm', async () => {
  for (const text of ['pay link for the haircut, half off', 'pay link haircut $45 waived', 'pay link haircut $45 already covered']) {
    const s = setup({ cls: { intent: 'pay_link' }, ext: { client_name: null, client_email: null, amount: null, item: 'haircut' } });
    const { userId, token } = s.device();
    const link = (await chipsOf(await s.call(token, 'POST', '/v1/suggest', { text }))).find((c) => c.kind === 'paylink');
    if (link) assert.equal(link.needs_confirm, true, text);
  }
});

test('fix 5: the invoice confirm checks the currency too', async () => {
  const s = setup();
  const { token } = s.device();
  const base = { amount: '45', currency: 'GBP', item: 'x', client_email: 'a@x.com', confirm_recipient: 'a@x.com', confirm_amount: 45 };
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', base)).status, 409);
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { ...base, confirm_currency: 'USD' })).status, 409);
  assert.equal(s.calls.length, 0);
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { ...base, confirm_currency: 'GBP' })).status, 200);
});

test('fix 6: two typed emails pre-fill no email', async () => {
  const s = setup({ cls: { intent: 'create_invoice' }, ext: { client_name: 'Sam', client_email: 'ana@x.com', amount: 45 } });
  const { userId, token } = s.device();
  unpaid(s, userId, 'INV-SAM', 'Sam');
  const inv = (await chipsOf(await s.call(token, 'POST', '/v1/suggest', { text: 'invoice sam@x.com $45 haircut, not ana@x.com' }))).find((c) => c.kind === 'invoice')!;
  assert.equal(inv.payload.client_email, null);
  assert.equal(inv.needs_confirm, true);
});
