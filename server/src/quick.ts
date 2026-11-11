// Regex-first reading of a suggest message: the deterministic parts cost no model call.

export type Quick = {
  /** True when no model can find a payment action here, so suggest returns no chips with no paid call. */
  none: boolean;
  /** The one amount stated, or null when there is none or more than one. */
  amount: number | null;
  /** Set only for an explicit currency (€, £, CA$, A$, EUR, ...). A bare $ stays null: it can be USD, CAD or AUD. */
  currency: string | null;
  /** The one email in the owner's own text, lowercased, or null. */
  email: string | null;
};

const NUM = String.raw`(?<whole>\d{1,3}(?:,\d{3})+|\d+)(?:\.(?<frac>\d{1,2}))?(?![\d,.]*\d)`;
const PREFIX: Record<string, string | null> = { 'us$': 'USD', 'ca$': 'CAD', 'a$': 'AUD', 'au$': 'AUD', $: null, '€': 'EUR', '£': 'GBP' };
const WORD: Record<string, string | null> = {
  usd: 'USD', eur: 'EUR', gbp: 'GBP', cad: 'CAD', aud: 'AUD', dollar: null, dollars: null, bucks: null, euro: 'EUR', euros: 'EUR',
};
const AMOUNTS = [
  // $60, €45.50, CA$1,200, usd 60
  new RegExp(String.raw`(?<cur>us\$|ca\$|au?\$|\$|€|£|\b(?:usd|eur|gbp|cad|aud)\b)\s?${NUM}`, 'gi'),
  // 60 usd, 45 euros, 60$, 45€
  new RegExp(String.raw`(?<![\w.,])${NUM}\s?(?<cur>\$|€|£|(?:usd|eur|gbp|cad|aud|dollars?|bucks|euros?)\b)`, 'gi'),
];
const EMAIL = /[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}/gi;
const MONEY_WORDS = new RegExp(String.raw`\b(?:${[
  'invoic\\w*', 'bill\\w*', 'pay\\w*', 'paid', 'owe[sd]?', 'owing', 'refund\\w*', 'remind\\w*', 'link',
  'price[sd]?', 'pricing', 'cost\\w*', 'charge[sd]?', 'how much', 'rates?', 'quote', 'fees?', 'total', 'due', 'overdue', 'late',
  'money', 'cash', 'deposit', 'balance', 'receipt', 'venmo', 'paypal', 'transfer', 'tip', 'reimburse\\w*',
  'available', 'availability', 'services?', 'products?', 'menu', 'catalog\\w*', 'in stock', 'sell', 'buy',
].join('|')})\b`, 'i');
// Letters outside plain A-Z: another language or script. The word list is English, so those go to the model.
const OTHER_SCRIPT = /[^\P{L}A-Za-z]/u;

function amountsIn(text: string): { amount: number; currency: string | null }[] {
  const out: { amount: number; currency: string | null }[] = [];
  for (const re of AMOUNTS) {
    for (const m of text.matchAll(re)) {
      const { whole, frac, cur } = m.groups!;
      const c = cur.toLowerCase();
      out.push({ amount: Number(`${whole.replace(/,/g, '')}${frac ? `.${frac}` : ''}`), currency: PREFIX[c] ?? WORD[c] ?? null });
    }
  }
  return out;
}

const one = <T>(xs: T[], key: (x: T) => string): T | null => (new Set(xs.map(key)).size === 1 ? xs[0] : null);

/** text: what the owner typed. context: text the owner copied from the client (may help with amounts, never with emails). */
export function quick(text: string, context = ''): Quick {
  const all = `${context}\n${text}`;
  const amounts = amountsIn(all);
  const amt = one(amounts, (a) => String(a.amount));
  const currency = one(amounts.map((a) => a.currency).filter((c) => c !== null), (c) => c);
  const emails = [...text.matchAll(EMAIL)].map((m) => m[0].toLowerCase());
  const none = amounts.length === 0 && !MONEY_WORDS.test(all) && !OTHER_SCRIPT.test(all);
  return { none, amount: amt?.amount ?? null, currency: amt ? currency : null, email: one(emails, (e) => e) };
}

/** True when `name` appears as whole words in `text` (case-insensitive). */
export function mentions(text: string, name: string): boolean {
  const n = name.trim();
  if (n.length < 2) return false;
  return new RegExp(String.raw`(?<![\p{L}\d])${n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\p{L}\d])`, 'iu').test(text);
}
