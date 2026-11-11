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

// ---- Device actions for /v1/suggest: text with no money signal that may still be an event, a reminder or a note.
// The phone settles clear cases itself ("meeting with Ana tomorrow 3pm"); only an unclear sentence reaches here.
const TASK = /\b(?:remind|call|ring|text|email|buy|pick up|send|order|book|check|follow up|ping|meet\w*|appointment|appt|dentist|doctor|lunch|dinner|coffee|interview|move|reschedule|cancel|don'?t forget|need to|todo|to-?do)\b/i;

/** The last sentence the owner typed. */
export const lastSentence = (text: string) => (text.trim().split('\n').pop() ?? '').split(/(?<=[.!?])\s+(?=\S)/).pop()!.trim();

/** A capitalized word after the first: likely a person ("Ana", "Ana's"). */
export const nameIn = (sentence: string) =>
  sentence.split(/\s+/).slice(1).map((w) => w.replace(/['’]s$|[^\p{L}]/gu, '')).find((w) => w.length > 1 && /^\p{Lu}/u.test(w) && /\p{Ll}/u.test(w)) ?? null;

/**
 * True when the sentence has action-ish signals: a task or meeting word, a time or number, a name, or a question.
 * Plain chat ("lol ok see you") has none, so it costs no call. Same rule as SmartDetect.maybe on the phone.
 */
export function deviceSignal(text: string): boolean {
  const s = lastSentence(text);
  if (s.split(/\s+/).filter(Boolean).length < 4) return false;
  return TASK.test(s) || /\d/.test(s) || nameIn(s) !== null || s.endsWith('?');
}

/** The typed words a money chip came from: "$45 for the haircut", "45 dollars". Null when there is no amount. */
export function moneyTrigger(text: string): string | null {
  const m = text.match(/(?:[$€£]\s?\d+(?:[.,]\d{1,2})?|\b\d+(?:[.,]\d{1,2})?\s?(?:[$€£]|usd|eur|gbp|dollars?|bucks|euros?)\b)(?:\s+for\s+(?:the\s+|a\s+|an\s+|my\s+)?\p{L}+)?/iu);
  return m ? m[0] : null;
}

/** The words a device chip came from: the name, else the task word, else the sentence start. */
export const deviceTrigger = (sentence: string) => nameIn(sentence) ?? sentence.match(TASK)?.[0] ?? sentence.split(/\s+/).slice(0, 3).join(' ');

/** "can we move Ana's thing?" gives "Move Ana's thing": the lead-in and the question mark go. */
export function deviceTitle(sentence: string): string {
  const t = sentence
    .replace(/^(?:(?:hey|ok|okay|so|and|also|please)[\s,]+)*(?:(?:can|could|shall|should) (?:we|you|i)\s+|(?:i|we) (?:need|have|want) to\s+|remind me to\s+|don'?t forget to\s+|let'?s\s+)?/i, '')
    .replace(/[\s?!.]+$/, '')
    .trim();
  return t ? t[0].toUpperCase() + t.slice(1) : '';
}

// ---- More PayPal verbs (payouts, plans, invoices, balance, disputes). Regex only: no model reads these.
// Each one reads the last sentence the owner typed, never copied client text.
const NOT_A_NAME = new Set([
  'me', 'you', 'a', 'an', 'the', 'them', 'it', 'him', 'her', 'us', 'back', 'over', 'out', 'to', 'my', 'your', 'this', 'that', 'money', 'now', 'later', 'for',
]);
const PAY_ROLE = String.raw`(?:my\s+(?:supplier|vendor|contractor|freelancer|assistant|cleaner|landlord|guy)\s+)?`;
const PAY_NAME = String.raw`(?<name>\p{L}[\p{L}'’-]*)`;
const PAY_TO_NAME = new RegExp(String.raw`^(?:please\s+)?(?:pay|send)\s+${PAY_ROLE}${PAY_NAME}`, 'iu');
const PAY_AMOUNT_TO = new RegExp(String.raw`^(?:please\s+)?(?:pay|send)\s+\S+\s+to\s+${PAY_ROLE}${PAY_NAME}`, 'iu');
// A request for the client to pay, not a payment to someone.
const NOT_PAYOUT = /\b(?:invoice|bill|link|reminder|receipt|quote|request)\b/i;

export type PayoutAsk = { name: string; amount: number | null; currency: string | null; email: string | null };

/** "pay joe $200", "send my supplier joe $200 joe@x.com", "send $200 to joe". Null when the sentence is not a payout. */
export function payoutAsk(text: string): PayoutAsk | null {
  const s = lastSentence(text);
  if (NOT_PAYOUT.test(s) || !/\d/.test(s)) return null;
  const m = s.match(PAY_TO_NAME) ?? s.match(PAY_AMOUNT_TO);
  const raw = m?.groups?.name;
  if (!raw || NOT_A_NAME.has(raw.toLowerCase())) return null;
  const q = quick(s);
  return { name: raw[0].toUpperCase() + raw.slice(1).toLowerCase(), amount: q.amount, currency: q.currency, email: q.email };
}

// Repeat bills (PayPal subscriptions). Pause and resume are clear verbs alone; stop, end and cancel need a plan word,
// so "cancel sam's invoice" or "stop by at 3" never touch a plan.
const PLAN_WORD = /\b(?:plans?|repeat (?:bills?|billing)|subscriptions?|monthly|weekly|yearly|membership)\b/i;
const PLANS_LIST = /^(?:(?:what|which|show(?: me)?|list|see|any)\b.*\b(?:plans|repeat bills|subscriptions)\b|(?:my\s+)?(?:plans|repeat bills|subscriptions)\??$)/i;

export type PlanVerb = 'list' | 'pause' | 'resume' | 'cancel' | 'status';

/** "what plans do I have", "pause ana's plan", "restart ana's plan", "stop ana's plan for good", "how is ana's plan". */
export function planVerb(text: string): PlanVerb | null {
  const s = lastSentence(text);
  if (PLANS_LIST.test(s)) return 'list';
  if (/\b(?:pause|suspend)\b|\bon hold\b/i.test(s)) return 'pause';
  if (/\b(?:resume|restart|unpause|reactivate)\b/i.test(s)) return 'resume';
  if (!PLAN_WORD.test(s)) return null;
  if (/\b(?:stop|end|cancel|kill)\b/i.test(s)) return 'cancel';
  if (/\bstatus\b|\bhow(?:'s|\s+is)\b/i.test(s)) return 'status';
  return null;
}

// Disputes. A reply quotes the owner's own words after the name: "tell sam in the dispute: I shipped it Monday".
const DISPUTE_REPLY = /^(?:reply to|tell|message|answer)\s+(?<name>\p{L}[\p{L}'’-]*)(?:'s)?(?:\s+in\s+(?:the|a|our|his|her|their)\s+(?:paypal\s+)?(?:dispute|claim|case))?\s*[:,-]?\s+(?<message>\S.*)$/iu;

export type DisputeVerb = { verb: 'list' | 'accept' | 'offer' } | { verb: 'reply'; name: string; message: string };

/** "disputes", "accept sam's claim", "offer sam $20 back", "tell sam I shipped it". Who it is about is matched against open disputes. */
export function disputeVerb(text: string): DisputeVerb | null {
  const s = lastSentence(text);
  if (/^(?:(?:show|list|see|check|any|my|open|what are)\s+)*(?:my\s+|open\s+|paypal\s+)*disputes\??$/i.test(s)) return { verb: 'list' };
  if (/\baccept\b.*\b(?:claim|dispute|case)\b/i.test(s)) return { verb: 'accept' };
  if (/\boffer\b/i.test(s) && /\d/.test(s)) return { verb: 'offer' };
  // A reply keeps every sentence of its last line.
  const m = (text.trim().split('\n').pop() ?? '').trim().match(DISPUTE_REPLY);
  return m?.groups ? { verb: 'reply', name: m.groups.name, message: m.groups.message.trim() } : null;
}

// "how much do I have", "my balance", "what's my PayPal balance". The whole sentence, so "your balance is $45" to a client is not one.
const BALANCE = /^(?:(?:what'?s|what is|check|show(?: me)?)\s+)?(?:my\s+|the\s+)?(?:paypal\s+)?balance\??$|^how much (?:money )?(?:do i have|have i got|is in (?:my )?paypal)\b/i;
export const balanceAsk = (text: string) => BALANCE.test(lastSentence(text));

// Money that moved outside PayPal, and invoices the owner calls off. PayPal's payment method names.
const METHOD: [RegExp, string, string][] = [
  [/\bcash\b/i, 'CASH', 'cash'], [/\b(?:check|cheque)\b/i, 'CHECK', 'check'], [/\bwire\b/i, 'WIRE_TRANSFER', 'wire'],
  [/\b(?:zelle|venmo|bank|transfer)\b/i, 'BANK_TRANSFER', 'bank transfer'], [/\bcard\b/i, 'CREDIT_CARD', 'card'],
];
const OUTSIDE_METHOD = /\b(?:cash|check|cheque|wire|zelle|venmo|bank|transfer|card)\b/i;

export type InvoiceVerb = { verb: 'mark_paid' | 'cancel_invoice' | 'record_refund'; method: string | null; methodWord: string | null };

/** "sam paid cash", "mark sam paid", "cancel sam's invoice", "record a $20 refund for sam", "refunded sam $20 in cash". */
export function invoiceVerb(text: string): InvoiceVerb | null {
  const s = lastSentence(text);
  const m = METHOD.find(([re]) => re.test(s));
  const method = { method: m?.[1] ?? null, methodWord: m?.[2] ?? null };
  if (/\b(?:cancel|void)\b.*\binvoice\b/i.test(s)) return { verb: 'cancel_invoice', method: null, methodWord: null };
  if (/\b(?:record|log|mark)\b.*\brefund/i.test(s) || (/\brefunded\b/i.test(s) && OUTSIDE_METHOD.test(s))) return { verb: 'record_refund', ...method };
  if (/^who\b/i.test(s)) return null;
  if (/\bmark(?:ed)?\b.*\bpaid\b/i.test(s) || /\bpaid\s+(?:me\s+)?(?:(?:in|by|with|via)\s+)?(?:cash|check|cheque|wire|zelle|venmo|bank|transfer|card)\b/i.test(s)) {
    return { verb: 'mark_paid', ...method };
  }
  return null;
}
