import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AppleVerifier } from '../src/apple.ts';
import { sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { verifyPassword } from '../src/password.ts';
import { setup } from './helpers.ts';

const PW = 'correct horse battery';
const DEVICE_ID = '3f0e6c1a-8a55-4a57-9d59-0c4d2f6f7b11';
const WRONG = { error: 'wrong email or password' };
// A stand-in for Apple: the identity token is the Apple user id.
const apple: AppleVerifier = async (token) => ({ sub: token });
const appleBody = (sub: string) => ({ identity_token: `apple-user-${sub}-0123456789`, nonce: 'raw-nonce-0123456789abcdef' });
const tap = { 'X-User-Action': 'tap' };

const tokenOf = async (r: Response) => {
  assert.equal(r.status, 200, await r.clone().text());
  return (await r.json()).device_token as string;
};
const count = (s: ReturnType<typeof setup>, sql: string, ...args: string[]) =>
  (s.db.raw.prepare(sql).get(...args) as { n: number }).n;

test('email: sign up, then log in; tokens work, differ, and only hashes are stored', async () => {
  const s = setup();
  const r = await s.call(null, 'POST', '/v1/auth/email/signup', { email: '  Ana@Example.COM ', password: PW });
  const body = await r.clone().json();
  assert.equal(body.created, true);
  const t1 = await tokenOf(r);
  assert.match(t1, /^pkd_[A-Za-z0-9_-]{43}$/, '256 random bits');
  assert.equal((await s.call(t1, 'GET', '/v1/summary')).status, 200);

  const t2 = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW }));
  assert.notEqual(t1, t2, 'every login makes a new token');
  assert.equal(s.db.userForTokenHash(sha256(t1)), s.db.userForTokenHash(sha256(t2)));
  assert.deepEqual(await (await s.call(t2, 'GET', '/v1/account')).json(), { email: 'ana@example.com', apple: false, password: true });

  const dump = JSON.stringify([s.db.raw.prepare('SELECT * FROM users').all(), s.db.raw.prepare('SELECT * FROM devices').all()]);
  for (const secret of ['ana@example.com', 'Ana@Example', PW, t1, t2]) assert.ok(!dump.includes(secret), `${secret} is not stored in plain`);
  const row = s.db.raw.prepare('SELECT id, email_enc, password_hash FROM users').get() as { id: string; email_enc: string; password_hash: string };
  assert.match(row.password_hash, /^scrypt\$65536\$8\$2\$/);
  assert.equal(s.cipher.decrypt(row.id, row.email_enc), 'ana@example.com');
  assert.equal(await verifyPassword(PW, row.password_hash), true);
  assert.equal(await verifyPassword('wrong password', row.password_hash), false);
  const expires = s.db.raw.prepare('SELECT expires_at - created_at AS ttl FROM devices LIMIT 1').get() as { ttl: number };
  assert.equal(expires.ttl, 90 * 86_400_000, 'a session lasts 90 days');
});

test('email: sign-up rules: a real email, 8+ characters, not a common password', async () => {
  const s = setup();
  for (const b of [
    { email: 'not-an-email', password: PW }, { email: 'a@b.co', password: 'short1' }, { email: 'a@b.co', password: 'Password123' },
    { email: 'a@b.co', password: '12345678' }, { email: 'a@b.co', password: 'aaaaaaaaaa' }, { email: 'a@b.co' }, { email: 'a@b.co', password: PW, extra: 1 },
  ]) {
    assert.equal((await s.call(null, 'POST', '/v1/auth/email/signup', b)).status, 400, JSON.stringify(b));
  }
  assert.equal(count(s, 'SELECT COUNT(*) AS n FROM users'), 0);
});

test('email: an unknown email and a wrong password get the same 401', async () => {
  const s = setup();
  await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  const wrong = await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: 'not the password' });
  const unknown = await s.call(null, 'POST', '/v1/auth/email/login', { email: 'nobody@example.com', password: 'not the password' });
  const junk = await s.call(null, 'POST', '/v1/auth/email/login', { email: 'nope', password: '' });
  for (const r of [wrong, unknown, junk]) {
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), WRONG);
  }
});

test('email: 5 wrong passwords lock the email, even for the right password, then it unlocks', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const s = setup({ now: () => t });
  await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  for (let i = 0; i < 5; i++) assert.equal((await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: `nope-${i}-xx` })).status, 401);
  const locked = await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW });
  assert.equal(locked.status, 429);
  assert.ok(Number(locked.headers.get('retry-after')) > 0);
  // Signing up does not get around the lock.
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).status, 429);

  t += 15 * 60_000 + 1;
  await tokenOf(await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW }));
});

test('email: an email with no account locks the same way, so the lock says nothing about who has an account', async () => {
  const s = setup();
  for (let i = 0; i < 5; i++) await s.call(null, 'POST', '/v1/auth/email/login', { email: 'nobody@example.com', password: `nope-${i}-xx` });
  const r = await s.call(null, 'POST', '/v1/auth/email/login', { email: 'nobody@example.com', password: PW });
  assert.equal(r.status, 429);
  assert.deepEqual(await r.json(), { error: 'too many tries, wait a few minutes and try again' });
});

test('email: per-address rate limit', async () => {
  const s = setup();
  const codes: number[] = [];
  for (let i = 0; i < 11; i++) codes.push((await s.call(null, 'POST', '/v1/auth/email/login', { email: `u${i}@example.com`, password: PW })).status);
  assert.deepEqual(codes, [...Array(10).fill(401), 429]);
});

test('email: signing up twice never makes a second account', async () => {
  const s = setup();
  const a = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  const again = await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ANA@example.com', password: PW });
  assert.equal((await again.clone().json()).created, false);
  const b = await tokenOf(again);
  assert.equal(s.db.userForTokenHash(sha256(a)), s.db.userForTokenHash(sha256(b)));
  const other = await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: 'another good passphrase' });
  assert.equal(other.status, 409);
  assert.equal(count(s, 'SELECT COUNT(*) AS n FROM users'), 1);
});

test('logout: the token fails with 401 at once; other sessions keep working', async () => {
  const s = setup();
  const a = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  const b = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW }));
  const r = await s.call(a, 'POST', '/v1/auth/logout');
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { logged_out: true, sessions_ended: 1 });
  assert.equal((await s.call(a, 'GET', '/v1/summary')).status, 401);
  assert.equal((await s.call(a, 'POST', '/v1/auth/logout')).status, 401);
  assert.equal((await s.call(b, 'GET', '/v1/summary')).status, 200);
});

test('logout ?all=1: every session of the user ends; other users are untouched', async () => {
  const s = setup();
  const a = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  const b = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW }));
  const other = s.device().token;
  assert.deepEqual(await (await s.call(a, 'POST', '/v1/auth/logout?all=1')).json(), { logged_out: true, sessions_ended: 2 });
  assert.equal((await s.call(a, 'GET', '/v1/summary')).status, 401);
  assert.equal((await s.call(b, 'GET', '/v1/summary')).status, 401);
  assert.equal((await s.call(other, 'GET', '/v1/summary')).status, 200);
  // The password still works: logout is not a lock.
  await tokenOf(await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW }));
});

test('session: an expired token is refused', async () => {
  const s = setup();
  const { token } = s.device();
  s.db.raw.prepare('UPDATE devices SET expires_at = ?').run(Date.now() - 1);
  assert.equal((await s.call(token, 'GET', '/v1/summary')).status, 401);
});

test('session: a token in use slides to a full 90 days, at most once a day', async () => {
  const s = setup();
  const { token } = s.device();
  const day = 86_400_000;
  const expiry = () => (s.db.raw.prepare('SELECT expires_at FROM devices').get() as { expires_at: number }).expires_at;
  const first = expiry();
  s.db.raw.prepare('UPDATE devices SET expires_at = ?').run(first - 12 * 3_600_000);
  assert.equal((await s.call(token, 'GET', '/v1/summary')).status, 200);
  assert.equal(expiry(), first - 12 * 3_600_000, 'used within a day of the last slide: no write');
  s.db.raw.prepare('UPDATE devices SET expires_at = ?').run(Date.now() + day);
  assert.equal((await s.call(token, 'GET', '/v1/summary')).status, 200);
  assert.ok(expiry() >= first, 'a token one day from its cutoff gets a full session again');
  assert.ok(expiry() <= Date.now() + 90 * day);
});

test('db: an old devices table gains expires_at, set from created_at', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pk-'));
  try {
    const path = join(dir, 'old.db');
    const old = new DatabaseSync(path);
    old.exec(`CREATE TABLE users (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, apple_sub_hash TEXT);
      CREATE TABLE devices (token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), label TEXT, created_at INTEGER NOT NULL);
      INSERT INTO users VALUES ('u1', 1, NULL); INSERT INTO devices VALUES ('h1', 'u1', 'x', ${Date.now()});`);
    old.close();
    const db = openDb(path);
    assert.equal(db.userForTokenHash('h1'), 'u1');
    assert.equal(db.userForTokenHash('h1', Date.now() + 91 * 86_400_000), undefined);
    const cols = (db.raw.prepare('PRAGMA table_info(users)').all() as { name: string }[]).map((c) => c.name);
    for (const c of ['email_hash', 'email_enc', 'password_hash']) assert.ok(cols.includes(c));
    db.raw.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('DELETE /v1/account: needs a tap, then removes every row of the user and nobody else', async () => {
  const s = setup();
  const a = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  const other = s.device();
  const userId = s.db.userForTokenHash(sha256(a))!;
  for (const t of [a, other.token]) {
    assert.equal((await s.call(t, 'PUT', '/v1/profile', { business_name: 'Ana Cuts', tone: 'warm', currency: 'USD' })).status, 200);
    assert.equal((await s.call(t, 'POST', '/v1/actions/paylink', { amount: '45.00', item: 'Haircut', client_name: 'Sam' })).status, 200);
  }
  assert.equal((await s.call(a, 'DELETE', '/v1/account')).status, 428, 'no tap, no delete');

  const r = await s.call(a, 'DELETE', '/v1/account', undefined, tap);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { deleted: true });
  assert.equal((await s.call(a, 'GET', '/v1/summary')).status, 401);
  const tables = (s.db.raw.prepare(`SELECT m.name FROM sqlite_master m, pragma_table_info(m.name) c WHERE m.type = 'table' AND c.name = 'user_id'`)
    .all() as { name: string }[]).map((t) => t.name);
  assert.ok(tables.length >= 15);
  for (const t of tables) assert.equal(count(s, `SELECT COUNT(*) AS n FROM "${t}" WHERE user_id = ?`, userId), 0, t);
  assert.equal(count(s, 'SELECT COUNT(*) AS n FROM users WHERE id = ?', userId), 0);
  assert.ok(count(s, 'SELECT COUNT(*) AS n FROM invoices WHERE user_id = ?', other.userId) + count(s, 'SELECT COUNT(*) AS n FROM orders WHERE user_id = ?', other.userId) > 0);

  // The login is gone too; the email can start a fresh, empty account.
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW })).status, 401);
  const fresh = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
});

test('Apple + email: link an email to an Apple account; both ways in reach one user', async () => {
  const s = setup({ apple });
  const viaApple = await tokenOf(await s.call(null, 'POST', '/v1/auth/apple', appleBody('ana')));
  const userId = s.db.userForTokenHash(sha256(viaApple));
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/link', { email: 'ana@example.com', password: PW })).status, 401, 'link needs a session');
  assert.equal((await s.call(viaApple, 'POST', '/v1/auth/email/link', { email: 'ana@example.com', password: 'password1' })).status, 400, 'weak password');
  const r = await s.call(viaApple, 'POST', '/v1/auth/email/link', { email: 'Ana@Example.com', password: PW });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { linked: true, recovered: false });
  assert.deepEqual(await (await s.call(viaApple, 'GET', '/v1/account')).json(), { email: 'ana@example.com', apple: true, password: true });

  const viaEmail = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW }));
  assert.equal(s.db.userForTokenHash(sha256(viaEmail)), userId);
  const again = await tokenOf(await s.call(null, 'POST', '/v1/auth/apple', appleBody('ana')));
  assert.equal(s.db.userForTokenHash(sha256(again)), userId);
  // Signing up with the linked email and its password signs in; it makes no second user.
  const signup = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  assert.equal(s.db.userForTokenHash(sha256(signup)), userId);
  assert.equal(count(s, 'SELECT COUNT(*) AS n FROM users'), 1);

  // A second email for the same account is refused.
  assert.equal((await s.call(viaApple, 'POST', '/v1/auth/email/link', { email: 'other@example.com', password: PW })).status, 409);
});

test('Apple + email: an email account adds Apple through /v1/auth/apple/link', async () => {
  const s = setup({ apple });
  const viaEmail = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  assert.deepEqual(await (await s.call(viaEmail, 'POST', '/v1/auth/apple/link', appleBody('ana'))).json(), { linked: true, recovered: false });
  const viaApple = await tokenOf(await s.call(null, 'POST', '/v1/auth/apple', appleBody('ana')));
  assert.equal(s.db.userForTokenHash(sha256(viaApple)), s.db.userForTokenHash(sha256(viaEmail)));
  assert.equal(count(s, 'SELECT COUNT(*) AS n FROM users'), 1);
});

test('email link: an email held by another account needs its password, then returns that account', async () => {
  const s = setup();
  const owner = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW }));
  const fresh = s.device();
  const bad = await s.call(fresh.token, 'POST', '/v1/auth/email/link', { email: 'ana@example.com', password: 'not the password' });
  assert.equal(bad.status, 401);
  assert.deepEqual(await bad.json(), WRONG);
  const r = await s.call(fresh.token, 'POST', '/v1/auth/email/link', { email: 'ana@example.com', password: PW });
  const body = await r.json();
  assert.equal(body.recovered, true);
  assert.equal(s.db.userForTokenHash(sha256(body.device_token)), s.db.userForTokenHash(sha256(owner)));
  assert.equal(s.db.account(fresh.userId)?.email_enc, null, 'the device account did not take the email');
});

test('two people, one phone (same device id): nobody sees the other after logout and login', async () => {
  const s = setup();
  const a = await tokenOf(await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE_ID }));
  assert.equal((await s.call(a, 'POST', '/v1/auth/email/link', { email: 'ana@example.com', password: PW })).status, 200);
  assert.equal((await s.call(a, 'PUT', '/v1/profile', { business_name: 'Ana Cuts', tone: 'warm', currency: 'EUR' })).status, 200);
  assert.equal((await s.call(a, 'POST', '/v1/actions/paylink', { amount: '45.00', item: 'Haircut', client_name: 'Sam' })).status, 200);
  assert.equal((await s.call(a, 'POST', '/v1/auth/logout')).status, 200);
  assert.equal((await s.call(a, 'GET', '/v1/payments')).status, 401);

  const b = await tokenOf(await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE_ID }));
  assert.equal((await s.call(b, 'POST', '/v1/auth/email/link', { email: 'ben@example.com', password: 'another good passphrase' })).status, 200);
  const b2 = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ben@example.com', password: 'another good passphrase' }));
  for (const t of [b, b2]) {
    assert.equal((await (await s.call(t, 'GET', '/v1/profile')).json()).profile, null);
    assert.equal((await (await s.call(t, 'GET', '/v1/payments')).json()).payments.length, 0);
    assert.equal((await (await s.call(t, 'GET', '/v1/account')).json()).email, 'ben@example.com');
  }
  assert.equal((await s.call(b2, 'POST', '/v1/auth/logout?all=1')).status, 200);

  const a2 = await tokenOf(await s.call(null, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW }));
  assert.equal((await (await s.call(a2, 'GET', '/v1/profile')).json()).profile.business_name, 'Ana Cuts');
  assert.equal((await (await s.call(a2, 'GET', '/v1/payments')).json()).payments.length, 1);
  assert.equal((await s.call(b, 'GET', '/v1/profile')).status, 401);
});

test('idempotency: the stored answer is encrypted, and a replay still returns it', async () => {
  const s = setup();
  const { token, userId } = s.device();
  const h = { 'X-User-Action': 'tap', 'Idempotency-Key': 'enc-idem-key-0001' };
  const first = await s.call(token, 'POST', '/v1/actions/paylink', { amount: '45.00', item: 'Haircut', client_name: 'Sam' }, h);
  assert.equal(first.status, 200);
  const row = s.db.raw.prepare('SELECT response FROM idempotency WHERE user_id = ?').get(userId) as { response: string };
  assert.match(row.response, /^v1:/);
  const again = await s.call(token, 'POST', '/v1/actions/paylink', { amount: '45.00', item: 'Haircut', client_name: 'Sam' }, h);
  assert.deepEqual(await again.json(), await first.json());
  // A row stored before encryption (plain JSON) still replays.
  s.db.raw.prepare('UPDATE idempotency SET response = ? WHERE user_id = ?').run('{"id":"OLD"}', userId);
  assert.deepEqual(await (await s.call(token, 'POST', '/v1/actions/paylink', { amount: '45.00', item: 'Haircut', client_name: 'Sam' }, h)).json(), { id: 'OLD' });
});
