// PayPal actions beyond invoices, pay links and refunds. Chips come from plain regex and the owner's own records,
// never from a model. Every action sits under /v1/actions/*, so it gets the tap gate and the per-chip idempotency key.
import type { Chip } from './app.ts';
import { payoutAsk } from './quick.ts';

export function createMore() {
  /** The chips for a more-verb, or null when the text is not one. No paid call. */
  async function suggest(_userId: string, text: string): Promise<Chip[] | null> {
    // "pay joe $200" is a payout, never a pay link. Until payouts ship it gets no chip.
    if (payoutAsk(text)) return [];
    return null;
  }

  return { suggest };
}
