import { createCipheriv, createDecipheriv, createHash, hkdfSync, randomBytes } from 'node:crypto';

const VERSION = 'v1';

export type Cipher = {
  encrypt(userId: string, plaintext: string): string;
  decrypt(userId: string, blob: string): string;
};

export function parseMasterKey(hex: string | undefined): Buffer {
  if (!hex || !/^[0-9a-f]{64}$/i.test(hex)) throw new Error('DATA_ENCRYPTION_KEY must be 64 hex chars (32 bytes)');
  return Buffer.from(hex, 'hex');
}

export function createCipher(masterKey: Buffer): Cipher {
  const keys = new Map<string, Buffer>();
  const keyFor = (userId: string) => {
    let k = keys.get(userId);
    if (!k) {
      k = Buffer.from(hkdfSync('sha256', masterKey, Buffer.from(userId, 'utf8'), 'pro-keyboard/data/v1', 32));
      keys.set(userId, k);
    }
    return k;
  };
  return {
    encrypt(userId, plaintext) {
      const iv = randomBytes(12);
      const c = createCipheriv('aes-256-gcm', keyFor(userId), iv);
      c.setAAD(Buffer.from(userId, 'utf8'));
      const ct = Buffer.concat([c.update(plaintext, 'utf8'), c.final()]);
      return `${VERSION}:${Buffer.concat([iv, c.getAuthTag(), ct]).toString('base64')}`;
    },
    decrypt(userId, blob) {
      const [v, b64] = blob.split(':');
      if (v !== VERSION || !b64) throw new Error('bad ciphertext format');
      const raw = Buffer.from(b64, 'base64');
      const d = createDecipheriv('aes-256-gcm', keyFor(userId), raw.subarray(0, 12));
      d.setAAD(Buffer.from(userId, 'utf8'));
      d.setAuthTag(raw.subarray(12, 28));
      return Buffer.concat([d.update(raw.subarray(28)), d.final()]).toString('utf8');
    },
  };
}

export const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');
export const randomToken = (prefix: string) => `${prefix}_${randomBytes(32).toString('base64url')}`;
