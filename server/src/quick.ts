// Regex-first reading of a suggest message: the deterministic parts cost no model call.

export type Quick = {
  /** True when no model can find a payment action here, so suggest returns no chips with no paid call. */
  none: boolean;
  /** The one amount the owner typed, or null when there is none, more than one, or one that is not a plain total. */
  amount: number | null;
  /** True when the owner typed no amount and the copied client text has one. */
  clientAmountOnly: boolean;
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
  new RegExp(String.raw`(?<cur>us\$|ca\$|au?\$|\$|€|£|\b(?:usd|eur|gbp|cad|aud)\b)\s?${NUM}`, 'gid'),
  // 60 usd, 45 euros, 60$, 45€
  new RegExp(String.raw`(?<![\w.,])${NUM}\s?(?<cur>\$|€|£|(?:usd|eur|gbp|cad|aud|dollars?|bucks|euros?)\b)`, 'gid'),
];
// $2k, $45 each, $45 x 3, $45 per hour: not the total, so the model decides.
const NOT_TOTAL_AFTER = /^\s?(?:k|m|x|each|per|ea)\b/i;
// 3 haircuts at $45, 2 trims @ $20, 3x $45: a unit price after a quantity.
const QUANTITY_BEFORE = /\b\d+\s*(?:x|@|[\p{L}-]+\s+(?:at|@))\s*$/iu;
// A number that reads like a price with no currency or money word: "do 45 for the cut", "€1.200".
const PRICE_SHAPE = /[$€£]\s?\d|\d\s?[$€£]|\b\d+(?:[.,]\d+)*\s+for\b|\b(?:do|for)\s+\d/i;
// Rule A: a regex amount needs exactly one number in the owner's text and no rate or multiplier.
const NUMBER = /\d+(?:[.,]\d+)*|\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|dozens?|half)\b/gi;
// A discount, tip, part payment or quantity word: the number may not be the total.
const RATE = /[×*]|\d\s*x|\bx\s*\d|\b(?:x|times|each|per|ea|hours?|hrs?|months?|people|pax|off|minus|discount\w*|less|tips?|plus|extra|couple|twice|both|half|double|deposit|partial|split)\b|\/\s*(?:hr|h|mo)\b/i;
// $45/person, 45 usd/day, €300 / week: "/word" right after an amount is a rate, not a link.
const SLASH_RATE = /(\d\s*(?:[$€£]|(?:usd|eur|gbp|cad|aud|dollars?|bucks|euros?)\b)?)\s*\/\s*(?=\p{L})/iu;
const URL = /\S*\/\S*/g;
/** Text with every URL-like token (anything with a slash) removed, so an email inside a link never counts as typed. */
export const withoutUrls = (text: string) => text.replace(URL, ' ');
const EMAIL = /[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}/gi;
const MONEY_WORDS = new RegExp(String.raw`\b(?:${[
  'invoic\\w*', 'bill\\w*', 'pay\\w*', 'paid', 'owe[sd]?', 'owing', 'refund\\w*', 'remind\\w*', 'link',
  'price[sd]?', 'pricing', 'cost\\w*', 'charge[sd]?', 'how much', 'rates?', 'quote', 'fees?', 'total', 'due', 'overdue', 'late',
  'money', 'cash', 'deposit', 'balance', 'receipt', 'venmo', 'paypal', 'transfer', 'tip', 'reimburse\\w*',
  'available', 'availability', 'services?', 'products?', 'menu', 'catalog\\w*', 'in stock', 'sell', 'buy',
].join('|')})\b`, 'i');
// Letters outside plain A-Z: another language or script. The word list is English, so those go to the model.
const OTHER_SCRIPT = /[^\P{L}A-Za-z]/u;

type Found = { at: number; amount: number; currency: string | null; total: boolean };

function amountsIn(text: string): Found[] {
  const out: Found[] = [];
  for (const re of AMOUNTS) {
    for (const m of text.matchAll(re)) {
      const { whole, frac, cur } = m.groups!;
      const c = cur.toLowerCase();
      const total = !NOT_TOTAL_AFTER.test(text.slice(m.index + m[0].length)) && !QUANTITY_BEFORE.test(text.slice(0, m.index));
      out.push({ at: m.indices!.groups!.whole[0], amount: Number(`${whole.replace(/,/g, '')}${frac ? `.${frac}` : ''}`), currency: PREFIX[c] ?? WORD[c] ?? null, total });
    }
  }
  return out;
}

const one = <T>(xs: T[], key: (x: T) => string): T | null => (new Set(xs.map(key)).size === 1 ? xs[0] : null);

/** The single plain total in `found`: one number (by position; "$45 USD" is one), not a unit price or a 2k. */
function single(found: Found[]): Found | null {
  const at = one(found, (a) => String(a.at));
  return at && found.every((a) => a.total) ? at : null;
}

/** text: what the owner typed. context: text the owner copied from the client (a money signal, never a field). */
export function quick(text: string, context = ''): Quick {
  const all = `${context}\n${text}`;
  const typed = amountsIn(text);
  const copied = amountsIn(context);
  const plain = text.replace(EMAIL, ' ');
  const amt = (plain.match(NUMBER) ?? []).length === 1 && !RATE.test(plain) && !SLASH_RATE.test(plain) ? single(typed) : null;
  const currency = one(typed.map((a) => a.currency).filter((c) => c !== null), (c) => c);
  const emails = typedEmails(text);
  const none = typed.length + copied.length === 0 && !MONEY_WORDS.test(all) && !PRICE_SHAPE.test(all) && !OTHER_SCRIPT.test(all);
  return {
    none, amount: amt?.amount ?? null, clientAmountOnly: typed.length === 0 && copied.length > 0,
    currency: amt ? currency : null, email: one(emails, (e) => e),
  };
}

// Words that add nothing to a money request. Any other word next to a regex amount sends the request to the model too.
const FILLER = new Set(['a', 'an', 'the', 'for', 'to', 'of', 'is', 'it', 'this', 'that', 'here', "here's", 'heres', 'please', 'pls', 'and', 'my', 'your', 'you', 'me', 'send', 'make', 'create', 'new', 'now', 'with']);

/** The emails the owner typed, lowercased. Links do not count. */
export const typedEmails = (text: string) => [...withoutUrls(text).matchAll(EMAIL)].map((m) => m[0].toLowerCase());

/** True when every word of `text` is an amount, an email, a currency or money word, a filler word, or one of `names`. */
export function onlyKnownWords(text: string, names: string[]): boolean {
  let rest = withoutUrls(text.replace(new RegExp(SLASH_RATE, 'giu'), '$1 ')).replace(EMAIL, ' ');
  for (const n of names) if (n.trim().length >= 2) rest = rest.replace(wholeWords(n.trim(), 'giu'), ' ');
  const words = rest.toLowerCase().match(/[\p{L}']+/gu) ?? [];
  return words.every((w) => FILLER.has(w) || Object.hasOwn(WORD, w) || MONEY_WORDS.test(w));
}

const wholeWords = (n: string, flags: string) =>
  new RegExp(String.raw`(?<![\p{L}\d])${n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\p{L}\d])`, flags);

/** True when `name` appears as whole words in `text` (case-insensitive). */
export function mentions(text: string, name: string): boolean {
  const n = name.trim();
  if (n.length < 2) return false;
  return wholeWords(n, 'iu').test(text);
}

// ---- Ask router, step 0: what the regex can settle with no model call.
const GREETING = /^(?:(?:hi+|hello|hey|yo|sup|thanks|thank you|thx|ok|okay|k|lol|cool|nice|great|bye|good (?:morning|afternoon|evening|night))(?:\s+(?:there|muninn|again|so much|a lot))?[\s!.?,]*)+$/i;
const MONEY_ACTION = /\b(?:invoic\w*|bill\w*|charge\w*|pay\s?link|refund\w*|remind\w*)\b/i;
const NOTE_PREFIX = /^(?:please\s+)?(?:(?:add|save|make|take|create|write)\s+)?(?:(?:a|new|this as a)\s+)*note(?:\s+to self)?\b\s*(?:[:\-,]|that\b|saying\b)?\s*/i;

export type AskQuick = {
  /** True for an empty request or a plain greeting: route "none" with no paid call. */
  none: boolean;
  /** The group when the words alone make it obvious, so the router skips its first question. */
  group: 'money' | 'device' | null;
};

/** A request that starts as a note is a note, even when the note is about money. */
export function askQuick(text: string): AskQuick {
  const t = text.trim();
  if (!t || GREETING.test(t)) return { none: true, group: null };
  if (NOTE_PREFIX.test(t)) return { none: false, group: 'device' };
  return { none: false, group: amountsIn(t).length > 0 && MONEY_ACTION.test(t) ? 'money' : null };
}

// A repeat bill: "every month", "monthly", "weekly", "every year". "every 2 weeks" is not read, so no chip guesses it.
const INTERVAL = /\b(?:every\s+(week|month|year)|(week|month|year)ly|annually)\b/gi;
// Words that change the interval or end the bill after a count. A plan here has one plain interval and no end, so these give no chip.
const COUNT = '(?:\\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)';
const NOT_PLAIN = new RegExp(`\\b(?:bi|semi)[\\s-]?(?:week|month|year|annual)|\\btwice\\b|\\bevery\\s+(?:other|second|third|${COUNT})\\b`, 'i');
const ENDS = new RegExp(`\\bfor\\s+${COUNT}\\s+(?:weeks?|months?|years?)\\b|\\b${COUNT}\\s+times\\b`, 'i');

/** True when the text gives the repeat bill an end: "for 3 months", "3 times". */
export const repeatEnds = (text: string) => ENDS.test(text);

/** The one plain repeat interval in the text, or null when there is none, more than one, or the text changes or ends it. */
export function intervalOf(text: string): 'week' | 'month' | 'year' | null {
  if (NOT_PLAIN.test(text) || ENDS.test(text)) return null;
  const found = new Set([...text.matchAll(INTERVAL)].map((m) => (m[1] ?? m[2] ?? 'year').toLowerCase() as 'week' | 'month' | 'year'));
  return found.size === 1 ? [...found][0] : null;
}

/** The text with its interval words removed, so "$40 every month" reads as one plain amount. */
export const withoutInterval = (text: string) => text.replace(INTERVAL, ' ');

/** "add a note: buy shampoo" gives "buy shampoo". Text with no note prefix comes back whole. */
export const noteText = (text: string) => text.trim().replace(NOTE_PREFIX, '').trim();
