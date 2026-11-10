import { z } from 'zod';
import { config } from './config.ts';

export function amountToCents(v: unknown): number | null {
  const s = typeof v === 'number' ? (Number.isFinite(v) ? String(v) : '') : typeof v === 'string' ? v.trim().replace(/^[$€£]/, '') : '';
  if (!/^\d{1,7}(\.\d{1,2})?$/.test(s)) return null;
  const [whole, frac = ''] = s.split('.');
  const cents = Number(whole) * 100 + Number(frac.padEnd(2, '0'));
  if (cents <= 0 || cents > config.money.maxAmount * 100) return null;
  return cents;
}

// PayPal report values: signed, no upper cap (a balance or a large sale is fine here).
export function valueToCents(v: string): number | null {
  const m = /^(-?)(\d{1,12})(?:\.(\d{1,2}))?$/.exec(v.trim());
  if (!m) return null;
  const cents = Number(m[2]) * 100 + Number((m[3] ?? '').padEnd(2, '0'));
  return m[1] ? -cents : cents;
}

export const centsToValue = (cents: number) => (cents / 100).toFixed(2);

export const Amount = z.union([z.number(), z.string()]).transform((v, ctx) => {
  const cents = amountToCents(v);
  if (cents === null) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: `amount must be > 0, at most ${config.money.maxAmount}, with up to 2 decimals` });
    return z.NEVER;
  }
  return cents;
});

export const Currency = z.string().trim().toUpperCase().pipe(z.enum(config.money.currencies));

const SYMBOL: Record<string, string> = { USD: '$', CAD: 'CA$', AUD: 'A$', EUR: '€', GBP: '£' };

export function formatMoney(cents: number, currency: string): string {
  const v = cents % 100 === 0 ? String(cents / 100) : centsToValue(cents);
  return `${SYMBOL[currency] ?? currency + ' '}${v}`;
}
