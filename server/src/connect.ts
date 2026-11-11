import { Hono } from 'hono';
import { randomBytes } from 'node:crypto';
import { config } from './config.ts';
import { sha256, type Cipher } from './crypto.ts';
import type { Db, PayPalConnectionRow } from './db.ts';
import { log } from './log.ts';
import type { PayPalProvider, Seller } from './paypal.ts';

// Connect PayPal: Partner Referrals v2. The seller signs in on PayPal, grants this app's permissions, and comes back.
// The tracking id is random per Connect tap, so it says nothing about the owner. Only its hash is stored.
const TRACKING = /^mu[0-9a-f]{32}$/;
const MERCHANT = /^[A-Z0-9]{8,20}$/;
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

export function createPayPalConnect(deps: { db: Db; cipher: Cipher; paypal: PayPalProvider; now: () => number }) {
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
  // then stores the merchant for the user that started this Connect.
  async function finish(row: PayPalConnectionRow, merchantId: string): Promise<'connected' | 'declined' | 'taken' | 'failed'> {
    const partner = paypal.partner();
    const st = await partner.merchantStatus(merchantId);
    if (!st || (st.trackingId !== null && sha256(st.trackingId) !== row.tracking_hash)) return 'failed';
    if (!st.permissionsGranted) return 'declined';
    const ok = db.finishPayPalConnect(row.user_id, row.tracking_hash, {
      merchant_hash: accountKey(cipher, merchantId), merchant_enc: cipher.encrypt(row.user_id, merchantId),
      email_enc: st.primaryEmail ? cipher.encrypt(row.user_id, st.primaryEmail) : null,
      payments_receivable: Number(st.paymentsReceivable), email_confirmed: Number(st.emailConfirmed),
    });
    return ok ? 'connected' : 'taken';
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
  routes.get('/paypal/return', async (c) => {
    const back = (result: string) => c.redirect(`${config.paypal.appReturnUrl}?result=${result}`, 302);
    const trackingId = c.req.query('merchantId') ?? '';
    const merchantId = c.req.query('merchantIdInPayPal') ?? '';
    const row = TRACKING.test(trackingId) ? pendingFor(trackingId) : null;
    if (!row || !MERCHANT.test(merchantId)) {
      log('paypal_return_rejected', { reason: row ? 'bad merchant id' : 'unknown tracking id' });
      return back('failed');
    }
    if (c.req.query('permissionsGranted') !== 'true' || c.req.query('consentStatus') !== 'true') return back('declined');
    let result: Awaited<ReturnType<typeof finish>>;
    try {
      const confirmed = await paypal.partner().merchantIdForTracking(trackingId);
      result = confirmed === merchantId ? await finish(row, merchantId) : 'failed';
    } catch (e) {
      log('paypal_return_error', { user_id: row.user_id, err: (e as Error).message });
      result = 'failed';
    }
    log('paypal_return', { user_id: row.user_id, result });
    return back(result);
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
    log('paypal_disconnected', { user_id: userId, removed });
    return c.json({ connected: false, demo: true });
  });

  /** MERCHANT.* webhooks, already verified by the caller. True when the event changed a connection. */
  async function webhook(type: string, res: any): Promise<boolean> {
    const merchantId = typeof res?.merchant_id === 'string' && MERCHANT.test(res.merchant_id) ? res.merchant_id : null;
    if (!merchantId) return false;
    if (type === 'MERCHANT.PARTNER-CONSENT.REVOKED') {
      const userId = db.removePayPalByMerchant(accountKey(cipher, merchantId));
      if (userId) log('paypal_revoked', { user_id: userId });
      return !!userId;
    }
    if (type === 'MERCHANT.ONBOARDING.COMPLETED') {
      const trackingId = typeof res?.tracking_id === 'string' && TRACKING.test(res.tracking_id) ? res.tracking_id : null;
      const row = trackingId ? pendingFor(trackingId) : null;
      if (!row) return false;
      const result = await finish(row, merchantId);
      log('paypal_onboarding_webhook', { user_id: row.user_id, result });
      return result === 'connected';
    }
    return false;
  }

  return { routes, account, label, isDemo: (userId: string) => !connected(userId), webhook };
}
