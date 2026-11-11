import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createAppleVerifier, type AppleJwk } from '../src/apple.ts';
import { sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { DEMO_INVOICES, DEMO_PROFILE, seedDemo } from '../src/seed.ts';
import { setup } from './helpers.ts';

const AUD = 'com.orseliyas.muninn';
const NONCE = 'raw-nonce-0123456789abcdef';
const pair = (kid: string) => {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  return { kid, privateKey, jwk: { ...(publicKey.export({ format: 'jwk' }) as { kty: string; n: string; e: string }), kid, alg: 'RS256', use: 'sig' } as AppleJwk };
};
const apple = pair('apple-key-1');
const other = pair('apple-key-1');
const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');

function token(claims: Record<string, unknown> = {}, o: { key?: KeyObject; kid?: string; alg?: string } = {}) {
  const head = b64({ alg: o.alg ?? 'RS256', kid: o.kid ?? apple.kid });
  const body = b64({
    iss: 'https://appleid.apple.com', aud: AUD, sub: '001234.abcdef.5678', nonce: sha256(NONCE),
    iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 600, ...claims,
  });
  const sig = sign('RSA-SHA256', Buffer.from(`${head}.${body}`), o.key ?? apple.privateKey).toString('base64url');
  return `${head}.${body}.${sig}`;
}
function verifier(keys: AppleJwk[] = [apple.jwk]) {
  let fetches = 0;
  const verify = createAppleVerifier({ audience: AUD, fetchKeys: async () => { fetches++; return keys; } });
  return { verify, fetches: () => fetches };
}

test('apple: a good token gives the sub, and the JWKS is fetched once', async () => {
  const v = verifier();
  assert.deepEqual(await v.verify(token(), NONCE), { sub: '001234.abcdef.5678' });
  await v.verify(token({ sub: 'someone-else' }), NONCE);
  assert.equal(v.fetches(), 1);
});

test('apple: bad signature is rejected', async () => {
  const v = verifier();
  await assert.rejects(v.verify(token({}, { key: other.privateKey }), NONCE), /bad signature/);
  const [h, , s] = token().split('.');
  await assert.rejects(v.verify(`${h}.${b64({ iss: 'https://appleid.apple.com', aud: AUD, sub: 'attacker', nonce: sha256(NONCE), exp: 9e9 })}.${s}`, NONCE), /bad signature/);
});

test('apple: alg none and HS256 are rejected', async () => {
  const v = verifier();
  const [, b] = token().split('.');
  await assert.rejects(v.verify(`${b64({ alg: 'none', kid: apple.kid })}.${b}.`, NONCE), /bad header/);
  await assert.rejects(v.verify(token({}, { alg: 'HS256' }), NONCE), /bad header/);
});

test('apple: wrong aud, wrong iss, expired and wrong nonce are rejected', async () => {
  const v = verifier();
  await assert.rejects(v.verify(token({ aud: 'com.evil.app' }), NONCE), /bad aud/);
  await assert.rejects(v.verify(token({ iss: 'https://evil.example' }), NONCE), /bad iss/);
  await assert.rejects(v.verify(token({ exp: Math.floor(Date.now() / 1000) - 1 }), NONCE), /expired/);
  await assert.rejects(v.verify(token(), 'another-raw-nonce-000000'), /bad nonce/);
  await assert.rejects(v.verify(token({ nonce: NONCE }), NONCE), /bad nonce/);
  await assert.rejects(v.verify(token({ nonce: undefined }), NONCE), /bad nonce/);
});

test('apple: unknown key id is rejected and does not refetch on every call', async () => {
  const v = verifier();
  await assert.rejects(v.verify(token({}, { kid: 'nope' }), NONCE), /unknown key id/);
  await assert.rejects(v.verify(token({}, { kid: 'nope' }), NONCE), /unknown key id/);
  assert.equal(v.fetches(), 1);
});

test('POST /v1/auth/apple: signs in, reuses the user, stores only hashes', async () => {
  const created: string[] = [];
  const s = setup({ apple: verifier().verify, onNewUser: (id) => created.push(id) });
  const post = (b: unknown) => s.call(null, 'POST', '/v1/auth/apple', b);

  const r1 = await post({ identity_token: token(), nonce: NONCE });
  assert.equal(r1.status, 200);
  const t1 = (await r1.json()).device_token as string;
  assert.match(t1, /^pkd_/);
  assert.equal((await s.call(t1, 'GET', '/v1/summary')).status, 200);

  const t2 = (await (await post({ identity_token: token(), nonce: NONCE })).json()).device_token as string;
  assert.notEqual(t1, t2);
  const users = s.db.raw.prepare('SELECT id, apple_sub_hash FROM users').all() as { id: string; apple_sub_hash: string }[];
  assert.equal(users.length, 1);
  assert.deepEqual(created, [users[0].id]);
  assert.equal(s.db.userForTokenHash(sha256(t2)), users[0].id);

  const dump = JSON.stringify([users, s.db.raw.prepare('SELECT * FROM devices').all()]);
  for (const secret of ['001234.abcdef.5678', sha256('001234.abcdef.5678'), t1, t2]) assert.ok(!dump.includes(secret));

  await post({ identity_token: token({ sub: 'second-person' }), nonce: NONCE });
  assert.equal(created.length, 2);
});

test('POST /v1/auth/apple: every failure is the same 401', async () => {
  const s = setup({ apple: verifier().verify });
  const bodies: unknown[] = [
    { identity_token: token({}, { key: other.privateKey }), nonce: NONCE },
    { identity_token: token({ aud: 'com.evil.app' }), nonce: NONCE },
    { identity_token: token({ exp: 1 }), nonce: NONCE },
    { identity_token: token(), nonce: 'another-raw-nonce-000000' },
    { identity_token: 'not.a.jwt-but-long-enough-to-pass', nonce: NONCE },
    { nonce: NONCE },
    'garbage',
  ];
  for (const b of bodies) {
    const r = await s.call(null, 'POST', '/v1/auth/apple', b);
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: 'unauthorized' });
  }
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n, 0);
});

test('POST /v1/auth/apple: rate limited per client', async () => {
  const s = setup({ apple: verifier().verify });
  let last = 0;
  for (let i = 0; i < 11; i++) last = (await s.call(null, 'POST', '/v1/auth/apple', { nonce: NONCE })).status;
  assert.equal(last, 429);
});

test('db: an old users table gains apple_sub_hash', () => {
  const file = join(mkdtempSync(join(tmpdir(), 'muninn-test-')), 'old.db');
  try {
    const old = openDb(file);
    old.raw.exec('DROP INDEX users_apple; ALTER TABLE users DROP COLUMN apple_sub_hash');
    const kept = old.createUser();
    old.raw.close();
    const db = openDb(file);
    assert.equal(db.userForAppleSub('h1').created, true);
    assert.equal(db.userForAppleSub('h1').created, false);
    assert.ok(db.raw.prepare('SELECT id FROM users WHERE id = ?').get(kept));
    db.raw.close();
  } finally {
    rmSync(dirname(file), { recursive: true, force: true });
  }
});

test('POST /v1/auth/apple: with the demo seed hook, a new user starts with the demo business', async () => {
  const seeds: Promise<unknown>[] = [];
  const s: ReturnType<typeof setup> = setup({
    apple: verifier().verify,
    onNewUser: (userId) => seeds.push(seedDemo({ db: s.db, cipher: s.cipher, paypal: s.mockPayPal, userId, now: Date.now() })),
  });
  const { device_token } = await (await s.call(null, 'POST', '/v1/auth/apple', { identity_token: token(), nonce: NONCE })).json();
  await Promise.all(seeds);
  const profile = (await (await s.call(device_token, 'GET', '/v1/profile')).json()).profile;
  assert.equal(profile.business_name, DEMO_PROFILE.business_name);
  assert.equal((await (await s.call(device_token, 'GET', '/v1/payments')).json()).payments.length, DEMO_INVOICES.length);

  await s.call(null, 'POST', '/v1/auth/apple', { identity_token: token(), nonce: NONCE });
  assert.equal(seeds.length, 1);
});

const DEVICE = '3f0e6c1a-8a55-4a57-9d59-0c4d2f6f7b11';
const tap = (key: string) => ({ 'X-User-Action': 'tap', 'Idempotency-Key': key });

test('POST /v1/auth/apple/link: attaches the Apple account to the device account, and keeps its data and token', async () => {
  const s = setup({ apple: verifier().verify });
  const device = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  assert.equal((await s.call(device, 'POST', '/v1/actions/paylink', { amount: '45.00', item: 'Haircut' }, tap('link-test-key-0001'))).status, 200);
  const r = await s.call(device, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { linked: true, recovered: false });
  const users = s.db.raw.prepare('SELECT id, apple_sub_hash FROM users').all() as { id: string; apple_sub_hash: string | null }[];
  assert.equal(users.length, 1);
  assert.ok(users[0].apple_sub_hash);
  assert.ok(!JSON.stringify(users).includes('001234.abcdef.5678'), 'only a hash of the Apple id is stored');
  assert.equal((await (await s.call(device, 'GET', '/v1/payments')).json()).payments.length, 1);
  // Again from the same account: still linked, nothing new.
  assert.deepEqual(await (await s.call(device, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE })).json(), { linked: true, recovered: false });
});

test('POST /v1/auth/apple/link: a re-install gets the earlier account and its data back', async () => {
  const s = setup({ apple: verifier().verify });
  const first = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  await s.call(first, 'POST', '/v1/actions/paylink', { amount: '45.00', item: 'Haircut' }, tap('link-test-key-0002'));
  await s.call(first, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE });

  const fresh = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  assert.equal((await (await s.call(fresh, 'GET', '/v1/payments')).json()).payments.length, 0, 'a new install starts empty');
  const r = await s.call(fresh, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE });
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(body.recovered, true);
  assert.match(body.device_token, /^pkd_/);
  assert.notEqual(body.device_token, first);
  assert.equal(s.db.userForTokenHash(sha256(body.device_token)), s.db.userForTokenHash(sha256(first)));
  assert.equal((await (await s.call(body.device_token, 'GET', '/v1/payments')).json()).payments.length, 1, 'the earlier data is back');
  // Another person's Apple account never reaches this user.
  const other = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  assert.deepEqual(await (await s.call(other, 'POST', '/v1/auth/apple/link', { identity_token: token({ sub: 'second-person' }), nonce: NONCE })).json(), { linked: true, recovered: false });
  assert.equal((await (await s.call(other, 'GET', '/v1/payments')).json()).payments.length, 0);
});

test('POST /v1/auth/apple/link: a bad Apple token, a missing device token or a second Apple account is refused', async () => {
  const s = setup({ apple: verifier().verify });
  const device = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  const bad: unknown[] = [
    {}, { identity_token: token() }, { identity_token: token(), nonce: 'another-raw-nonce-000000' },
    { identity_token: token({ aud: 'com.evil.app' }), nonce: NONCE }, { identity_token: token({ exp: Math.floor(Date.now() / 1000) - 1 }), nonce: NONCE },
    { identity_token: token().slice(0, -6) + 'AAAAAA', nonce: NONCE },
  ];
  for (const b of bad) {
    const r = await s.call(device, 'POST', '/v1/auth/apple/link', b);
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: 'unauthorized' });
  }
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users WHERE apple_sub_hash IS NOT NULL').get() as { n: number }).n, 0);
  assert.equal((await s.call(null, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE })).status, 401, 'no device token, no link');

  assert.equal((await s.call(device, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE })).status, 200);
  const second = await s.call(device, 'POST', '/v1/auth/apple/link', { identity_token: token({ sub: 'second-person' }), nonce: NONCE });
  assert.equal(second.status, 409);
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n, 1);
});
