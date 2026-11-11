import { z } from 'zod';
import type { Cipher } from './crypto.ts';
import type { Db } from './db.ts';
import { log } from './log.ts';
import { formatMoney } from './money.ts';

// Only a Slack incoming webhook: https://hooks.slack.com/services/T.../B.../secret. Nothing else gets our posts.
export const SlackWebhookUrl = z.string().trim().max(300)
  .regex(/^https:\/\/hooks\.slack\.com\/services\/[A-Z0-9]+\/[A-Z0-9]+\/[A-Za-z0-9]+$/, 'must be a Slack incoming webhook (https://hooks.slack.com/services/...)');

const TIMEOUT_MS = 3000;
// Slack reads &, < and > as markup.
const escape = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

export function createSlack(db: Db, cipher: Cipher, now: () => number) {
  function put(userId: string, url: string | null) {
    db.putIntegration(userId, url
      ? { provider: 'slack', status: 'connected', connected_at: now(), config_enc: cipher.encrypt(userId, JSON.stringify({ webhook_url: url })) }
      : { provider: 'slack', status: 'not_connected', connected_at: null, config_enc: null });
  }

  function urlFor(userId: string): string | null {
    const row = db.listIntegrations(userId).find((r) => r.provider === 'slack' && r.status === 'connected');
    if (!row?.config_enc) return null;
    try {
      return SlackWebhookUrl.parse(JSON.parse(cipher.decrypt(userId, row.config_enc)).webhook_url);
    } catch {
      log('slack_notify_failed', { user_id: userId, reason: 'stored config unreadable' });
      return null;
    }
  }

  /**
   * "Ana paid $90 · Haircut": first name, amount and item, never an email. One try: a failure is logged with its
   * reason and dropped, so a broken webhook never holds up or repeats the PayPal event.
   */
  async function notifyPaid(userId: string, p: { clientName: string | null; cents: number; currency: string; item: string }) {
    const url = urlFor(userId);
    if (!url) return;
    // Nothing with an @ goes to Slack: a name or item that holds an email is dropped.
    const first = p.clientName?.trim().split(/\s+/)[0];
    const who = first && !first.includes('@') ? first : 'A client';
    const item = p.item.includes('@') ? '' : ` · ${p.item}`;
    const text = escape(`${who} paid ${formatMoney(p.cents, p.currency)}${item}`);
    try {
      const res = await fetch(url, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text }), redirect: 'error', signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      if (!res.ok) log('slack_notify_failed', { user_id: userId, reason: `HTTP ${res.status}` });
      else log('slack_notified', { user_id: userId });
    } catch (e) {
      const err = e as Error & { cause?: { code?: string } };
      log('slack_notify_failed', { user_id: userId, reason: err.name === 'TimeoutError' ? 'timeout' : err.cause?.code ?? err.name });
    }
  }

  return { put, notifyPaid };
}
