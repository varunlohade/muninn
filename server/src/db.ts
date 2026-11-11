import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

const SCHEMA = `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, apple_sub_hash TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS users_apple ON users(apple_sub_hash) WHERE apple_sub_hash IS NOT NULL;
CREATE TABLE IF NOT EXISTS devices (
  token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), label TEXT, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS profiles (
  user_id TEXT PRIMARY KEY REFERENCES users(id), business_name TEXT NOT NULL, tone TEXT NOT NULL, currency TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS catalog_items (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), name TEXT NOT NULL,
  price_cents INTEGER NOT NULL, currency TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS invoices (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), status TEXT NOT NULL,
  amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, item TEXT NOT NULL,
  client_name_enc TEXT, client_email_enc TEXT, pay_link TEXT, due_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL, paid_at INTEGER, capture_id TEXT, source TEXT NOT NULL DEFAULT 'app', seed_key TEXT);
CREATE TABLE IF NOT EXISTS orders (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), status TEXT NOT NULL,
  amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, item TEXT NOT NULL,
  client_name_enc TEXT, approve_link TEXT, created_at INTEGER NOT NULL, paid_at INTEGER, capture_id TEXT);
CREATE TABLE IF NOT EXISTS reminders (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), invoice_id TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS refunds (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), target_kind TEXT NOT NULL, target_id TEXT NOT NULL,
  amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, capture_id TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
  expires_at INTEGER NOT NULL, status TEXT NOT NULL, paypal_refund_id TEXT, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS idempotency (
  user_id TEXT NOT NULL REFERENCES users(id), key TEXT NOT NULL, route TEXT NOT NULL, body_hash TEXT NOT NULL,
  status TEXT NOT NULL, response TEXT, created_at INTEGER NOT NULL, PRIMARY KEY (user_id, key));
CREATE TABLE IF NOT EXISTS integrations (
  user_id TEXT NOT NULL REFERENCES users(id), provider TEXT NOT NULL, status TEXT NOT NULL,
  connected_at INTEGER, config_enc TEXT, PRIMARY KEY (user_id, provider));
CREATE INDEX IF NOT EXISTS refunds_target ON refunds(user_id, target_id, status);
CREATE UNIQUE INDEX IF NOT EXISTS invoices_seed ON invoices(user_id, seed_key) WHERE seed_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS invoices_user ON invoices(user_id, created_at);
CREATE INDEX IF NOT EXISTS orders_user ON orders(user_id, created_at);
CREATE INDEX IF NOT EXISTS catalog_user ON catalog_items(user_id);
`;

export type Profile = { business_name: string; tone: string; currency: string };
export type CatalogItem = { id: string; name: string; price_cents: number; currency: string };
export type InvoiceRow = {
  id: string; user_id: string; status: string; amount_cents: number; currency: string; item: string;
  client_name_enc: string | null; client_email_enc: string | null; pay_link: string | null;
  due_at: number; created_at: number; paid_at: number | null; capture_id: string | null;
  source: 'app' | 'demo_seed'; seed_key: string | null;
};
export type OrderRow = {
  id: string; user_id: string; status: string; amount_cents: number; currency: string; item: string;
  client_name_enc: string | null; approve_link: string | null; created_at: number; paid_at: number | null; capture_id: string | null;
};
export type RefundRow = {
  id: string; user_id: string; target_kind: 'invoice' | 'order'; target_id: string; amount_cents: number; currency: string;
  capture_id: string; token_hash: string; expires_at: number; status: string; paypal_refund_id: string | null;
};

export type IntegrationRow = { provider: string; status: string; connected_at: number | null; config_enc: string | null };

export type Db = ReturnType<typeof openDb>;
export type IdemRow = { route: string; body_hash: string; status: 'pending' | 'done'; response: string | null };
export type ClaimResult = { ok: RefundRow } | { error: 'not_found' | 'busy' | 'closed' | 'exceeds' };

export function openDb(path: string) {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  const idemCols = db.prepare('PRAGMA table_info(idempotency)').all() as { name: string }[];
  if (idemCols.length && !idemCols.some((c) => c.name === 'body_hash')) db.exec('DROP TABLE idempotency');
  const invCols = db.prepare('PRAGMA table_info(invoices)').all() as { name: string }[];
  if (invCols.length && !invCols.some((c) => c.name === 'source')) {
    db.exec("ALTER TABLE invoices ADD COLUMN source TEXT NOT NULL DEFAULT 'app'; ALTER TABLE invoices ADD COLUMN seed_key TEXT;");
  }
  const userCols = db.prepare('PRAGMA table_info(users)').all() as { name: string }[];
  if (userCols.length && !userCols.some((c) => c.name === 'apple_sub_hash')) db.exec('ALTER TABLE users ADD COLUMN apple_sub_hash TEXT');
  db.exec(SCHEMA);
  const now = () => Date.now();
  const q = (sql: string) => db.prepare(sql);

  return {
    raw: db,

    createUser(): string {
      const id = randomUUID();
      q('INSERT INTO users (id, created_at) VALUES (?, ?)').run(id, now());
      return id;
    },
    // Atomic find-or-create, so two sign-ins at once for one Apple account end with one user.
    userForAppleSub(subHash: string): { userId: string; created: boolean } {
      const id = randomUUID();
      const created = q('INSERT OR IGNORE INTO users (id, created_at, apple_sub_hash) VALUES (?, ?, ?)').run(id, now(), subHash).changes > 0;
      if (created) return { userId: id, created };
      return { userId: (q('SELECT id FROM users WHERE apple_sub_hash = ?').get(subHash) as { id: string }).id, created };
    },
    addDevice(userId: string, tokenHash: string, label: string | null) {
      q('INSERT INTO devices (token_hash, user_id, label, created_at) VALUES (?, ?, ?, ?)').run(tokenHash, userId, label, now());
    },
    userForDeviceLabel(label: string): string | undefined {
      return (q('SELECT user_id FROM devices WHERE label = ? ORDER BY created_at LIMIT 1').get(label) as { user_id: string } | undefined)?.user_id;
    },
    removeDevice(tokenHash: string) {
      q('DELETE FROM devices WHERE token_hash = ?').run(tokenHash);
    },
    userForTokenHash(tokenHash: string): string | undefined {
      const r = q('SELECT user_id FROM devices WHERE token_hash = ?').get(tokenHash) as { user_id: string } | undefined;
      return r?.user_id;
    },

    getProfile(userId: string): Profile | undefined {
      return q('SELECT business_name, tone, currency FROM profiles WHERE user_id = ?').get(userId) as Profile | undefined;
    },
    putProfile(userId: string, p: Profile) {
      q(`INSERT INTO profiles (user_id, business_name, tone, currency) VALUES (?, ?, ?, ?)
         ON CONFLICT(user_id) DO UPDATE SET business_name = excluded.business_name, tone = excluded.tone, currency = excluded.currency`)
        .run(userId, p.business_name, p.tone, p.currency);
    },

    allItems(): (CatalogItem & { user_id: string })[] {
      return q('SELECT id, user_id, name, price_cents, currency FROM catalog_items').all() as (CatalogItem & { user_id: string })[];
    },
    allProfiles(): (Profile & { user_id: string })[] {
      return q('SELECT user_id, business_name, tone, currency FROM profiles').all() as (Profile & { user_id: string })[];
    },
    listItems(userId: string): CatalogItem[] {
      return q('SELECT id, name, price_cents, currency FROM catalog_items WHERE user_id = ? ORDER BY created_at').all(userId) as CatalogItem[];
    },
    addItem(userId: string, it: Omit<CatalogItem, 'id'>): CatalogItem {
      const id = randomUUID();
      q('INSERT INTO catalog_items (id, user_id, name, price_cents, currency, created_at) VALUES (?, ?, ?, ?, ?, ?)')
        .run(id, userId, it.name, it.price_cents, it.currency, now());
      return { id, ...it };
    },
    updateItem(userId: string, id: string, it: Omit<CatalogItem, 'id'>): boolean {
      return q('UPDATE catalog_items SET name = ?, price_cents = ?, currency = ? WHERE id = ? AND user_id = ?')
        .run(it.name, it.price_cents, it.currency, id, userId).changes > 0;
    },
    deleteItem(userId: string, id: string): boolean {
      return q('DELETE FROM catalog_items WHERE id = ? AND user_id = ?').run(id, userId).changes > 0;
    },

    insertInvoice(r: Omit<InvoiceRow, 'paid_at' | 'capture_id' | 'source' | 'seed_key'> & Partial<Pick<InvoiceRow, 'source' | 'seed_key'>>) {
      q(`INSERT OR IGNORE INTO invoices (id, user_id, status, amount_cents, currency, item, client_name_enc, client_email_enc, pay_link, due_at, created_at, source, seed_key)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(r.id, r.user_id, r.status, r.amount_cents, r.currency, r.item, r.client_name_enc, r.client_email_enc, r.pay_link, r.due_at, r.created_at,
          r.source ?? 'app', r.seed_key ?? null);
    },
    invoiceBySeedKey(userId: string, key: string): InvoiceRow | undefined {
      return q('SELECT * FROM invoices WHERE user_id = ? AND seed_key = ?').get(userId, key) as InvoiceRow | undefined;
    },
    getInvoice(userId: string, id: string): InvoiceRow | undefined {
      return q('SELECT * FROM invoices WHERE id = ? AND user_id = ?').get(id, userId) as InvoiceRow | undefined;
    },
    listInvoices(userId: string, limit = 50): InvoiceRow[] {
      return q('SELECT * FROM invoices WHERE user_id = ? ORDER BY created_at DESC LIMIT ?').all(userId, limit) as InvoiceRow[];
    },
    setInvoiceStatus(userId: string, id: string, status: string, paidAt: number | null, captureId: string | null) {
      q('UPDATE invoices SET status = ?, paid_at = COALESCE(paid_at, ?), capture_id = COALESCE(capture_id, ?) WHERE id = ? AND user_id = ?')
        .run(status, paidAt, captureId, id, userId);
    },

    insertOrder(r: Omit<OrderRow, 'paid_at' | 'capture_id'>) {
      q(`INSERT OR IGNORE INTO orders (id, user_id, status, amount_cents, currency, item, client_name_enc, approve_link, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(r.id, r.user_id, r.status, r.amount_cents, r.currency, r.item, r.client_name_enc, r.approve_link, r.created_at);
    },
    getOrder(userId: string, id: string): OrderRow | undefined {
      return q('SELECT * FROM orders WHERE id = ? AND user_id = ?').get(id, userId) as OrderRow | undefined;
    },
    listOrders(userId: string, limit = 50): OrderRow[] {
      return q('SELECT * FROM orders WHERE user_id = ? ORDER BY created_at DESC LIMIT ?').all(userId, limit) as OrderRow[];
    },
    setOrderStatus(userId: string, id: string, status: string, paidAt: number | null, captureId: string | null) {
      q('UPDATE orders SET status = ?, paid_at = COALESCE(paid_at, ?), capture_id = COALESCE(capture_id, ?) WHERE id = ? AND user_id = ?')
        .run(status, paidAt, captureId, id, userId);
    },

    ownerOfInvoice(id: string): string | undefined {
      return (q('SELECT user_id FROM invoices WHERE id = ?').get(id) as { user_id: string } | undefined)?.user_id;
    },
    ownerOfOrder(id: string): string | undefined {
      return (q('SELECT user_id FROM orders WHERE id = ?').get(id) as { user_id: string } | undefined)?.user_id;
    },

    addReminder(userId: string, invoiceId: string) {
      q('INSERT INTO reminders (id, user_id, invoice_id, created_at) VALUES (?, ?, ?, ?)').run(randomUUID(), userId, invoiceId, now());
    },

    insertRefund(r: Omit<RefundRow, 'paypal_refund_id'>) {
      q(`INSERT INTO refunds (id, user_id, target_kind, target_id, amount_cents, currency, capture_id, token_hash, expires_at, status, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(r.id, r.user_id, r.target_kind, r.target_id, r.amount_cents, r.currency, r.capture_id, r.token_hash, r.expires_at, r.status, now());
    },
    refundState(userId: string, targetId: string): { doneCents: number; running: number } {
      const r = q(`SELECT COALESCE(SUM(CASE WHEN status = 'done' THEN amount_cents END), 0) AS done_cents,
                          COUNT(CASE WHEN status = 'running' THEN 1 END) AS running
                   FROM refunds WHERE user_id = ? AND target_id = ?`).get(userId, targetId) as { done_cents: number; running: number };
      return { doneCents: r.done_cents, running: r.running };
    },
    // Atomic: one refund per target runs at a time, the amount is re-checked against what is left,
    // and claiming one token voids every other open token on the same target.
    claimRefund(userId: string, tokenHash: string, at: number): ClaimResult {
      db.exec('BEGIN IMMEDIATE');
      try {
        const result = ((): ClaimResult => {
          const r = q(`SELECT * FROM refunds WHERE token_hash = ? AND user_id = ? AND status = 'pending' AND expires_at > ?`)
            .get(tokenHash, userId, at) as RefundRow | undefined;
          if (!r) return { error: 'not_found' };
          const table = r.target_kind === 'invoice' ? 'invoices' : 'orders';
          const target = q(`SELECT status, amount_cents FROM ${table} WHERE id = ? AND user_id = ?`).get(r.target_id, userId) as
            { status: string; amount_cents: number } | undefined;
          const state = this.refundState(userId, r.target_id);
          if (state.running > 0) return { error: 'busy' };
          const voidIt = (reason: ClaimResult) => {
            q(`UPDATE refunds SET status = 'void' WHERE id = ?`).run(r.id);
            return reason;
          };
          if (!target || target.status === 'REFUNDED') return voidIt({ error: 'closed' });
          if (state.doneCents + r.amount_cents > target.amount_cents) return voidIt({ error: 'exceeds' });
          q(`UPDATE refunds SET status = 'running' WHERE id = ?`).run(r.id);
          q(`UPDATE refunds SET status = 'void' WHERE user_id = ? AND target_id = ? AND status = 'pending'`).run(userId, r.target_id);
          return { ok: { ...r, status: 'running' } };
        })();
        db.exec('COMMIT');
        return result;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
    finishRefund(userId: string, id: string, status: string, paypalRefundId: string | null) {
      q('UPDATE refunds SET status = ?, paypal_refund_id = ? WHERE id = ? AND user_id = ?').run(status, paypalRefundId, id, userId);
    },

    reserveIdem(userId: string, key: string, route: string, bodyHash: string): IdemRow | null {
      const ins = q(`INSERT OR IGNORE INTO idempotency (user_id, key, route, body_hash, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?)`)
        .run(userId, key, route, bodyHash, now());
      if (ins.changes > 0) return null;
      return q('SELECT route, body_hash, status, response FROM idempotency WHERE user_id = ? AND key = ?').get(userId, key) as unknown as IdemRow;
    },
    getIdem(userId: string, key: string): IdemRow | null {
      return (q('SELECT route, body_hash, status, response FROM idempotency WHERE user_id = ? AND key = ?').get(userId, key) as unknown as IdemRow) ?? null;
    },
    completeIdem(userId: string, key: string, response: string) {
      q(`UPDATE idempotency SET status = 'done', response = ? WHERE user_id = ? AND key = ?`).run(response, userId, key);
    },
    releaseIdem(userId: string, key: string) {
      q(`DELETE FROM idempotency WHERE user_id = ? AND key = ? AND status = 'pending'`).run(userId, key);
    },

    listIntegrations(userId: string): IntegrationRow[] {
      return q('SELECT provider, status, connected_at, config_enc FROM integrations WHERE user_id = ?').all(userId) as IntegrationRow[];
    },
    putIntegration(userId: string, r: IntegrationRow) {
      q(`INSERT INTO integrations (user_id, provider, status, connected_at, config_enc) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(user_id, provider) DO UPDATE SET status = excluded.status, connected_at = excluded.connected_at, config_enc = excluded.config_enc`)
        .run(userId, r.provider, r.status, r.connected_at, r.config_enc);
    },

    paidSince(userId: string, since: number): { currency: string; cents: number }[] {
      return q(`SELECT currency, SUM(amount_cents) AS cents FROM (
                  SELECT currency, amount_cents FROM invoices WHERE user_id = ? AND paid_at >= ?
                  UNION ALL SELECT currency, amount_cents FROM orders WHERE user_id = ? AND paid_at >= ?)
                GROUP BY currency`).all(userId, since, userId, since) as { currency: string; cents: number }[];
    },
    unpaidCount(userId: string): number {
      return (q(`SELECT COUNT(*) AS n FROM invoices WHERE user_id = ? AND paid_at IS NULL AND status NOT IN ('CANCELLED', 'REFUNDED')`)
        .get(userId) as { n: number }).n;
    },
  };
}
