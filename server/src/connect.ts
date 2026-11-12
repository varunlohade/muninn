import { Hono, type Context } from 'hono';
import { randomBytes } from 'node:crypto';
import { config } from './config.ts';
import { sha256, type Cipher } from './crypto.ts';
import type { Db, PayPalConnectionRow } from './db.ts';
import { log } from './log.ts';
import { clean } from './text.ts';
import type { PayPalProvider, Seller } from './paypal.ts';

// Connect PayPal: Partner Referrals v2. The seller signs in on PayPal, grants this app's permissions, and comes back.
// The tracking id is random per Connect tap, so it says nothing about the owner. Only its hash is stored.
/** The business name a profile has until the owner or PayPal gives one. */
export const DEFAULT_BUSINESS_NAME = 'my shop';
const TRACKING = /^mu[0-9a-f]{32}$/;
const MERCHANT = /^[A-Z0-9]{8,20}$/;
const CODE = /^[0-9a-f]{48}$/;
type Verified = { merchantId: string; email: string | null; receivable: boolean; confirmed: boolean; name?: string | null; currency?: string | null };
const codeOf = async (c: Context) => {
  const b = await c.req.json().catch(() => null) as { code?: unknown } | null;
  return typeof b?.code === 'string' ? b.code : '';
};
const accountKey = (cipher: Cipher, merchantId: string) => cipher.lookupHash('paypal-merchant', merchantId);

const decrypt = (cipher: Cipher, userId: string, v: string | null) => {
  if (!v) return null;
  try {
    return cipher.decrypt(userId, v);
  } catch {
    log('decrypt_failed', { user_id: userId });
    return null;
  }
};

/** The user's connected PayPal account, or null for the shared demo merchant. The PayPal provider reads it on every call. */
export function sellerLookup(db: Db, cipher: Cipher) {
  return (userId: string): Seller | null => {
    const r = db.getPayPalConnection(userId);
    if (r?.status !== 'connected' || !r.merchant_hash) return null;
    const merchantId = decrypt(cipher, userId, r.merchant_enc);
    return merchantId ? { merchantId, email: decrypt(cipher, userId, r.email_enc), account: r.merchant_hash } : null;
  };
}

export function mask(email: string | null, merchantId: string | null): string | null {
  const at = email?.indexOf('@') ?? -1;
  if (email && at > 0) return `${email[0]}•••${email.slice(at)}`;
  return merchantId ? `•••${merchantId.slice(-4)}` : null;
}

export function createPayPalConnect(deps: { db: Db; cipher: Cipher; paypal: PayPalProvider; now: () => number; onChange?: (userId: string) => void }) {
  const { db, cipher, paypal, now } = deps;
  const connected = (userId: string) => {
    const r = db.getPayPalConnection(userId);
    return r?.status === 'connected' ? r : null;
  };

  /** The account key new objects carry: null for the demo merchant. */
  const account = (userId: string) => connected(userId)?.merchant_hash ?? null;

  function label(userId: string): string | null {
    const r = connected(userId);
    return r ? mask(decrypt(cipher, userId, r.email_enc), decrypt(cipher, userId, r.merchant_enc)) : null;
  }

  // Checks with PayPal that this tracking id belongs to this merchant and that the seller granted our permissions,
  // then records the checked merchant on the pending Connect. It does not connect: only the owner's app can finish,
  // with the one-time code, so a sign-up link sent to someone else never attaches their PayPal to the sender's account.
  async function verify(row: PayPalConnectionRow, merchantId: string, code: string | null): Promise<'verified' | 'declined' | 'failed'> {
    const st = await paypal.partner().merchantStatus(merchantId);
    if (!st || (st.trackingId !== null && sha256(st.trackingId) !== row.tracking_hash)) return 'failed';
    if (!st.permissionsGranted) return 'declined';
    const v: Verified = { merchantId, email: st.primaryEmail, receivable: st.paymentsReceivable, confirmed: st.emailConfirmed, name: st.legalName ?? null, currency: st.currency ?? null };
    const ok = db.verifyPayPalConnect(row.user_id, row.tracking_hash, cipher.encrypt(row.user_id, JSON.stringify(v)),
      code ? sha256(code) : null, code ? now() + config.paypal.connectCodeTtlMs : null);
    return ok ? 'verified' : 'failed';
  }

  /** The caller's own pending Connect for this code, while the code is fresh, with the merchant PayPal checked. */
  function byCode(userId: string, code: string): { row: PayPalConnectionRow; v: Verified } | null {
    if (!CODE.test(code)) return null;
    const row = db.payPalConnectionByCode(sha256(code));
    if (!row || row.user_id !== userId || !row.code_expires_at || row.code_expires_at < now() || !row.verified_enc) return null;
    const raw = decrypt(cipher, userId, row.verified_enc);
    return raw ? { row, v: JSON.parse(raw) as Verified } : null;
  }

  const pendingFor = (trackingId: string) => {
    const row = db.payPalConnectionByTracking(sha256(trackingId));
    return row?.status === 'pending' && row.created_at + config.paypal.connectTtlMs > now() ? row : null;
  };

  const routes = new Hono<{ Variables: { userId: string } }>();

  routes.post('/v1/paypal/connect', async (c) => {
    const userId = c.get('userId');
    if (!config.paypal.publicUrl || !config.paypal.partnerMerchantId) return c.json({ error: 'Connect PayPal is not set up on this server' }, 503);
    if (connected(userId)) return c.json({ error: 'PayPal is already connected. Disconnect it first.' }, 409);
    const trackingId = `mu${randomBytes(16).toString('hex')}`;
    if (!db.startPayPalConnect(userId, sha256(trackingId), now())) return c.json({ error: 'PayPal is already connected. Disconnect it first.' }, 409);
    const { actionUrl } = await paypal.partner().createReferral(trackingId, `${config.paypal.publicUrl}/paypal/return`);
    log('paypal_connect_started', { user_id: userId });
    return c.json({ action_url: actionUrl, return_scheme: new URL(config.paypal.appReturnUrl).protocol.slice(0, -1) });
  });

  // PayPal sends the seller's browser here. Nothing in the query is trusted: PayPal confirms the merchant for this tracking id.
  // A good return hands the app a one-time code; the app finishes with it, signed in as the user who started this Connect.
  routes.get('/paypal/return', async (c) => {
    const back = (result: string) => c.redirect(`${config.paypal.appReturnUrl}?result=${result}`, 302);
    const code = randomBytes(24).toString('hex');
    const trackingId = c.req.query('merchantId') ?? '';
    const merchantId = c.req.query('merchantIdInPayPal') ?? '';
    const row = TRACKING.test(trackingId) ? pendingFor(trackingId) : null;
    if (!row || !MERCHANT.test(merchantId)) {
      log('paypal_return_rejected', { reason: row ? 'bad merchant id' : 'unknown tracking id' });
      return back('failed');
    }
    if (c.req.query('permissionsGranted') !== 'true' || c.req.query('consentStatus') !== 'true') return back('declined');
    let result: Awaited<ReturnType<typeof verify>>;
    try {
      const confirmed = await paypal.partner().merchantIdForTracking(trackingId);
      result = confirmed === merchantId ? await verify(row, merchantId, code) : 'failed';
    } catch (e) {
      log('paypal_return_error', { user_id: row.user_id, err: (e as Error).message });
      result = 'failed';
    }
    log('paypal_return', { user_id: row.user_id, result });
    return result === 'verified' ? c.redirect(`${config.paypal.appReturnUrl}?code=${code}`, 302) : back(result);
  });

  // The app shows which PayPal came back before the owner says "Use this account".
  routes.post('/v1/paypal/pending', async (c) => {
    const found = byCode(c.get('userId'), await codeOf(c));
    if (!found) return c.json({ error: 'This PayPal sign-in has expired. Connect again.' }, 404);
    return c.json({ account: mask(found.v.email, found.v.merchantId) });
  });

  routes.post('/v1/paypal/finish', async (c) => {
    const userId = c.get('userId');
    const found = byCode(userId, await codeOf(c));
    if (!found) return c.json({ error: 'This PayPal sign-in has expired. Connect again.' }, 404);
    const { row, v } = found;
    const ok = db.finishPayPalConnect(userId, row.tracking_hash, {
      merchant_hash: accountKey(cipher, v.merchantId), merchant_enc: cipher.encrypt(userId, v.merchantId),
      email_enc: v.email ? cipher.encrypt(userId, v.email) : null, payments_receivable: Number(v.receivable), email_confirmed: Number(v.confirmed),
    });
    log('paypal_connect_finished', { user_id: userId, result: ok ? 'connected' : 'taken' });
    if (!ok) return c.json({ error: 'That PayPal account is already connected to another Muninn account.', result: 'taken' }, 409);
    deps.onChange?.(userId);
    // Sign in with PayPal fills the business name and currency from PayPal while the owner has not set a name
    // (no profile yet, or still the default). A name the owner typed is never replaced.
    const name = v.name ? clean(v.name).slice(0, 80) : '';
    const p = db.getProfile(userId);
    if (name && (!p || p.business_name === DEFAULT_BUSINESS_NAME)) {
      const currency = v.currency && (config.money.currencies as readonly string[]).includes(v.currency) ? v.currency : p?.currency ?? 'USD';
      db.putProfile(userId, { business_name: name, tone: p?.tone ?? 'friendly and short', currency });
    }
    return c.json({ result: 'connected', account: label(userId) });
  });

  routes.get('/v1/paypal/status', async (c) => {
    const userId = c.get('userId');
    let r = connected(userId);
    // Until PayPal says the account can take payments, each status check asks again.
    if (r && !(r.payments_receivable && r.email_confirmed)) {
      const merchantId = decrypt(cipher, userId, r.merchant_enc);
      try {
        const st = merchantId ? await paypal.partner().merchantStatus(merchantId) : null;
        if (st) db.setPayPalFlags(userId, st.paymentsReceivable, st.emailConfirmed);
        r = connected(userId);
      } catch (e) {
        log('paypal_status_error', { user_id: userId, err: (e as Error).message });
      }
    }
    return c.json({
      connected: !!r, demo: !r, pending: db.getPayPalConnection(userId)?.status === 'pending',
      email_confirmed: !!r?.email_confirmed, payments_receivable: !!r?.payments_receivable, account: label(userId),
    });
  });

  // Forgets the seller here. Objects the seller's account made stay on it, so they read "no longer connected" until a reconnect.
  routes.post('/v1/paypal/disconnect', (c) => {
    const userId = c.get('userId');
    const removed = db.removePayPalConnection(userId);
    deps.onChange?.(userId);
    log('paypal_disconnected', { user_id: userId, removed });
    return c.json({ connected: false, demo: true });
  });

  /** MERCHANT.* webhooks, already verified by the caller. True when the event changed a connection. */
  async function webhook(type: string, res: any): Promise<boolean> {
    const merchantId = typeof res?.merchant_id === 'string' && MERCHANT.test(res.merchant_id) ? res.merchant_id : null;
    if (!merchantId) return false;
    if (type === 'MERCHANT.PARTNER-CONSENT.REVOKED') {
      const userId = db.removePayPalByMerchant(accountKey(cipher, merchantId));
      if (userId) { log('paypal_revoked', { user_id: userId }); deps.onChange?.(userId); }
      return !!userId;
    }
    if (type === 'MERCHANT.ONBOARDING.COMPLETED') {
      const trackingId = typeof res?.tracking_id === 'string' && TRACKING.test(res.tracking_id) ? res.tracking_id : null;
      const row = trackingId ? pendingFor(trackingId) : null;
      if (!row) return false;
      // Records the checked merchant only. The owner's app still finishes with the code from the return link.
      const result = await verify(row, merchantId, null);
      log('paypal_onboarding_webhook', { user_id: row.user_id, result });
      return result === 'verified';
    }
    return false;
  }

  return { routes, account, label, isDemo: (userId: string) => !connected(userId), webhook };
}
