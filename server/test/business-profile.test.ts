import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setup } from './helpers.ts';

const BARBER = 'Barber shop: cuts, fades and beard trims';
const APP_DEV = 'Freelance app developer: I design and build iPhone apps';

async function owner(description: string) {
  const s = setup({ cls: { intent: 'none' }, ext: { client_name: null, client_email: null, amount: null, item: null } });
  const a = s.device();
  const r = await s.call(a.token, 'PUT', '/v1/profile/business', { description });
  assert.equal(r.status, 200);
  const ask = async (text: string) => (await (await s.call(a.token, 'POST', '/v1/suggest', { text })).json() as any).chips;
  return { s, a, ask };
}

test('business: a price question gets no price chip, and the description reaches the intent and extraction prompts', async () => {
  const barber = await owner(BARBER);
  assert.deepEqual(await barber.ask('how much for a beard trim?'), []);
  const dev = await owner(APP_DEV);
  await dev.ask('two screens for 50');
  for (const [o, d] of [[barber, BARBER], [dev, APP_DEV]] as const) {
    assert.ok(o.s.aiCalls.filter((c) => c.fn === 'classify').every((c) => c.args[1] === d));
    assert.ok(o.s.aiCalls.filter((c) => c.fn === 'extract').every((c) => c.args[2] === d));
  }
  assert.ok(dev.s.aiCalls.some((c) => c.fn === 'extract'));
});

test('business: the description is stored encrypted, per user, and editable', async () => {
  const { s, a } = await owner(BARBER);
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
  const { s, a } = await owner(APP_DEV);
  await s.call(a.token, 'POST', '/v1/reply', { text: 'what do you charge?' });
  const reply = s.aiCalls.find((c) => c.fn === 'reply');
  assert.equal((reply?.args[1] as { description: string }).description, APP_DEV);
});
