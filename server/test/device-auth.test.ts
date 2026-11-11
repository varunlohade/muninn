import assert from 'node:assert/strict';
import { test } from 'node:test';
import { sha256 } from '../src/crypto.ts';
import { setup } from './helpers.ts';

const ID = '3f0e6c1a-8a55-4a57-9d59-0c4d2f6f7b11';
const OTHER = '9b2d7c44-1e0f-4a6b-8f3e-5a1c2d3e4f50';

test('POST /v1/auth/device: a new user gets a working token, stored only as a hash', async () => {
  const s = setup();
  const r = await s.call(null, 'POST', '/v1/auth/device', { device_id: ID });
  assert.equal(r.status, 200);
  const { device_token } = await r.json();
  assert.match(device_token, /^pkd_[A-Za-z0-9_-]{20,100}$/);
  assert.equal((await s.call(device_token, 'GET', '/v1/summary')).status, 200);
  const users = s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number };
  assert.equal(users.n, 1);
  assert.ok(s.db.userForTokenHash(sha256(device_token)));
  const dump = JSON.stringify(s.db.raw.prepare('SELECT * FROM devices').all());
  assert.ok(!dump.includes(device_token), 'the token itself is never stored');
  assert.ok(!dump.includes(ID), 'the device id is never stored');
});

test('POST /v1/auth/device: the same device_id never gives back an existing user', async () => {
  const s = setup();
  const a = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: ID })).json()).device_token;
  const b = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: ID })).json()).device_token;
  assert.notEqual(a, b);
  assert.notEqual(s.db.userForTokenHash(sha256(a)), s.db.userForTokenHash(sha256(b)));
});

test('POST /v1/auth/device: users are isolated from each other', async () => {
  const s = setup();
  const a = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: ID })).json()).device_token;
  const b = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: OTHER })).json()).device_token;
  const put = await s.call(a, 'PUT', '/v1/profile', { business_name: 'Ana Cuts', tone: 'warm', currency: 'EUR' });
  assert.equal(put.status, 200);
  const made = await s.call(a, 'POST', '/v1/actions/paylink', { amount: '45.00', item: 'Haircut', client_name: 'Sam' }, { 'X-User-Action': 'tap', 'Idempotency-Key': 'device-auth-test-key-1' });
  assert.equal(made.status, 200, await made.clone().text());
  assert.equal((await (await s.call(a, 'GET', '/v1/payments')).json()).payments.length, 1);
  assert.equal((await (await s.call(b, 'GET', '/v1/profile')).json()).profile, null);
  assert.equal((await (await s.call(b, 'GET', '/v1/payments')).json()).payments.length, 0);
  assert.equal((await (await s.call(b, 'GET', '/v1/clients')).json()).clients.length, 0);
});

test('POST /v1/auth/device: a body without a UUID makes no user', async () => {
  const s = setup();
  for (const b of [{}, { device_id: 'abc' }, { device_id: ID, extra: 1 }, null]) {
    assert.equal((await s.call(null, 'POST', '/v1/auth/device', b)).status, 400);
  }
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n, 0);
});

test('POST /v1/auth/device: rate limited per client, 5 an hour', async () => {
  const s = setup();
  const codes: number[] = [];
  for (let i = 0; i < 6; i++) codes.push((await s.call(null, 'POST', '/v1/auth/device', { device_id: ID })).status);
  assert.deepEqual(codes, [200, 200, 200, 200, 200, 429]);
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n, 5);
});

test('POST /v1/auth/device: the new-user hook runs once per account', async () => {
  const seen: string[] = [];
  const s = setup({ onNewUser: (id) => seen.push(id) });
  await s.call(null, 'POST', '/v1/auth/device', { device_id: ID });
  assert.equal(seen.length, 1);
});
