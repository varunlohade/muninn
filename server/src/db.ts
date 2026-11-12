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
CREATE TABLE IF NOT EXISTS shared_images (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), png BLOB NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS shared_images_expiry ON shared_images(expires_at);
CREATE TABLE IF NOT EXISTS profiles (
  user_id TEXT PRIMARY KEY REFERENCES users(id), business_name TEXT NOT NULL, tone TEXT NOT NULL, currency TEXT NOT NULL, review_url TEXT);
CREATE TABLE IF NOT EXISTS catalog_items (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), name TEXT NOT NULL,
  price_cents INTEGER NOT NULL, currency TEXT NOT NULL, created_at INTEGER NOT NULL,
  description TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT '', in_stock INTEGER NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0, photo_id TEXT);
-- One photo per catalog item, encrypted with the owner's key. id is random, so a new photo gets a new id.
CREATE TABLE IF NOT EXISTS catalog_photos (
  item_id TEXT PRIMARY KEY REFERENCES catalog_items(id) ON DELETE CASCADE, user_id TEXT NOT NULL REFERENCES users(id),
  id TEXT NOT NULL, mime TEXT NOT NULL, data_enc TEXT NOT NULL, bytes INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS invoices (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), status TEXT NOT NULL,
  amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, item TEXT NOT NULL,
  client_name_enc TEXT, client_email_enc TEXT, pay_link TEXT, due_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL, paid_at INTEGER, capture_id TEXT, source TEXT NOT NULL DEFAULT 'app', seed_key TEXT, pp_account TEXT);
CREATE TABLE IF NOT EXISTS orders (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), status TEXT NOT NULL,
  amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, item TEXT NOT NULL,
  client_name_enc TEXT, approve_link TEXT, created_at INTEGER NOT NULL, paid_at INTEGER, capture_id TEXT, pp_account TEXT);
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
CREATE TABLE IF NOT EXISTS subscriptions (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), status TEXT NOT NULL,
  amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, interval TEXT NOT NULL, item TEXT NOT NULL,
  client_name_enc TEXT, client_email_enc TEXT, approve_link TEXT, plan_id TEXT NOT NULL, created_at INTEGER NOT NULL,
  activated_at INTEGER, last_paid_at INTEGER, paid_count INTEGER NOT NULL DEFAULT 0, pp_account TEXT);
CREATE TABLE IF NOT EXISTS billing_plans (
  user_id TEXT NOT NULL REFERENCES users(id), plan_key TEXT NOT NULL, product_id TEXT NOT NULL, plan_id TEXT NOT NULL,
  PRIMARY KEY (user_id, plan_key));
CREATE TABLE IF NOT EXISTS subscription_payments (
  sale_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), subscription_id TEXT NOT NULL, paid_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS paypal_connections (
  user_id TEXT PRIMARY KEY REFERENCES users(id), tracking_hash TEXT NOT NULL UNIQUE, status TEXT NOT NULL,
  merchant_hash TEXT, merchant_enc TEXT, email_enc TEXT, payments_receivable INTEGER NOT NULL DEFAULT 0, email_confirmed INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL, connected_at INTEGER, verified_enc TEXT, code_hash TEXT, code_expires_at INTEGER);
CREATE UNIQUE INDEX IF NOT EXISTS paypal_connections_merchant ON paypal_connections(merchant_hash) WHERE merchant_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS subscriptions_user ON subscriptions(user_id, created_at);
CREATE INDEX IF NOT EXISTS refunds_target ON refunds(user_id, target_id, status);
CREATE UNIQUE INDEX IF NOT EXISTS invoices_seed ON invoices(user_id, seed_key) WHERE seed_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS invoices_user ON invoices(user_id, created_at);
CREATE INDEX IF NOT EXISTS orders_user ON orders(user_id, created_at);
CREATE INDEX IF NOT EXISTS catalog_user ON catalog_items(user_id);
`;

// review_url: left out keeps the stored link, null clears it.
export type Profile = { business_name: string; tone: string; currency: string; review_url?: string | null };
export type CatalogItem = { id: string; name: string; price_cents: number; currency: string };
export type CatalogDetails = { description: string; category: string; in_stock: boolean };
export type CatalogRow = CatalogItem & CatalogDetails & { sort_order: number; photo_id: string | null };
export type CatalogPhoto = { id: string; mime: string; data_enc: string; bytes?: number };
export type InvoiceRow = {
  id: string; user_id: string; status: string; amount_cents: number; currency: string; item: string;
  client_name_enc: string | null; client_email_enc: string | null; pay_link: string | null;
  due_at: number; created_at: number; paid_at: number | null; capture_id: string | null;
  source: 'app' | 'demo_seed'; seed_key: string | null; pp_account: string | null;
};
export type OrderRow = {
  id: string; user_id: string; status: string; amount_cents: number; currency: string; item: string;
  client_name_enc: string | null; approve_link: string | null; created_at: number; paid_at: number | null; capture_id: string | null;
  pp_account: string | null;
};
export type RefundRow = {
  id: string; user_id: string; target_kind: 'invoice' | 'order'; target_id: string; amount_cents: number; currency: string;
  capture_id: string; token_hash: string; expires_at: number; status: string; paypal_refund_id: string | null;
};

export type SubscriptionRow = {
  id: string; user_id: string; status: string; amount_cents: number; currency: string; interval: string; item: string;
  client_name_enc: string | null; client_email_enc: string | null; approve_link: string | null; plan_id: string; created_at: number;
  activated_at: number | null; last_paid_at: number | null; paid_count: number; pp_account: string | null;
};

export type IntegrationRow = { provider: string; status: string; connected_at: number | null; config_enc: string | null };
// status: 'pending' from Connect until PayPal sends the seller back, then 'connected'. Disconnect or a revoke deletes the row.
export type PayPalConnectionRow = {
  user_id: string; tracking_hash: string; status: 'pending' | 'connected'; merchant_hash: string | null; merchant_enc: string | null;
  email_enc: string | null; payments_receivable: number; email_confirmed: number; created_at: number; connected_at: number | null;
  // After PayPal sends the seller back: the checked merchant (encrypted JSON) and the hash of the one-time code the app must show.
  verified_enc: string | null; code_hash: string | null; code_expires_at: number | null;
};

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
  const profileCols = db.prepare('PRAGMA table_info(profiles)').all() as { name: string }[];
  if (profileCols.length && !profileCols.some((c) => c.name === 'review_url')) db.exec('ALTER TABLE profiles ADD COLUMN review_url TEXT');
  // pp_account: the merchant hash of the connected PayPal account that made the row, or NULL for the shared demo merchant.
  for (const t of ['invoices', 'orders', 'subscriptions']) {
    const cols = db.prepare(`PRAGMA table_info(${t})`).all() as { name: string }[];
    if (cols.length && !cols.some((c) => c.name === 'pp_account')) db.exec(`ALTER TABLE ${t} ADD COLUMN pp_account TEXT`);
  }
  const connCols = db.prepare('PRAGMA table_info(paypal_connections)').all() as { name: string }[];
  for (const [col, type] of [['verified_enc', 'TEXT'], ['code_hash', 'TEXT'], ['code_expires_at', 'INTEGER']]) {
    if (connCols.length && !connCols.some((c) => c.name === col)) db.exec(`ALTER TABLE paypal_connections ADD COLUMN ${col} ${type}`);
  }
  const itemCols = db.prepare('PRAGMA table_info(catalog_items)').all() as { name: string }[];
  for (const [col, type] of [['description', "TEXT NOT NULL DEFAULT ''"], ['category', "TEXT NOT NULL DEFAULT ''"],
    ['in_stock', 'INTEGER NOT NULL DEFAULT 1'], ['sort_order', 'INTEGER NOT NULL DEFAULT 0'], ['photo_id', 'TEXT']]) {
    if (itemCols.length && !itemCols.some((c) => c.name === col)) db.exec(`ALTER TABLE catalog_items ADD COLUMN ${col} ${type}`);
  }
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
    /**
     * Attaches an Apple account to a user who started with a device account. `owner` is the user that holds this Apple
     * account afterwards: this user, or the earlier user it already belonged to. Null when this user is saved under another Apple account.
     */
    linkAppleSub(userId: string, subHash: string): { owner: string } | null {
      const find = () => q('SELECT id FROM users WHERE apple_sub_hash = ?').get(subHash) as { id: string } | undefined;
      const held = find();
      if (held) return { owner: held.id };
      try {
        // The unique index settles two links at once: one wins, the other reads the winner.
        if (q('UPDATE users SET apple_sub_hash = ? WHERE id = ? AND apple_sub_hash IS NULL').run(subHash, userId).changes > 0) return { owner: userId };
      } catch {}
      const winner = find();
      return winner ? { owner: winner.id } : null;
    },
    addDevice(userId: string, tokenHash: string, label: string | null) {
      q('INSERT INTO devices (token_hash, user_id, label, created_at) VALUES (?, ?, ?, ?)').run(tokenHash, userId, label, now());
    },
    // A drawing shared as a link. The id is the only way to reach it; no query lists them.
    addSharedImage(id: string, userId: string, png: Uint8Array, createdAt: number, expiresAt: number) {
      q('INSERT INTO shared_images (id, user_id, png, created_at, expires_at) VALUES (?, ?, ?, ?, ?)').run(id, userId, png, createdAt, expiresAt);
    },
    sharedImage(id: string, at: number): Uint8Array | undefined {
      const r = q('SELECT png FROM shared_images WHERE id = ? AND expires_at > ?').get(id, at) as { png: Uint8Array } | undefined;
      return r?.png;
    },
    purgeSharedImages(at: number): number {
      return Number(q('DELETE FROM shared_images WHERE expires_at <= ?').run(at).changes);
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
      const p = q('SELECT business_name, tone, currency, review_url FROM profiles WHERE user_id = ?').get(userId) as Profile | undefined;
      return p && { ...p };
    },
    putProfile(userId: string, p: Profile) {
      q(`INSERT INTO profiles (user_id, business_name, tone, currency, review_url) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(user_id) DO UPDATE SET business_name = excluded.business_name, tone = excluded.tone, currency = excluded.currency,
           review_url = CASE WHEN ? THEN excluded.review_url ELSE profiles.review_url END`)
        .run(userId, p.business_name, p.tone, p.currency, p.review_url ?? null, p.review_url === undefined ? 0 : 1);
    },

    allItems(): (CatalogItem & { user_id: string })[] {
      return q('SELECT id, user_id, name, price_cents, currency FROM catalog_items').all() as (CatalogItem & { user_id: string })[];
    },
    allProfiles(): (Profile & { user_id: string })[] {
      return q('SELECT user_id, business_name, tone, currency FROM profiles').all() as (Profile & { user_id: string })[];
    },
    listItems(userId: string): CatalogRow[] {
      const rows = q(`SELECT id, name, price_cents, currency, description, category, in_stock, sort_order, photo_id FROM catalog_items
        WHERE user_id = ? ORDER BY sort_order, created_at`).all(userId) as (Omit<CatalogRow, 'in_stock'> & { in_stock: number })[];
      return rows.map((r) => ({ ...r, in_stock: r.in_stock === 1 }));
    },
    addItem(userId: string, it: Omit<CatalogItem, 'id'> & Partial<CatalogDetails>): CatalogRow {
      const id = randomUUID();
      const d = { description: it.description ?? '', category: it.category ?? '', in_stock: it.in_stock ?? true };
      const { next } = q('SELECT COALESCE(MAX(sort_order) + 1, 0) AS next FROM catalog_items WHERE user_id = ?').get(userId) as { next: number };
      q(`INSERT INTO catalog_items (id, user_id, name, price_cents, currency, created_at, description, category, in_stock, sort_order)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(id, userId, it.name, it.price_cents, it.currency, now(), d.description, d.category, d.in_stock ? 1 : 0, next);
      return { id, name: it.name, price_cents: it.price_cents, currency: it.currency, ...d, sort_order: next, photo_id: null };
    },
    // Details left out keep their stored values.
    updateItem(userId: string, id: string, it: Omit<CatalogItem, 'id'> & Partial<CatalogDetails>): boolean {
      return q(`UPDATE catalog_items SET name = ?, price_cents = ?, currency = ?, description = COALESCE(?, description),
          category = COALESCE(?, category), in_stock = COALESCE(?, in_stock) WHERE id = ? AND user_id = ?`)
        .run(it.name, it.price_cents, it.currency, it.description ?? null, it.category ?? null,
          it.in_stock === undefined ? null : it.in_stock ? 1 : 0, id, userId).changes > 0;
    },
    countItems(userId: string): number {
      return (q('SELECT COUNT(*) AS n FROM catalog_items WHERE user_id = ?').get(userId) as { n: number }).n;
    },
    /** Bytes of the owner's stored photos, leaving out the photo of `exceptItem` (the one an upload replaces). */
    photoBytes(userId: string, exceptItem: string): number {
      return (q('SELECT COALESCE(SUM(bytes), 0) AS n FROM catalog_photos WHERE user_id = ? AND item_id != ?').get(userId, exceptItem) as { n: number }).n;
    },
    deleteItem(userId: string, id: string): boolean {
      return q('DELETE FROM catalog_items WHERE id = ? AND user_id = ?').run(id, userId).changes > 0;
    },
    /** Sets the order to `ids`, which must be exactly the owner's item ids. */
    reorderItems(userId: string, ids: string[]): 'ok' | 'not_found' | 'incomplete' {
      const own = new Set((q('SELECT id FROM catalog_items WHERE user_id = ?').all(userId) as { id: string }[]).map((r) => r.id));
      if (ids.some((id) => !own.has(id))) return 'not_found';
      if (new Set(ids).size !== ids.length || ids.length !== own.size) return 'incomplete';
      const set = q('UPDATE catalog_items SET sort_order = ? WHERE id = ? AND user_id = ?');
      db.exec('BEGIN');
      try {
        ids.forEach((id, i) => set.run(i, id, userId));
        db.exec('COMMIT');
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
      return 'ok';
    },
    putItemPhoto(userId: string, itemId: string, p: CatalogPhoto): boolean {
      if (!q('SELECT 1 FROM catalog_items WHERE id = ? AND user_id = ?').get(itemId, userId)) return false;
      q(`INSERT INTO catalog_photos (item_id, user_id, id, mime, data_enc, bytes, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(item_id) DO UPDATE SET id = excluded.id, mime = excluded.mime, data_enc = excluded.data_enc, bytes = excluded.bytes,
           created_at = excluded.created_at`)
        .run(itemId, userId, p.id, p.mime, p.data_enc, p.bytes ?? 0, now());
      q('UPDATE catalog_items SET photo_id = ? WHERE id = ? AND user_id = ?').run(p.id, itemId, userId);
      return true;
    },
    getItemPhoto(userId: string, itemId: string): CatalogPhoto | undefined {
      return q('SELECT id, mime, data_enc FROM catalog_photos WHERE item_id = ? AND user_id = ?').get(itemId, userId) as CatalogPhoto | undefined;
    },
    deleteItemPhoto(userId: string, itemId: string): boolean {
      q('UPDATE catalog_items SET photo_id = NULL WHERE id = ? AND user_id = ?').run(itemId, userId);
      return q('DELETE FROM catalog_photos WHERE item_id = ? AND user_id = ?').run(itemId, userId).changes > 0;
    },

    insertInvoice(r: Omit<InvoiceRow, 'paid_at' | 'capture_id' | 'source' | 'seed_key' | 'pp_account'> & Partial<Pick<InvoiceRow, 'source' | 'seed_key' | 'pp_account'>>) {
      q(`INSERT OR IGNORE INTO invoices (id, user_id, status, amount_cents, currency, item, client_name_enc, client_email_enc, pay_link, due_at, created_at, source, seed_key, pp_account)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(r.id, r.user_id, r.status, r.amount_cents, r.currency, r.item, r.client_name_enc, r.client_email_enc, r.pay_link, r.due_at, r.created_at,
          r.source ?? 'app', r.seed_key ?? null, r.pp_account ?? null);
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

    insertOrder(r: Omit<OrderRow, 'paid_at' | 'capture_id' | 'pp_account'> & Partial<Pick<OrderRow, 'pp_account'>>) {
      q(`INSERT OR IGNORE INTO orders (id, user_id, status, amount_cents, currency, item, client_name_enc, approve_link, created_at, pp_account)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(r.id, r.user_id, r.status, r.amount_cents, r.currency, r.item, r.client_name_enc, r.approve_link, r.created_at, r.pp_account ?? null);
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

    insertSubscription(r: Omit<SubscriptionRow, 'activated_at' | 'last_paid_at' | 'paid_count' | 'pp_account'> & Partial<Pick<SubscriptionRow, 'pp_account'>>) {
      q(`INSERT OR IGNORE INTO subscriptions (id, user_id, status, amount_cents, currency, interval, item, client_name_enc, client_email_enc, approve_link, plan_id, created_at, pp_account)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(r.id, r.user_id, r.status, r.amount_cents, r.currency, r.interval, r.item, r.client_name_enc, r.client_email_enc, r.approve_link, r.plan_id, r.created_at, r.pp_account ?? null);
    },
    getSubscription(userId: string, id: string): SubscriptionRow | undefined {
      return q('SELECT * FROM subscriptions WHERE id = ? AND user_id = ?').get(id, userId) as SubscriptionRow | undefined;
    },
    listSubscriptions(userId: string, limit = 50): SubscriptionRow[] {
      return q('SELECT * FROM subscriptions WHERE user_id = ? ORDER BY created_at DESC LIMIT ?').all(userId, limit) as SubscriptionRow[];
    },
    ownerOfSubscription(id: string): string | undefined {
      return (q('SELECT user_id FROM subscriptions WHERE id = ?').get(id) as { user_id: string } | undefined)?.user_id;
    },
    setSubscriptionActive(userId: string, id: string, at: number) {
      q(`UPDATE subscriptions SET status = 'ACTIVE', activated_at = COALESCE(activated_at, ?) WHERE id = ? AND user_id = ?`).run(at, id, userId);
    },
    setSubscriptionStatus(userId: string, id: string, status: 'CANCELLED' | 'SUSPENDED') {
      q('UPDATE subscriptions SET status = ? WHERE id = ? AND user_id = ?').run(status, id, userId);
    },
    // One row per PayPal sale, so a webhook PayPal sends twice counts once. True when this sale is new.
    addSubscriptionPayment(userId: string, id: string, saleId: string, at: number): boolean {
      const added = q('INSERT OR IGNORE INTO subscription_payments (sale_id, user_id, subscription_id, paid_at) VALUES (?, ?, ?, ?)')
        .run(saleId, userId, id, at).changes > 0;
      if (added) q(`UPDATE subscriptions SET last_paid_at = ?, paid_count = paid_count + 1 WHERE id = ? AND user_id = ?`).run(at, id, userId);
      return added;
    },
    getBillingPlan(userId: string, planKey: string): { product_id: string; plan_id: string } | undefined {
      return q('SELECT product_id, plan_id FROM billing_plans WHERE user_id = ? AND plan_key = ?').get(userId, planKey) as { product_id: string; plan_id: string } | undefined;
    },
    // account: '' for the demo merchant, or the 'm:<id>:' prefix a connected seller's plan keys carry. Products never cross accounts.
    anyBillingProduct(userId: string, account = ''): string | null {
      const r = account
        ? q('SELECT product_id FROM billing_plans WHERE user_id = ? AND substr(plan_key, 1, ?) = ? LIMIT 1').get(userId, account.length, account)
        : q("SELECT product_id FROM billing_plans WHERE user_id = ? AND plan_key NOT LIKE 'm:%' LIMIT 1").get(userId);
      return (r as { product_id: string } | undefined)?.product_id ?? null;
    },
    putBillingPlan(userId: string, planKey: string, productId: string, planId: string) {
      q('INSERT OR IGNORE INTO billing_plans (user_id, plan_key, product_id, plan_id) VALUES (?, ?, ?, ?)').run(userId, planKey, productId, planId);
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

    getPayPalConnection(userId: string): PayPalConnectionRow | undefined {
      return q('SELECT * FROM paypal_connections WHERE user_id = ?').get(userId) as PayPalConnectionRow | undefined;
    },
    payPalConnectionByTracking(trackingHash: string): PayPalConnectionRow | undefined {
      return q('SELECT * FROM paypal_connections WHERE tracking_hash = ?').get(trackingHash) as PayPalConnectionRow | undefined;
    },
    payPalConnectionByCode(codeHash: string): PayPalConnectionRow | undefined {
      return q("SELECT * FROM paypal_connections WHERE code_hash = ? AND status = 'pending'").get(codeHash) as PayPalConnectionRow | undefined;
    },
    // PayPal checked the merchant for this pending Connect. A null code keeps the one there (the webhook has none to give).
    verifyPayPalConnect(userId: string, trackingHash: string, verifiedEnc: string, codeHash: string | null, codeExpiresAt: number | null): boolean {
      return q(`UPDATE paypal_connections SET verified_enc = ?, code_hash = COALESCE(?, code_hash), code_expires_at = COALESCE(?, code_expires_at)
                WHERE user_id = ? AND tracking_hash = ? AND status = 'pending'`).run(verifiedEnc, codeHash, codeExpiresAt, userId, trackingHash).changes > 0;
    },
    // A new Connect replaces a pending one. False when this user is already connected.
    startPayPalConnect(userId: string, trackingHash: string, at: number): boolean {
      return q(`INSERT INTO paypal_connections (user_id, tracking_hash, status, created_at) VALUES (?, ?, 'pending', ?)
                ON CONFLICT(user_id) DO UPDATE SET tracking_hash = excluded.tracking_hash, created_at = excluded.created_at,
                  verified_enc = NULL, code_hash = NULL, code_expires_at = NULL
                WHERE paypal_connections.status = 'pending'`).run(userId, trackingHash, at).changes > 0;
    },
    // Only the pending row with this tracking id becomes connected. False when another user already holds this merchant.
    finishPayPalConnect(userId: string, trackingHash: string, r: Pick<PayPalConnectionRow, 'merchant_hash' | 'merchant_enc' | 'email_enc' | 'payments_receivable' | 'email_confirmed'>): boolean {
      try {
        return q(`UPDATE paypal_connections SET status = 'connected', merchant_hash = ?, merchant_enc = ?, email_enc = ?, payments_receivable = ?, email_confirmed = ?, connected_at = ?,
                  verified_enc = NULL, code_hash = NULL, code_expires_at = NULL
                  WHERE user_id = ? AND tracking_hash = ? AND status = 'pending'`)
          .run(r.merchant_hash, r.merchant_enc, r.email_enc, r.payments_receivable, r.email_confirmed, now(), userId, trackingHash).changes > 0;
      } catch {
        return false;
      }
    },
    setPayPalFlags(userId: string, receivable: boolean, confirmed: boolean) {
      q(`UPDATE paypal_connections SET payments_receivable = ?, email_confirmed = ? WHERE user_id = ? AND status = 'connected'`).run(Number(receivable), Number(confirmed), userId);
    },
    removePayPalConnection(userId: string): boolean {
      return q('DELETE FROM paypal_connections WHERE user_id = ?').run(userId).changes > 0;
    },
    removePayPalByMerchant(merchantHash: string): string | undefined {
      const r = q('DELETE FROM paypal_connections WHERE merchant_hash = ? RETURNING user_id').get(merchantHash) as { user_id: string } | undefined;
      return r?.user_id;
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
