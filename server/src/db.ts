import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

const SCHEMA = `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL);
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
  created_at INTEGER NOT NULL, paid_at INTEGER, capture_id TEXT);
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
  user_id TEXT NOT NULL REFERENCES users(id), key TEXT NOT NULL, route TEXT NOT NULL, response TEXT NOT NULL,
  created_at INTEGER NOT NULL, PRIMARY KEY (user_id, key));
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
};
export type OrderRow = {
  id: string; user_id: string; status: string; amount_cents: number; currency: string; item: string;
  client_name_enc: string | null; approve_link: string | null; created_at: number; paid_at: number | null; capture_id: string | null;
};
export type RefundRow = {
  id: string; user_id: string; target_kind: 'invoice' | 'order'; target_id: string; amount_cents: number; currency: string;
  capture_id: string; token_hash: string; expires_at: number; status: string; paypal_refund_id: string | null;
};

export type Db = ReturnType<typeof openDb>;

export function openDb(path: string) {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
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
    addDevice(userId: string, tokenHash: string, label: string | null) {
      q('INSERT INTO devices (token_hash, user_id, label, created_at) VALUES (?, ?, ?, ?)').run(tokenHash, userId, label, now());
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

    insertInvoice(r: Omit<InvoiceRow, 'paid_at' | 'capture_id'>) {
      q(`INSERT OR IGNORE INTO invoices (id, user_id, status, amount_cents, currency, item, client_name_enc, client_email_enc, pay_link, due_at, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(r.id, r.user_id, r.status, r.amount_cents, r.currency, r.item, r.client_name_enc, r.client_email_enc, r.pay_link, r.due_at, r.created_at);
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
    claimRefund(userId: string, tokenHash: string, at: number): RefundRow | undefined {
      return q(`UPDATE refunds SET status = 'running' WHERE token_hash = ? AND user_id = ? AND status = 'pending' AND expires_at > ?
                RETURNING *`).get(tokenHash, userId, at) as RefundRow | undefined;
    },
    finishRefund(userId: string, id: string, status: string, paypalRefundId: string | null) {
      q('UPDATE refunds SET status = ?, paypal_refund_id = ? WHERE id = ? AND user_id = ?').run(status, paypalRefundId, id, userId);
    },

    getIdem(userId: string, key: string): { route: string; response: string } | undefined {
      return q('SELECT route, response FROM idempotency WHERE user_id = ? AND key = ?').get(userId, key) as
        { route: string; response: string } | undefined;
    },
    putIdem(userId: string, key: string, route: string, response: string) {
      q('INSERT OR IGNORE INTO idempotency (user_id, key, route, response, created_at) VALUES (?, ?, ?, ?, ?)')
        .run(userId, key, route, response, now());
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
