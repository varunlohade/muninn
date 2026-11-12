import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Extraction } from '../src/ai.ts';
import { setup } from './helpers.ts';

const BARBER = 'Barber shop: cuts, fades and beard trims';
const APP_DEV = 'Freelance app developer: I design and build iPhone apps';

// Recorded model answers per business. The mock answers from the description it is given, as the real prompt asks:
// the same words map to what each business sells. Every answer carries amount 45, a price the model made up.
const ANSWERS: Record<string, Record<string, Partial<Extraction>>> = {
  [BARBER]: {
    'how much?': { item: 'Haircut' },
    'price for 5 screens?': { item: 'Screens', quantity: 5 },
    'how much for a beard trim?': { item: 'Beard trim' },
  },
  [APP_DEV]: {
    'how much?': { item: null },
    'price for 5 screens?': { item: 'App screen', quantity: 5 },
  },
};
const model = (text: string, _catalog: string, business: string): Partial<Extraction> =>
  ({ client_name: null, client_email: null, amount: 45, currency: null, ...ANSWERS[business]?.[text] ?? { item: null } });

async function owner(description: string, items: { name: string; price: number }[]) {
  const s = setup({ cls: { intent: 'catalog_reply' }, ext: model });
  const a = s.device();
  const r = await s.call(a.token, 'PUT', '/v1/profile/business', { description });
  assert.equal(r.status, 200);
  for (const it of items) assert.equal((await s.call(a.token, 'POST', '/v1/catalog', it)).status, 200);
  const ask = async (text: string) => (await (await s.call(a.token, 'POST', '/v1/suggest', { text })).json() as any).chips;
  return { s, a, ask };
}

test('business: the same price question maps to what each business sells', async () => {
  const barber = await owner(BARBER, [{ name: 'Haircut', price: 30 }, { name: 'Beard trim', price: 15 }]);
  const dev = await owner(APP_DEV, [{ name: 'App screen', price: 400 }, { name: 'Logo design', price: 250 }]);

  const cut = await barber.ask('how much?');
  assert.deepEqual(cut.map((c: any) => [c.kind, c.label, c.payload.text]), [['insert', 'Haircut · $30', 'Haircut is $30.']]);
  const devAsk = await dev.ask('how much?');
  assert.deepEqual(devAsk.map((c: any) => [c.kind, c.label]), [['reply', 'Reply with prices']]);

  const screens = await dev.ask('price for 5 screens?');
  assert.deepEqual(screens.map((c: any) => [c.kind, c.label, c.payload.text, c.payload.amount]),
    [['insert', '5 × App screen · $2000', '5 × App screen: $2000 ($400 each).', '2000.00']]);
  const noScreens = await barber.ask('price for 5 screens?');
  assert.deepEqual(noScreens.map((c: any) => [c.kind, c.label]), [['add_price', 'Add a price · Screens']]);

  // The description reaches both the intent question and the extraction prompt.
  for (const [o, d] of [[barber, BARBER], [dev, APP_DEV]] as const) {
    assert.ok(o.s.aiCalls.filter((c) => c.fn === 'classify').every((c) => c.args[1] === d));
    assert.ok(o.s.aiCalls.filter((c) => c.fn === 'extract').every((c) => c.args[2] === d));
  }
});

test('business: no price is ever made up; a missing price offers "Add a price"', async () => {
  const { ask } = await owner(BARBER, [{ name: 'Haircut', price: 30 }]);
  const chips = await ask('how much for a beard trim?');
  assert.deepEqual(chips.map((c: any) => [c.kind, c.label]), [['add_price', 'Add a price · Beard trim']]);
  assert.deepEqual(chips[0].payload, { item: 'Beard trim' });
  assert.ok(!JSON.stringify(chips).includes('45'), 'the model amount never shows');

  const empty = await owner(APP_DEV, []);
  const none = await empty.ask('how much?');
  assert.deepEqual(none.map((c: any) => [c.kind, c.label, c.payload]), [['add_price', 'Add a price', { item: null }]]);
  assert.ok(!JSON.stringify(none).includes('45'));
});

test('business: the quantity counts only when its number is in the typed words', async () => {
  const s = setup({ cls: { intent: 'catalog_reply' }, ext: () => ({ client_name: null, client_email: null, amount: null, currency: null, item: 'App screen', quantity: 5 }) });
  const a = s.device();
  await s.call(a.token, 'PUT', '/v1/profile/business', { description: APP_DEV });
  await s.call(a.token, 'POST', '/v1/catalog', { name: 'App screen', price: 400 });
  const ask = async (text: string) => (await (await s.call(a.token, 'POST', '/v1/suggest', { text })).json() as any).chips[0];
  // The model said 5, but the words never did: one screen.
  assert.equal((await ask('what do you charge for screens?')).payload.text, 'App screen is $400.');
  assert.equal((await ask('app screen price for 15 pages?')).payload.text, 'App screen is $400.');
  // Said in digits or in a word: it counts.
  assert.equal((await ask('price for 5 app screens?')).payload.text, '5 × App screen: $2000 ($400 each).');
  assert.equal((await ask('five app screens, how much?')).payload.quantity, 5);
});

test('business: the description is stored encrypted, per user, and editable', async () => {
  const { s, a } = await owner(BARBER, []);
  const raw = s.db.getDescriptionEnc(a.userId)!;
  assert.ok(raw && !raw.includes('Barber'), 'stored encrypted');
  const got = await (await s.call(a.token, 'GET', '/v1/profile')).json() as any;
  assert.equal(got.profile.description, BARBER);
  assert.equal(got.profile.business_name, 'my shop');

  // Editing the rest of the profile keeps the description; a new description replaces it.
  await s.call(a.token, 'PUT', '/v1/profile', { business_name: 'Fade Lab', tone: 'warm' });
  const put = await (await s.call(a.token, 'PUT', '/v1/profile/business', { description: 'Bakery' })).json() as any;
  assert.deepEqual([put.profile.business_name, put.profile.description], ['Fade Lab', 'Bakery']);

  const b = s.device();
  assert.equal((await (await s.call(b.token, 'GET', '/v1/profile')).json() as any).profile, null);
  assert.equal((await s.call(a.token, 'PUT', '/v1/profile/business', { description: '' })).status, 400);
});

test('business: a client reply is written for this business', async () => {
  const { s, a } = await owner(APP_DEV, []);
  await s.call(a.token, 'POST', '/v1/reply', { text: 'what do you charge?' });
  const reply = s.aiCalls.find((c) => c.fn === 'reply');
  assert.equal((reply?.args[1] as { description: string }).description, APP_DEV);
});
