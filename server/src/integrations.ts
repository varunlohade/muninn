import type { Cipher } from './crypto.ts';
import type { Db } from './db.ts';
import { config } from './config.ts';

export type Capability =
  | 'invoices' | 'pay_links' | 'reminders' | 'refunds' | 'transactions' | 'disputes'
  | 'payments' | 'pos_payments' | 'bookings' | 'client_email' | 'store_orders';

export type Provider = {
  id: string;
  name: string;
  capabilities: Capability[];
  available: boolean;
  // Returns the config to store (encrypted) for this user. PayPal connects to the one sandbox merchant.
  connect?(userId: string): Record<string, unknown>;
};

export const PROVIDERS: Provider[] = [
  {
    id: 'paypal',
    name: 'PayPal',
    capabilities: ['invoices', 'pay_links', 'reminders', 'refunds', 'transactions', 'disputes'],
    available: true,
    connect: () => ({ account: 'platform_merchant', environment: config.paypal.sandbox ? 'sandbox' : 'live' }),
  },
  { id: 'stripe', name: 'Stripe', capabilities: ['payments'], available: false },
  { id: 'square', name: 'Square', capabilities: ['pos_payments'], available: false },
  { id: 'google_calendar', name: 'Google Calendar', capabilities: ['bookings'], available: false },
  { id: 'gmail', name: 'Gmail', capabilities: ['client_email'], available: false },
  { id: 'shopify', name: 'Shopify', capabilities: ['store_orders'], available: false },
];

export type IntegrationView = {
  id: string; name: string; capabilities: Capability[]; status: 'connected' | 'not_connected' | 'coming_soon'; connected_at: string | null;
};

export function createIntegrations(db: Db, cipher: Cipher, now: () => number) {
  function connect(userId: string, provider: Provider) {
    if (!provider.available || !provider.connect) throw new Error(`${provider.id} cannot connect yet`);
    const cfg = provider.connect(userId);
    db.putIntegration(userId, { provider: provider.id, status: 'connected', connected_at: now(), config_enc: cipher.encrypt(userId, JSON.stringify(cfg)) });
  }

  // PayPal is the platform's own merchant for the hackathon, so every user is connected on first use.
  function ensureDefaults(userId: string) {
    const have = new Set(db.listIntegrations(userId).map((r) => r.provider));
    for (const p of PROVIDERS) if (p.available && p.connect && !have.has(p.id)) connect(userId, p);
  }

  function status(userId: string, providerId: string): 'connected' | 'not_connected' {
    return db.listIntegrations(userId).some((r) => r.provider === providerId && r.status === 'connected') ? 'connected' : 'not_connected';
  }

  function list(userId: string): IntegrationView[] {
    ensureDefaults(userId);
    const rows = new Map(db.listIntegrations(userId).map((r) => [r.provider, r]));
    return PROVIDERS.map((p) => {
      const r = rows.get(p.id);
      return {
        id: p.id, name: p.name, capabilities: p.capabilities,
        status: !p.available ? 'coming_soon' : r?.status === 'connected' ? 'connected' : 'not_connected',
        connected_at: p.available && r?.connected_at ? new Date(r.connected_at).toISOString() : null,
      };
    });
  }

  return { connect, ensureDefaults, status, list };
}
