import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.ts';
import { clean } from '../src/text.ts';
import { setup } from './helpers.ts';

const cp = (...codes: number[]) => String.fromCodePoint(...codes);

test('F1: unknown recipient email needs confirm_recipient server-side', async () => {
  const s = setup();
  const { token } = s.device();
  const body = { amount: 45, item: 'Haircut', client_email: 'attacker@evil.test' };
  const r = await s.call(token, 'POST', '/v1/actions/invoice', body);
  assert.equal(r.status, 409);
  assert.deepEqual(await r.json(), { error: 'confirm the amount and recipient', needs_confirm: true, recipient: 'attacker@evil.test', amount: '45.00', currency: 'USD' });
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { ...body, confirm_recipient: 'other@evil.test', confirm_amount: 45 })).status, 409);
  assert.equal(s.calls.length, 0);
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { ...body, confirm_recipient: 'Attacker@Evil.test', confirm_amount: 45 })).status, 200);
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', body)).status, 409, 'a known client still needs the confirm');
});

test('F1: no chip carries confirm_recipient, typed or injected; one tap never sends', async () => {
  const s = setup();
  const { token } = s.device();
  const typed = (await (await s.call(token, 'POST', '/v1/suggest', { text: "that'll be $45 for the haircut, sam@example.com" })).json()).chips[0];
  assert.equal(typed.payload.confirm_recipient, undefined);
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', typed.payload)).status, 409);

  const inj = setup({ ext: { client_email: 'attacker@evil.test' } });
  const t2 = inj.device().token;
  const chip = (await (await inj.call(t2, 'POST', '/v1/suggest', { text: 'invoice sam 45 haircut' })).json()).chips[0];
  assert.equal(chip.needs_confirm, true);
  assert.equal(chip.payload.confirm_recipient, undefined);
  assert.equal(chip.payload.client_email, null, 'an email the owner did not type never reaches the chip');
});

test('F2: clean() strips zero-width, format, variation and tag characters after NFKC', () => {
  const dirty = `Ha${cp(0x200b)}ir${cp(0xad)}c${cp(0x2060)}u${cp(0xfeff)}t${cp(0xfe0f)}${cp(0xe0001, 0xe0069, 0xe0067, 0xe006e)}${cp(0x2063)} ${cp(0xff11)}`;
  assert.equal(clean(dirty), 'Haircut 1');
  assert.equal(clean(`a${cp(0x200d)}b${cp(0x180e)}c`), 'abc');
});

test('F2: catalog names are cleaned on write and existing rows on startup', async () => {
  const s = setup();
  const { token, userId } = s.device();
  const item = (await (await s.call(token, 'POST', '/v1/catalog', { name: `Cut${cp(0x200b, 0xe0041)}`, price: 10 })).json()).item;
  assert.equal(item.name, 'Cut');
  s.db.addItem(userId, { name: `Trim${cp(0x2062)}${cp(0xe0042)}`, price_cents: 500, currency: 'USD' });
  s.db.putProfile(userId, { business_name: `Fresh${cp(0x200b)} Cuts`, tone: 'warm', currency: 'USD' });
  createApp({ db: s.db, cipher: s.cipher, ai: {} as never, paypal: {} as never });
  assert.deepEqual(s.db.listItems(userId).map((i) => i.name), ['Cut', 'Trim']);
  assert.equal(s.db.getProfile(userId)!.business_name, 'Fresh Cuts');
});
