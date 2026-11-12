import { randomBytes, scrypt, timingSafeEqual, type ScryptOptions } from 'node:crypto';
import { config } from './config.ts';

// scrypt with a random 16-byte salt per password. Format: scrypt$N$r$p$salt$hash (salt and hash in base64).
// OWASP's N=2^16, r=8, p=2: 64 MB per hash (128 * N * r). The server has 512 MB, so at most
// config.password.maxConcurrent hashes run at once. A hash made with other settings is redone at the next good login.
export type ScryptParams = { N: number; r: number; p: number };
export const PARAMS: ScryptParams = { N: 65536, r: 8, p: 2 };
const KEY_LEN = 64;
const SALT_LEN = 16;
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 128;

/** Too many hashes are waiting. The caller answers 503 with Retry-After. */
export class PasswordBusyError extends Error {}

// A semaphore: `active` hashes run, the rest wait in order. A waiter that times out leaves the queue and throws.
let active = 0;
let peak = 0;
const waiting: (() => void)[] = [];
/** Running hashes now and the most at once since the last reset (for tests). */
export const hashingStats = (reset = false) => {
  const out = { active, peak, waiting: waiting.length };
  if (reset) peak = active;
  return out;
};

async function slot(): Promise<void> {
  if (active < config.password.maxConcurrent) {
    active++;
    peak = Math.max(peak, active);
    return;
  }
  await new Promise<void>((resolve, reject) => {
    const go = () => {
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(() => {
      waiting.splice(waiting.indexOf(go), 1);
      reject(new PasswordBusyError('password hashing is busy'));
    }, config.password.queueTimeoutMs);
    waiting.push(go);
  });
  // The slot was handed over by the finishing hash, so `active` stays the same.
  peak = Math.max(peak, active);
}

function free() {
  const next = waiting.shift();
  if (next) next();
  else active--;
}

const derive = async (password: string, salt: Buffer, o: ScryptOptions) => {
  await slot();
  try {
    return await new Promise<Buffer>((resolve, reject) =>
      scrypt(password.normalize('NFKC'), salt, KEY_LEN, { ...o, maxmem: 160 * 1024 * 1024 }, (e, k) => (e ? reject(e) : resolve(k))));
  } finally {
    free();
  }
};

export async function hashPassword(password: string, params: ScryptParams = PARAMS): Promise<string> {
  const salt = randomBytes(SALT_LEN);
  const key = await derive(password, salt, params);
  return `scrypt$${params.N}$${params.r}$${params.p}$${salt.toString('base64')}$${key.toString('base64')}`;
}

/** True when the stored hash was made with other settings than PARAMS. */
export const needsRehash = (stored: string) => !stored.startsWith(`scrypt$${PARAMS.N}$${PARAMS.r}$${PARAMS.p}$`);

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [kind, n, r, p, salt, hash] = stored.split('$');
  if (kind !== 'scrypt' || !salt || !hash) return false;
  const want = Buffer.from(hash, 'base64');
  const got = await derive(password, Buffer.from(salt, 'base64'), { N: Number(n), r: Number(r), p: Number(p) });
  return got.length === want.length && timingSafeEqual(got, want);
}

// A login for an unknown email still runs one scrypt, so the answer takes as long as a wrong password.
let dummy: Promise<string> | undefined;
export const dummyHash = () => (dummy ??= hashPassword(randomBytes(16).toString('hex')));

// The most common leaked passwords of 8 or more characters. Shorter ones already fail the length rule.
const COMMON = new Set([
  '12345678', '123456789', '1234567890', '12345678910', '123123123', '11111111', '00000000', '88888888', '87654321', '11223344',
  '1q2w3e4r', '1q2w3e4r5t', '1qaz2wsx', 'qwertyuiop', 'qwerty123', 'qwerty12', 'qwertyui', 'q1w2e3r4', 'q1w2e3r4t5', 'zaq12wsx',
  'asdfghjkl', 'asdfasdf', 'zxcvbnm1', 'password', 'password1', 'password12', 'password123', 'password!', 'passw0rd', 'p@ssw0rd',
  'p@ssword', 'pa$$word', 'iloveyou', 'iloveyou1', 'princess', 'sunshine', 'football', 'baseball', 'superman', 'starwars',
  'whatever', 'trustno1', 'welcome1', 'welcome123', 'letmein1', 'letmein123', 'abc12345', 'abcd1234', 'abcdefgh', 'admin123',
  'administrator', 'changeme', 'computer', 'internet', 'michelle', 'jennifer', 'charlie1', 'football1', 'monkey123', 'dragon123',
  'master123', 'shadow123', 'qazwsxedc', 'aa123456', 'a1234567', 'a12345678', 'asd12345', 'qwe12345', 'test1234', 'testtest',
  'unknown1', 'Aa123456', 'aaaaaaaa', 'zzzzzzzz', 'secret123', 'chocolate', 'butterfly', 'liverpool', 'mercedes', 'samsung1',
  'pokemon1', 'minecraft', 'qwerty1234', 'hello123', 'loveyou1', 'babygirl1', 'jordan23', 'michael1', 'killer123', 'freedom1',
  'paypal123', 'muninn123',
].map((p) => p.toLowerCase()));

/** Why this password is not allowed, or null when it is fine. */
export function passwordProblem(password: string): string | null {
  if (password.length < PASSWORD_MIN) return `password must be at least ${PASSWORD_MIN} characters`;
  if (password.length > PASSWORD_MAX) return `password must be at most ${PASSWORD_MAX} characters`;
  if (COMMON.has(password.toLowerCase()) || /^(.)\1+$/.test(password)) return 'this password is too common, pick another';
  return null;
}
