import assert from 'node:assert/strict';
import { test } from 'node:test';
import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import type { AppleVerifier } from '../src/apple.ts';
import { createLimiter, ipKey } from '../src/app.ts';
import { config } from '../src/config.ts';
import { KEY_CACHE_MAX, createCipher, sha256 } from '../src/crypto.ts';
import { hashPassword, hashingStats } from '../src/password.ts';
import { setup } from './helpers.ts';

const PW = 'correct horse battery';
const LOCKED = { error: 'too many tries, wait a few minutes and try again' };
const DEVICE_ID = '3f0e6c1a-8a55-4a57-9d59-0c4d2f6f7b11';
// A stand-in for Apple: the identity token is the Apple user id. The nonce goes through the server's own check.
const apple: AppleVerifier = async (token) => ({ sub: token });
const appleBody = (nonce: string, sub = 'ana') => ({ identity_token: `apple-user-${sub}-0123456789`, nonce });

// A request from a given client address (the Node adapter's socket).
const from = (s: ReturnType<typeof setup>, ip: string, method: string, path: string, body?: unknown, token?: string) =>
  s.app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  }, { incoming: { socket: { remoteAddress: ip } } });

// Runs fn with config values swapped, then puts them back.
async function withConfig<T>(set: () => () => void, fn: () => Promise<T>): Promise<T> {
  const restore = set();
  try {
    return await fn();
  } finally {
    restore();
  }
}

test('limiter: a full map drops the oldest key only, never everyone', () => {
  const l = createLimiter({ limit: 1, windowMs: 60_000, maxKeys: 3 });
  for (const k of ['a', 'b', 'c']) assert.equal(l.hit(k), false);
  for (const k of ['a', 'b', 'c']) assert.equal(l.hit(k), true, `${k} is over`);
  l.hit('d');
  assert.equal(l.over('b'), true, 'b keeps its count');
  assert.equal(l.over('c'), true, 'c keeps its count');
  assert.equal(l.over('a'), false, 'only the oldest key went');
});

test('ipKey: IPv6 by /64, IPv4 and mapped IPv4 as is', () => {
  assert.equal(ipKey('203.0.113.7'), '203.0.113.7');
  assert.equal(ipKey('::ffff:203.0.113.7'), '203.0.113.7');
  assert.equal(ipKey('2001:db8:1:2:3:4:5:6'), '2001:db8:1:2::/64');
  assert.equal(ipKey('2001:0db8:0001:0002:ffff::1'), '2001:db8:1:2::/64');
  assert.equal(ipKey('2001:db8::1'), '2001:db8:0:0::/64');
  assert.equal(ipKey('fe80::1%en0'), 'fe80:0:0:0::/64');
});

test('limits: two IPv6 addresses in one /64 share a bucket', async () => {
  const s = setup();
  const codes: number[] = [];
  for (let i = 0; i < 6; i++) codes.push((await from(s, `2001:db8:1:2::${i + 1}`, 'POST', '/v1/auth/device', { device_id: DEVICE_ID })).status);
  assert.deepEqual(codes, [200, 200, 200, 200, 200, 429]);
  assert.equal((await from(s, '2001:db8:1:3::1', 'POST', '/v1/auth/device', { device_id: DEVICE_ID })).status, 200, 'another /64 has its own');
});

test('limits: a global cap on new accounts per hour; existing accounts still sign in', async () => {
  await withConfig(() => {
    const old = config.rateLimit.newAccounts.limit;
    config.rateLimit.newAccounts.limit = 2;
    return () => { config.rateLimit.newAccounts.limit = old; };
  }, async () => {
    const s = setup({ apple });
    assert.equal((await from(s, '10.0.0.1', 'POST', '/v1/auth/device', { device_id: DEVICE_ID })).status, 200);
    assert.equal((await from(s, '10.0.0.2', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).status, 200);
    assert.equal((await from(s, '10.0.0.3', 'POST', '/v1/auth/device', { device_id: DEVICE_ID })).status, 429);
    assert.equal((await from(s, '10.0.0.4', 'POST', '/v1/auth/email/signup', { email: 'ben@example.com', password: PW })).status, 429);
    assert.equal((await from(s, '10.0.0.5', 'POST', '/v1/auth/apple', appleBody('legacy-nonce-0123456789'))).status, 429);
    assert.equal((await from(s, '10.0.0.6', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW })).status, 200);
    assert.equal((await from(s, '10.0.0.7', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).status, 200, 'sign-up of an existing account is a login');
    assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n, 2);
  });
});

test('demo seed: a budget per hour; past it a new user starts empty and does not fail', async () => {
  await withConfig(() => {
    const old = config.rateLimit.demoSeed.limit;
    config.rateLimit.demoSeed.limit = 2;
    return () => { config.rateLimit.demoSeed.limit = old; };
  }, async () => {
    const seeded: string[] = [];
    const s = setup({ onNewUser: (id) => seeded.push(id) });
    for (let i = 0; i < 3; i++) {
      assert.equal((await from(s, `10.0.1.${i}`, 'POST', '/v1/auth/email/signup', { email: `u${i}@example.com`, password: PW })).status, 200);
    }
    assert.equal(seeded.length, 2);
    assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n, 3);
  });
});

test('email link: limited per client address too, and a short password is refused before any lookup', async () => {
  const s = setup();
  assert.equal((await from(s, '10.0.2.1', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).status, 200);
  const users = Array.from({ length: 11 }, () => s.device().token);
  const held = await from(s, '10.0.2.9', 'POST', '/v1/auth/email/link', { email: 'ana@example.com', password: 'short' }, users[0]);
  const free = await from(s, '10.0.2.9', 'POST', '/v1/auth/email/link', { email: 'nobody@example.com', password: 'short' }, users[0]);
  assert.equal(held.status, 400);
  assert.equal(free.status, 400);
  assert.deepEqual(await held.json(), await free.json());
  // Same address, many accounts: the address limit (10 a minute) still applies. 2 calls above, 8 more pass, then 429.
  const codes: number[] = [];
  for (let i = 1; i < 10; i++) codes.push((await from(s, '10.0.2.9', 'POST', '/v1/auth/email/link', { email: `x${i}@example.com`, password: 'short' }, users[i])).status);
  assert.deepEqual(codes, [...Array(8).fill(400), 429]);
});

test('lockout: 10 parallel guesses get at most 5 tries; the owner on another address still gets in', async () => {
  const s = setup();
  assert.equal((await from(s, '10.0.3.1', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).status, 200);
  const results = await Promise.all(Array.from({ length: 10 }, (_, i) =>
    from(s, '198.51.100.7', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: `guess-number-${i}` })));
  const codes = results.map((r) => r.status).sort();
  assert.deepEqual(codes, [...Array(5).fill(401), ...Array(5).fill(429)]);
  // The guessing address is locked for this email, even with the right password (sign-up shares the lock).
  const locked = await from(s, '198.51.100.7', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW });
  assert.equal(locked.status, 429);
  assert.deepEqual(await locked.json(), LOCKED);
  // The owner, somewhere else, is not locked out.
  assert.equal((await from(s, '10.0.3.2', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW })).status, 200);
});

test('lockout: past 20 tries an hour on one email, each try waits longer; the owner gets in after the wait', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const s = setup({ now: () => t });
  assert.equal((await from(s, '10.0.4.1', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).status, 200);
  for (let ip = 0; ip < 4; ip++) {
    for (let i = 0; i < 5; i++) {
      assert.equal((await from(s, `192.0.2.${ip}`, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: `guess-${ip}-${i}-xx` })).status, 401);
    }
  }
  const wait = await from(s, '10.0.4.2', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW });
  assert.equal(wait.status, 429);
  assert.equal(wait.headers.get('retry-after'), '1');
  t += 1001;
  assert.equal((await from(s, '10.0.4.2', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW })).status, 200);
  // The next wrong try makes the wait 2 s: it doubles each time, capped at 5 minutes.
  assert.equal((await from(s, '192.0.2.9', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: 'guess-again-xx' })).status, 401);
  assert.equal((await from(s, '10.0.4.2', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW })).headers.get('retry-after'), '2');
});

test('lockout table: rows older than an hour are pruned', async () => {
  const s = setup();
  s.db.raw.prepare('INSERT INTO auth_failures (key, count, first_at, locked_until) VALUES (?, ?, ?, ?)').run('old', 3, Date.now() - 2 * 3_600_000, null);
  await from(s, '10.0.5.1', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW });
  assert.equal(s.db.raw.prepare('SELECT 1 FROM auth_failures WHERE key = ?').get('old'), undefined);
});

test('password: a hash with older scrypt settings is redone at the next good login', async () => {
  const s = setup();
  const token = (await (await from(s, '10.0.6.1', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).json()).device_token;
  const userId = s.db.userForTokenHash(sha256(token))!;
  s.db.setPasswordHash(userId, await hashPassword(PW, { N: 16384, r: 8, p: 1 }));
  assert.equal((await from(s, '10.0.6.1', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW })).status, 200);
  const row = s.db.raw.prepare('SELECT password_hash FROM users WHERE id = ?').get(userId) as { password_hash: string };
  assert.match(row.password_hash, /^scrypt\$65536\$8\$2\$/);
  assert.equal((await from(s, '10.0.6.1', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW })).status, 200);
});

test('apple nonce: the server gives one out, it works once, and expires', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const s = setup({ apple, now: () => t });
  const r = await from(s, '10.0.7.1', 'GET', '/v1/auth/apple/nonce');
  assert.equal(r.status, 200);
  const { nonce, expires_in_s } = await r.json();
  assert.match(nonce, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(expires_in_s, 600);
  assert.equal((await from(s, '10.0.7.1', 'POST', '/v1/auth/apple', appleBody(nonce))).status, 200);
  const replay = await from(s, '10.0.7.1', 'POST', '/v1/auth/apple', appleBody(nonce));
  assert.equal(replay.status, 401, 'a used nonce is refused');
  assert.deepEqual(await replay.json(), { error: 'unauthorized' });
  assert.ok(!JSON.stringify(s.db.raw.prepare('SELECT * FROM apple_nonces').all()).includes(nonce), 'only the hash is stored');

  const late = (await (await from(s, '10.0.7.1', 'GET', '/v1/auth/apple/nonce')).json()).nonce;
  t += 10 * 60_000 + 1;
  assert.equal((await from(s, '10.0.7.1', 'POST', '/v1/auth/apple', appleBody(late))).status, 401, 'an expired nonce is refused');

  // /v1/auth/apple/link uses the nonce up the same way.
  const device = s.device().token;
  const link = (await (await from(s, '10.0.7.1', 'GET', '/v1/auth/apple/nonce')).json()).nonce;
  assert.equal((await from(s, '10.0.7.1', 'POST', '/v1/auth/apple/link', appleBody(link, 'ben'), device)).status, 200);
  assert.equal((await from(s, '10.0.7.1', 'POST', '/v1/auth/apple/link', appleBody(link, 'ben'), device)).status, 401);
});

test('apple nonce: when required, a nonce the server never gave out is refused; in test/dev it still works', async () => {
  const s = setup({ apple });
  const own = 'app-made-nonce-0123456789';
  assert.equal(config.apple.requireServerNonce, false);
  assert.equal((await from(s, '10.0.8.1', 'POST', '/v1/auth/apple', appleBody(own))).status, 200);
  await withConfig(() => {
    config.apple.requireServerNonce = true;
    return () => { config.apple.requireServerNonce = false; };
  }, async () => {
    assert.equal((await from(s, '10.0.8.1', 'POST', '/v1/auth/apple', appleBody(own))).status, 401);
    const nonce = (await (await from(s, '10.0.8.1', 'GET', '/v1/auth/apple/nonce')).json()).nonce;
    assert.equal((await from(s, '10.0.8.1', 'POST', '/v1/auth/apple', appleBody(nonce))).status, 200);
  });
});

test('crypto: the per-user key cache is bounded, and an evicted key is made again', () => {
  const cipher = createCipher(randomBytes(32));
  const first = cipher.encrypt('user-0', 'hello');
  for (let i = 1; i <= KEY_CACHE_MAX + 100; i++) cipher.encrypt(`user-${i}`, 'x');
  assert.equal(cipher.cachedKeys(), KEY_CACHE_MAX);
  assert.equal(cipher.decrypt('user-0', first), 'hello');
});

test('password hashing: 10 parallel logins all finish, never more than 2 hashes at once', async () => {
  const s = setup();
  assert.equal((await from(s, '10.0.9.1', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).status, 200);
  hashingStats(true);
  const results = await Promise.all(Array.from({ length: 10 }, (_, i) =>
    from(s, `10.0.9.${i + 10}`, 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: PW })));
  assert.deepEqual(results.map((r) => r.status), Array(10).fill(200));
  const stats = hashingStats();
  assert.equal(stats.peak, 2);
  assert.equal(stats.active, 0);
  assert.equal(stats.waiting, 0);
});

test('password hashing: a full queue answers 503 with Retry-After and gives the try back', async () => {
  const s = setup();
  assert.equal((await from(s, '10.0.10.1', 'POST', '/v1/auth/email/signup', { email: 'ana@example.com', password: PW })).status, 200);
  await withConfig(() => {
    const old = config.password.queueTimeoutMs;
    config.password.queueTimeoutMs = 1;
    return () => { config.password.queueTimeoutMs = old; };
  }, async () => {
    const results = await Promise.all(Array.from({ length: 5 }, () =>
      from(s, '10.0.10.2', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: 'wrong-guess-xx' })));
    const busy = results.filter((r) => r.status === 503);
    assert.equal(busy.length, 3);
    assert.equal(busy[0].headers.get('retry-after'), '5');
    assert.equal(results.filter((r) => r.status === 401).length, 2);
  });
  // Only the 2 hashes that ran count against this address: 3 more tries pass before the lock.
  const codes: number[] = [];
  for (let i = 0; i < 4; i++) codes.push((await from(s, '10.0.10.2', 'POST', '/v1/auth/email/login', { email: 'ana@example.com', password: `again-${i}-xx` })).status);
  assert.deepEqual(codes, [401, 401, 401, 429]);
});

test('config: APPLE_NONCE_REQUIRED=0 turns the nonce check off even in production', () => {
  const url = new URL('../src/config.ts', import.meta.url).href;
  const read = (env: Record<string, string>) => {
    const r = spawnSync(process.execPath, ['--input-type=module', '-e', `const { config } = await import(${JSON.stringify(url)}); console.log(config.apple.requireServerNonce)`],
      { env: { ...process.env, NODE_ENV: '', APPLE_NONCE_REQUIRED: '', ...env }, encoding: 'utf8', timeout: 10_000 });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout.trim();
  };
  assert.equal(read({ NODE_ENV: 'production', APPLE_NONCE_REQUIRED: '0' }), 'false');
  assert.equal(read({ NODE_ENV: 'production' }), 'true');
  assert.equal(read({ APPLE_NONCE_REQUIRED: '1' }), 'true');
  assert.equal(read({}), 'false');
});
