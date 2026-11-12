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
// A number that reads like a price with no currency or money word: "do 45 for the cut", "€1.200". "$?" asks a price.
const PRICE_SHAPE = /[$€£]\s?\d|(?:^|\s)[$€£]{1,2}\s*\?|\d\s?[$€£]|\b\d+(?:[.,]\d+)*\s+for\b|\b(?:do|for)\s+\d/i;
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
  // Shorthand and typos: "hw much", "how mutch", "invoce", "prise", "pymt".
  'h[oe]?w\\s+m(?:u?ch|uhc|utch|ich|uc[hjg]|xh)', 'inv(?:oce|ioce|ocie|cie)s?', 'pri[cs]e?s?', 'pymt', 'pmt', 'amt', 'qoute', 'qte',
  // Hinglish and a few European words for the same questions: "kitna hoga", "paise", "was kostet", "precio", "combien".
  'kitn[aei]', 'paise', 'paisa', 'daam', 'rupees?', 'rs', 'preis\\w*', 'kost\\w*', 'rechnung', 'bezahl\\w*', 'zahl\\w*', 'wie ?viel',
  // A rate or a fee with no price word: "what's the membership per month", "your retainer".
  'per (?:hour|hr|month|mo|session|night|word|page|person|head|unit|piece|day|week|class|lesson|visit)', 'retainers?',
  'precios?', 'factura', 'pago', 'quanto', 'custa', 'combien', 'prix', 'facture', 'tarif\\w*',
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

// ---- A plain request to be paid, in the owner's natural words: "two screens for 50", "sam owes me 50 for the app
// screens", "drain is clear, 120 please". Regex only, so a sure case needs no intent question. The model may still read
// the reason and the client; the amount is always the one read here.

// Money the owner spent or someone else paid, or a bill of the owner's own: never a request to a client.
const SPENT = [
  /\b(?:i|we|i've|we've|ive)\s+(?:just\s+|already\s+)?(?:paid|spent|bought|owe|lost|got charged)\b/i,
  /\b(?:she|he|they|mom|dad)\s+(?:just\s+)?(?:paid|spent|bought)\b/i,
  /\b(?:my|our)\s+(?:\w+\s+)?(?:rent|bill|phone|car|gas|lunch|dinner|ticket|tickets|groceries|mortgage|loan|insurance)\b/i,
  /\b(?:bus|train|lunch|dinner|breakfast|coffee|gas|rent|uber|taxi|cab|tickets?|movie|groceries|parking|drinks?|pizza)\s+(?:was|is|were|cost|costs)\b/i,
];
// The owner asks the client to pay: a pay word, a total word, or a job that is done.
const ASKS = /\bowe[sd]?\b|\bpay\b|\bsend\b|\bplease\b|\bpls\b|\bthat'?s\b|\bthats\b|\bthat(?:'ll| will) be\b|\bit(?:'s| is)\b|\btotal\b|\bcame to\b|\bcomes to\b|\bready\b|\bdone\b|\bfixed\b|\bfinished\b|\bdue\b|\binvoice\b|\bbill\b/i;
// A number with these after it counts things or time, not money.
const UNIT_AFTER = /^\s*(?:%|percent|people|persons|pax|guests|kids|min|mins|minutes?|hours?|hrs?|days?|weeks?|months?|years?|yrs?|degrees?|followers?|likes?|pm|am|o'?clock|times|miles?|km|kg|lbs?|pages?|words?|st|nd|rd|th)\b/i;
const BARE = /(?<![\w.,:/$€£])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(?![\w.,:/]*\d)(?!\s*[$€£])/g;
// Words that end a reason: "for the cut bro", "for the fade when you get a sec", "for the cut last week".
const REASON_END = /\s+(?:bro|man|mate|dude|pls|please|thanks|thx|when\b.*|whenever\b.*|tonight|today|yesterday|last\s+\w+|this\s+\w+|here\b.*|asap|now|ok|okay)$/i;
const LEAD = /^(?:(?:done|finished|ready)\s+(?:with\s+)?|(?:i\s+)?(?:can\s+)?do\s+|the\s+|your\s+|my\s+|for\s+(?:the\s+|your\s+)?)+/i;

export type MoneyRequest = { amount: number; currency: string | null; reason: string | null };

/**
 * The owner's own text asks a client for one amount. Null for chat, money the owner spent ("I paid 50 for lunch"),
 * more than one possible amount, a number that counts time or things, or a sentence with no ask in it.
 */
export function moneyRequest(text: string): MoneyRequest | null {
  const s = text.trim();
  // A rate, tip, discount or quantity word ("3 cuts at $45", "half off"): the total is not plain, so the model decides.
  if (!s || SPENT.some((re) => re.test(s)) || TIME_LIKE.test(s) || RATE.test(s) || SLASH_RATE.test(s)) return null;
  const marked = amountsIn(s).filter((a) => a.total);
  let amount: number;
  let currency: string | null = null;
  let at: number;
  if (marked.length) {
    if (new Set(marked.map((a) => a.at)).size !== 1) return null;
    ({ amount, currency, at } = marked[0]);
  } else {
    // Bare digits: only the one number that is not a count ("2 screens") and sits by an ask or a "for".
    const bare = [...s.matchAll(BARE)].filter((m) => !UNIT_AFTER.test(s.slice(m.index + m[0].length)));
    const counts = (m: RegExpMatchArray) => /^\s+[a-z]/i.test(s.slice(m.index! + m[0].length)) && !/^\s+(?:for|please|pls|total|bucks|now|thanks|when|if)\b/i.test(s.slice(m.index! + m[0].length));
    const money = bare.filter((m) => !counts(m));
    if (money.length !== 1) return null;
    amount = Number(money[0][1].replace(/,/g, '') + (money[0][2] ? `.${money[0][2]}` : ''));
    at = money[0].index!;
    if (amount < 5) return null;
  }
  if (!(amount > 0)) return null;
  const forShape = /\bfor\b/i.test(s);
  if (!ASKS.test(s) && !forShape) return null;
  return { amount, currency, reason: reasonIn(s, at) };
}

// "7:30", "at 5", "by 3" read as a time.
const TIME_LIKE = /\d:\d\d|\b(?:at|by|around|after|before|until|till)\s+\d{1,2}\b(?!\s*(?:dollars?|bucks|usd|eur))/i;

/** The owner's words for what the money is for: after "for", else the clause without the amount. Null when none. */
function reasonIn(s: string, at: number): string | null {
  const clauses = s.split(/[,.!?;]|\s+-\s+/).map((c) => c.trim()).filter(Boolean);
  const tidy = (r: string) => {
    let t = r.replace(/[$€£]?\s?\d[\d,.]*\s?(?:usd|eur|gbp|dollars?|bucks)?/gi, ' ').replace(/\s+/g, ' ').trim();
    for (let i = 0; i < 3; i++) t = t.replace(REASON_END, '').trim();
    t = t.replace(/\s+(?:it'?s|its|is|was)$/i, '').replace(LEAD, '').replace(/\b(?:is|was|are|were)\s+(?:ready|done|clear|finished)$/i, '').replace(/\s+(?:is|was|came to|comes to|done|ready)$/i, '').trim();
    const words = t.split(/\s+/).filter(Boolean);
    if (!words.length || words.length > 5) return null;
    if (words.every((w) => /^(?:that'?s|thats|it'?s|its|that'll|be|total|please|pls|pay|me|you|send|can|the|a|an|it|here|owe[sd]?|done|with|order|your|my)$/i.test(w))) return null;
    return t;
  };
  const after = /\bfor\s+(?:the\s+|your\s+|my\s+|a\s+|an\s+)?([^,.!?;]+)/i.exec(s);
  if (after) {
    const r = tidy(after[1]);
    if (r && !/^\d/.test(after[1].trim())) return r;
  }
  // "two screens for 50": the words before "for <amount>".
  const before = /^(.*?)\s+for\s+[$€£]?\d/i.exec(s);
  if (before) {
    const r = tidy(before[1].split(/[,.!?;]/).pop() ?? '');
    if (r) return r;
  }
  // "fixed the leak, that's $150": the clause without the amount.
  for (const c of clauses) {
    if (/\d/.test(c) && s.indexOf(c) <= at && at < s.indexOf(c) + c.length) continue;
    const r = tidy(c.replace(/^(?:fixed|replaced|cleaned|finished|done with|completed)\s+/i, (m) => (/^fixed|^replaced|^cleaned/i.test(m) ? '' : '')));
    if (r && !/\b(?:you|can|send|pay|here|how)\b/i.test(r)) return r;
  }
  return null;
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
// "a month", "per month", "each month" count too; "a month ago" does not.
const INTERVAL = /\b(?:(?:every|a|per|each)\s+(week|month|year)(?!\s+ago)|(week|month|year)ly|annually)\b/gi;
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

export type RepeatAsk = { name: string; amount: number; currency: string | null; verb: boolean };
const REPEAT_SHAPE = /^(?:(?<verb>bill|charge|invoice)\s+)?(?<name>\p{L}[\p{L}'’-]*)\s+(?<money>(?:(?:usd|eur|gbp|cad|aud)\s?)?[$€£]?\s?\d[\d,.]*(?:\s?(?:[$€£]|usd|eur|gbp|cad|aud|dollars?|bucks|euros?))?)\s*[.!]?$/iu;

/**
 * "bill ana $40 every month", "charge ana 40 monthly", "ana $40 a month": one name, one amount, one plain interval.
 * `verb` is false for the bare "ana $40 a month", so the caller checks the name is a known client. Null otherwise.
 */
export function repeatAsk(text: string): RepeatAsk | null {
  const s = lastSentence(text);
  if (!intervalOf(s)) return null;
  const g = withoutInterval(s).replace(/\s+/g, ' ').trim().match(REPEAT_SHAPE)?.groups;
  if (!g || NOT_A_NAME.has(g.name.toLowerCase()) || /^(?:bill|charge|invoice)$/i.test(g.name)) return null;
  const q = quick(g.money);
  const bare = g.money.match(/^\d+(?:\.\d{1,2})?$/);
  const amount = q.amount ?? (bare ? Number(bare[0]) : null);
  if (amount === null || amount <= 0) return null;
  const name = g.name[0].toUpperCase() + g.name.slice(1).toLowerCase();
  return { name, amount, currency: q.currency, verb: !!g.verb };
}

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

/**
 * An owner command that names its own payment action: "remind Emma about last week's walks" is a reminder,
 * "bill Kowalski the retainer" an invoice. Only the first word counts, and something must follow it. Null otherwise.
 */
export function commandIntent(text: string): 'send_reminder' | 'create_invoice' | null {
  const m = /^\s*(remind|nudge|chase|bill|invoice)\s+(\S.*)$/iu.exec(lastSentence(text));
  if (!m) return null;
  return /^(bill|invoice)$/i.test(m[1]) ? 'create_invoice' : 'send_reminder';
}

/**
 * The words after "remind <name>": "" for "remind Jordan pls", "to bring the leash" for "remind Emma to bring the
 * leash". `name` may be typed in full or by first name. Null for "nudge" and "chase", which always mean money, and
 * when the name does not follow "remind".
 */
export function afterRemindName(text: string, name: string): string | null {
  const m = /^\s*remind\s+(\S.*)$/iu.exec(lastSentence(text));
  if (!m) return null;
  const first = name.trim().split(/\s+/)[0];
  for (const n of [name.trim(), first]) {
    const hit = new RegExp(`^${n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?:'s)?(?![\\p{L}\\p{N}])`, 'iu').exec(m[1]);
    if (n.length >= 2 && hit) {
      const rest = m[1].slice(hit[0].length).trim();
      return /^(?:please|pls|plz|now|again|today|asap|thanks|thx)?[\s.!?,]*$/i.test(rest) ? '' : rest;
    }
  }
  return null;
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

// ---- Lookup: "invoice for sam", "did sam pay", "ana's booking". The owner asks about their own records.
// Regex only. A sentence that is a lookup phrase from end to end is sure; "invoice sam" (a command or a lookup) is unsure.

/** money: invoices, bills, receipts, payments. any: the client's latest record of any kind. */
export type LookupKind = 'money' | 'any';
export type Lookup = {
  sure: boolean;
  /** The name or item as typed, lowercased. */
  name: string;
  kind: LookupKind;
  /** The typed noun in its plain form: "invoice", "booking", "receipt". Null when the sentence has none ("did sam pay"). */
  noun: string | null;
  /** owe → unpaid only; receipt → paid only. */
  want: 'unpaid' | 'paid' | null;
  cents: number | null;
  /** [from, to) in ms, from "last week", "yesterday", "in november". */
  range: { from: number; to: number; words: string } | null;
  /** The typed words the chip quotes. */
  trigger: string;
};

const MONEY_NOUNS = new Set(['invoice', 'bill', 'receipt', 'payment', 'balance']);
// Long nouns a typo may hit: "invocie", "recipt", "apointment". Short or common-looking ones (order, class, quote) stay as typed.
const FUZZY_NOUNS = ['invoice', 'receipt', 'payment', 'booking', 'appointment', 'session', 'delivery', 'reservation', 'lesson'];
const NOUN = String.raw`(?<noun>invoices?|bills?|receipts?|payments?|balance|orders?|bookings?|appointments?|appts?|jobs?|quotes?|estimates?|sessions?|class(?:es)?|lessons?|tables?|reservations?|deliver(?:y|ies)|visits?|projects?)`;
// One or two name words. Lazy, so a date or amount after the name is not read as a second word.
const NAME = String.raw`(?<name>[a-z][a-z.-]*(?: [a-z][a-z.-]*)??)`;
const MOD = String.raw`(?:(?:the|my|our|his|her|their|a|an|any) )?(?:(?<mod>latest|last|recent|most recent|newest|current|open|unpaid|outstanding|pending|previous|old) )?`;
const AMT = String.raw`(?<amt>[$€£]\d+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})? ?(?:dollars?|bucks|usd|eur|gbp))`;
const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const DATE = String.raw`(?:(?:from|in|on|of|since|for) )?(?<date>(?:the )?last week|this week|yesterday|today|last month|this month|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*|(?:last )?(?:mon|tues|wednes|thurs|fri|satur|sun)day)`;
const TAIL = String.raw`(?: ${DATE})?`;
// "sam's invoice for $120" looks up by amount. "invoice for sam for $45" is a new invoice, so only the possessive takes a trailing amount.
const AMT_TAIL = String.raw`(?: (?:for |of )?(?<amt2>[$€£]\d+(?:\.\d{1,2})?))?`;
// "..., the $85 one": an amount that picks one record, after any lookup phrase.
const THE_ONE = String.raw`(?: the (?<amt3>[$€£]\d+(?:\.\d{1,2})?) one)?`;
const PREP = '(?:for|from|of|to|with|by)';
const PAID_TAIL = String.raw`(?: (?:me|us|you|yet|up|already|back|it|(?:for )?(?:the|my|a|an|her|his|that) [a-z]+|for [a-z]+))*`;

type Template = { re: RegExp; sure: boolean; kind?: LookupKind; want?: 'unpaid'; possessive?: true };
const tpl = (s: string, sure = true, extra: Omit<Template, 're' | 'sure'> = {}): Template => ({ re: new RegExp(`^${s}$`), sure, ...extra });
const TEMPLATES: Template[] = [
  // invoice for sam, last order from ana lopez, the receipt for bo from last week, the $120 invoice for sam
  tpl(`${MOD}(?:${AMT} )?${NOUN} ${PREP} ${NAME}${TAIL}${THE_ONE}`),
  // sam's invoice, sams invoce, ana's last booking, sam's $120 invoice from last week. "sam invoice" (no 's) is unsure.
  tpl(`${NAME}(?<poss>'s|s'|')? ${MOD}(?:${AMT} )?${NOUN}${TAIL}${AMT_TAIL}${THE_ONE}`, true, { possessive: true }),
  // the $120 one for sam
  tpl(`(?:the )?${AMT} (?:one|${NOUN}) ${PREP} ${NAME}${TAIL}`),
  // did sam pay, has sam paid yet, did sam ever pay me, is sam paid up
  tpl(`(?:did|has|have|had) ${NAME} (?:ever |already |actually |finally |even )?(?:pay|paid)${PAID_TAIL}`, true, { kind: 'money' }),
  tpl(`is ${NAME} paid(?: up)?(?: yet)?`, true, { kind: 'money' }),
  tpl(`${NAME} (?:paid|pay) yet`, true, { kind: 'money' }),
  // what does sam owe, how much does sam owe me, does sam still owe me anything, what sam owes
  tpl(`(?:what|how much) (?:does|do|did) ${NAME} (?:still )?owe(?: me| us)?(?: still)?`, true, { kind: 'money', want: 'unpaid' }),
  tpl(`(?:does|do) ${NAME} (?:still )?owe(?: me| us)?(?: anything| money| still)?`, true, { kind: 'money', want: 'unpaid' }),
  tpl(`(?:what|how much) ${NAME} (?:still )?owes(?: me| us)?`, true, { kind: 'money', want: 'unpaid' }),
  // what did ana order last time, when did bo last book
  tpl(`(?:what|when) did ${NAME} (?:last )?(?:order|book|buy|get|have|come in)(?: last time| last)?`, true, { kind: 'any' }),
  // invoice sam: a command or a lookup, so the router decides.
  tpl(`${NOUN} ${NAME}`, false),
];
const LEAD_IN = /^(?:hey|hi|hello|yo|ok|okay|so|um|uh|hmm|lol|lmao|haha|btw|quick q|quick question|pls|please|can you|could you|can u|would you|will you|show me|show|find me|find|get me|get|pull up|open|check|look up|lookup|what's|whats|what is|where's|wheres|where is|when's|when is|when was|give me|gimme|i need|need|see|send me|bring up|remind me)\b[ ,:]*/;
const TRAIL = /(?:[ ,]+(?:lol|lmao|haha|pls|please|thanks|thx|again|rn|right now|now|real quick|quickly|asap|for me|then))+$/;
// Words that are never a client's name in these phrases.
const NOT_NAME = new Set([
  'me', 'you', 'u', 'him', 'her', 'them', 'it', 'this', 'that', 'the', 'my', 'a', 'an', 'our', 'your', 'his', 'their', 'we', 'i', 'they', 'he', 'she',
  'someone', 'anyone', 'everyone', 'somebody', 'anybody', 'everybody', 'nobody', 'who', 'what', 'which', 'one', 'ones', 'all', 'any', 'each',
  'today', 'tomorrow', 'yesterday', 'tonight', 'week', 'month', 'now', 'later', 'next', 'last', 'template', 'templates', 'ideas', 'idea',
  'for', 'from', 'of', 'to', 'with', 'by', 'in', 'on', 'and', 'or', 'not', 'is', 'was', 'be', 'yet', 'ever', 'there', 'here', 'pay', 'paid',
  'new', 'send', 'make', 'create', 'number', 'amount', 'total', 'due', 'late', 'link', 'email', 'sent', 'more', 'some', 'free', 'online',
]);

/** Optimal string alignment distance: an insert, a delete, a change or a swap of two neighbours each cost 1. */
export function editDistance(a: string, b: string): number {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array<number>(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
    }
  }
  return d[a.length][b.length];
}

/** "invocie" → "invoice", "recipts" → "receipts": one typo in a long record noun. Other words stay as typed. */
function fixNoun(word: string): string {
  if (word.length < 5) return word;
  for (const n of FUZZY_NOUNS) {
    if (word === n || word === n + 's') return word;
    if (editDistance(word, n) <= 1) return n;
    if (editDistance(word, n + 's') <= 1) return n + 's';
  }
  return word;
}

const singular = (noun: string) => (noun === 'deliveries' ? 'delivery' : noun === 'classes' ? 'class' : noun === 'appt' || noun === 'appts' ? 'appointment'
  : noun.endsWith('s') && noun !== 'class' ? noun.slice(0, -1) : noun);

function rangeOf(words: string, now: number): Lookup['range'] {
  const day = 86_400_000;
  const d = new Date(now);
  const today = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
  const week = today - ((d.getUTCDay() + 6) % 7) * day;
  const month = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1);
  const w = words.replace(/^the /, '');
  const span = (from: number, to: number) => ({ from, to, words: w });
  if (w === 'today') return span(today, today + day);
  if (w === 'yesterday') return span(today - day, today);
  if (w === 'this week') return span(week, now + 1);
  if (w === 'last week') return span(week - 7 * day, week);
  if (w === 'this month') return span(month, now + 1);
  if (w === 'last month') return span(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - 1, 1), month);
  // "friday", "last friday": the most recent such day before today.
  const wd = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'].indexOf(w.replace(/^last /, '').slice(0, 3));
  if (w.endsWith('day') && wd >= 0) {
    const back = (d.getUTCDay() - wd + 7) % 7 || 7;
    return span(today - back * day, today - back * day + day);
  }
  const mi = MONTHS.indexOf(w.slice(0, 3));
  if (mi < 0) return null;
  // The most recent such month: "in november" typed in March means last November.
  const year = mi <= d.getUTCMonth() ? d.getUTCFullYear() : d.getUTCFullYear() - 1;
  return span(Date.UTC(year, mi, 1), Date.UTC(year, mi + 1, 1));
}

const amountCents = (a: string | undefined) => {
  const n = a ? Number(a.replace(/[^\d.]/g, '')) : NaN;
  return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : null;
};

/** The core of the last sentence: lowercase, no lead-in ("hey can you show me"), no tail ("lol", "?"), record nouns spelled right. */
// A lead-in that asks to see something. After one, "bo chen order" is a lookup, not a command.
const LOOK_VERB = /^(?:show|find|get|pull up|open|check|look up|lookup|what's|whats|what is|where's|wheres|where is|give me|gimme|see|bring up)\b/;

function lookupCore(text: string): { core: string; trigger: string; asked: boolean } {
  const sentence = lastSentence(text).replace(/[’‘`]/g, "'");
  let s = sentence.toLowerCase().replace(/[^a-z0-9$€£'.\s-]/g, ' ').replace(/\.(?!\d)/g, ' ').replace(/\s+/g, ' ').trim();
  let asked = false;
  for (let prev = ''; prev !== s;) { prev = s; asked ||= LOOK_VERB.test(s); s = s.replace(LEAD_IN, '').trim(); }
  s = s.replace(TRAIL, '').trim();
  s = s.split(' ').map((w) => {
    const poss = /^(.*?)('s|')$/.exec(w);
    return poss ? fixNoun(poss[1]) + poss[2] : fixNoun(w);
  }).join(' ');
  return { core: s, trigger: sentence.replace(/[\s?!.,]+$/, '').trim(), asked };
}

/** A lookup phrase in the owner's last sentence, or null. It says nothing about whether the name is a real client. */
export function detectLookup(text: string, now: number): Lookup | null {
  if (!text.trim() || amountsIn(text).length > 1) return null;
  const { core, trigger, asked } = lookupCore(text);
  if (!core || core.split(' ').length > 9) return null;
  for (const t of TEMPLATES) {
    const m = t.re.exec(core);
    const g = m?.groups;
    if (!g?.name) continue;
    const name = g.name.trim();
    if (name.split(' ').some((w) => NOT_NAME.has(w))) continue;
    const noun = g.noun ? singular(g.noun) : null;
    // "sam invoice" has no 's: a command or a lookup. "sams invoice" reads as a possessive.
    // "sam invoice" alone is a command or a lookup. A possessive, a lookup verb, "latest", a date or an amount makes it a lookup.
    const sure = t.sure && (!t.possessive || g.poss !== undefined || /s$/.test(name) || asked || !!(g.mod ?? g.date ?? g.amt ?? g.amt2 ?? g.amt3));
    return {
      sure, name, kind: t.kind ?? (noun && MONEY_NOUNS.has(noun) ? 'money' : 'any'), noun,
      want: t.want ?? (noun === 'receipt' ? 'paid' : noun === 'balance' ? 'unpaid' : null),
      cents: amountCents(g.amt ?? g.amt2 ?? g.amt3), range: g.date ? rangeOf(g.date, now) : null, trigger,
    };
  }
  return null;
}

// ---- More PayPal verbs (payouts, plans, invoices, balance, disputes). Regex only: no model reads these.
// Each one reads the last sentence the owner typed, never copied client text.
const NOT_A_NAME = new Set([
  'me', 'you', 'a', 'an', 'the', 'them', 'it', 'him', 'her', 'us', 'back', 'over', 'out', 'to', 'my', 'your', 'this', 'that', 'money', 'now', 'later', 'for',
]);
// A time or date word in a payout sentence makes it chat or a plan, never a payout to send now.
const TIME_WORD = /\b(?:today|tonight|tomorrow|yesterday|now|later|soon|next|last|this|every|daily|weekly|monthly|yearly|morning|afternoon|evening|night|noon|midnight|week|weekend|month|year|am|pm|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs(?:day)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\d\s?(?:am|pm)\b|\d:\d/i;
const PAY_ROLE = String.raw`(?:my\s+(?:supplier|vendor|contractor|freelancer|assistant|cleaner|landlord|staff|guy)\s+)?`;
// One or two name words: "joe", "joe smith".
const PAY_NAME = String.raw`(?<name>\p{L}[\p{L}'’-]*(?:\s+\p{L}[\p{L}'’-]*)?)`;
// One money token: "$200", "200 usd", "usd 200", "€45.50". quick() then checks it is one real amount with a currency.
const PAY_MONEY = String.raw`(?:(?:usd|eur|gbp|cad|aud)\s?)?\S*\d\S*(?:\s(?:usd|eur|gbp|cad|aud|dollars?|bucks|euros?))?`;
const PAY_EMAIL = String.raw`(?:\s+\S+@\S+)?`;
// "... for tiles": the reason becomes the payout note. An email may sit before or after it.
const PAY_TAIL = String.raw`${PAY_EMAIL}(?:\s+for\s+(?<reason>[^@]+?))?${PAY_EMAIL}[.!]?$`;
// The whole sentence is the payout and nothing else, so a time, a date or an address word never reads as one.
// "cool, sending palak $40", "ok I'll send ritika 20", "let me pay joe $50": a short lead-in before the verb.
// Past tense ("sent", "paid") stays out: that is news about money already gone, not a payout to make.
const PAY_LEAD = String.raw`(?:(?:cool|ok(?:ay)?|sure|great|alright|yes|yeah|yep|done|perfect|got it|no problem)[,!.]?\s+)?(?:please\s+)?(?:i'?ll\s+|i\s+will\s+|let\s+me\s+|i'?m\s+|i\s+am\s+)?`;
const PAY_VERB = String.raw`(?:pay(?:ing)?|send(?:ing)?)`;
const PAYOUT_SHAPES = [
  new RegExp(String.raw`^${PAY_LEAD}${PAY_VERB}\s+${PAY_ROLE}${PAY_NAME}\s+${PAY_MONEY}${PAY_TAIL}`, 'iu'),
  new RegExp(String.raw`^${PAY_LEAD}${PAY_VERB}\s+${PAY_MONEY}\s+to\s+${PAY_ROLE}${PAY_NAME}${PAY_TAIL}`, 'iu'),
];
// A request for the client to pay, not a payment to someone.
const NOT_PAYOUT = /\b(?:invoice|bill|link|reminder|receipt|quote|request)\b/i;

export type PayoutAsk = { name: string; amount: number; currency: string | null; email: string | null; note: string | null };

/**
 * "pay joe $200", "pay joe smith $200 for tiles", "send my supplier joe $200 joe@x.com", "send $200 to joe for tiles".
 * Null when the sentence is not exactly a payout with one amount, or has a time or date word.
 */
export function payoutAsk(text: string): PayoutAsk | null {
  const s = lastSentence(text);
  // A bare number counts too ("pay ritika 20"): the whole sentence must still be a payout shape.
  const bare = [...s.replace(EMAIL, ' ').matchAll(BARE)];
  if (NOT_PAYOUT.test(s) || TIME_WORD.test(s.replace(EMAIL, ' ')) || (amountsIn(s).length === 0 && bare.length !== 1)) return null;
  const g = PAYOUT_SHAPES.map((re) => s.match(re)?.groups).find((x) => x?.name);
  const words = g?.name.split(/\s+/) ?? [];
  if (!words.length || words.some((w) => NOT_A_NAME.has(w.toLowerCase()))) return null;
  const q = quick(s);
  const amount = q.amount ?? (amountsIn(s).length === 0 && (s.match(NUMBER) ?? []).length === 1 ? Number(bare[0][1].replace(/,/g, '') + (bare[0][2] ? `.${bare[0][2]}` : '')) : null);
  if (amount === null) return null;
  const name = words.map((w) => w[0].toUpperCase() + w.slice(1).toLowerCase()).join(' ');
  return { name, amount, currency: q.currency, email: q.email, note: g?.reason?.trim() || null };
}

// Repeat bills (PayPal subscriptions). Pause and resume are clear verbs alone; stop, end and cancel need a plan word,
// so "cancel sam's invoice" or "stop by at 3" never touch a plan.
const PLAN_WORD = /\b(?:plans?|repeat (?:bills?|billing)|subscriptions?|monthly|weekly|yearly|membership)\b/i;
const PLANS_LIST = /^(?:(?:what|which|show(?: me)?|list|see|any)\b.*\b(?:plans|repeat bills|subscriptions)\b|(?:my\s+)?(?:plans|repeat bills|subscriptions)\??$)/i;

export type PlanVerb = 'list' | 'pause' | 'resume' | 'cancel' | 'status';

const NOT_PLAN_OWNER = new Set(['my', 'the', 'a', 'an', 'all', 'this', 'that', 'our', 'your', 'his', 'her', 'their', 'its', 'every', 'monthly', 'weekly', 'yearly']);
const PLAN_OWNER = [
  /(?<name>\p{L}[\p{L}-]*)['’]s\s+(?:[$€£]?\d[\d,.]*\s+)?(?:plans?|repeat (?:bills?|billing)|subscriptions?|monthly|weekly|yearly|membership)\b/iu,
  /\b(?:pause|suspend|resume|restart|unpause|reactivate|stop|end|cancel|kill)\s+(?<name>\p{L}[\p{L}-]*)\s+(?:plans?|repeat|subscriptions?|monthly|weekly|yearly|membership)\b/iu,
];

/** The client a plan sentence is about: "pause ana's plan" gives "Ana". Null when it names no one. */
export function planOwner(text: string): string | null {
  const s = lastSentence(text);
  if (!PLAN_WORD.test(s)) return null;
  const name = PLAN_OWNER.map((re) => s.match(re)?.groups?.name).find((n) => n && !NOT_PLAN_OWNER.has(n.toLowerCase()));
  return name ? name[0].toUpperCase() + name.slice(1).toLowerCase() : null;
}

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
  // "I can offer 2 slots" is chat: an offer needs a money amount or a dispute word.
  if (/\boffer\b/i.test(s) && (amountsIn(s).length > 0 || /\b(?:dispute|claim|case)\b/i.test(s))) return { verb: 'offer' };
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

// ---- Chart: "bar chart of my sales", "graph my projections", "show revenue next 3 months", "chart?".
// The owner's own money in, by month, with a marked estimate. Regex only; talk about a client's chart stays chat.
export type ChartAsk = { kind: 'bar' | 'line'; back: number; ahead: number };
const NUMBER_WORDS: Record<string, number> = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12 };
const CHART_NOUN = /\b(?:chart|graph|plot)s?\b/i;
const CHART_ALONE = /^(?:(?:a|the|my)\s+)?(?:(?:bar|line)\s+)?(?:chart|graph|plot)(?:\s+(?:please|pls))?[\s?!.]*$/i;
const SALES = /\b(?:sales|revenue|income|earnings|takings|turnover|money in|projections?|forecasts?|trend(?:s|ing)?)\b/i;
const CHART_MONTHS = new RegExp(`\\b(?:(?:last|past|next|coming)\\s+${COUNT}\\s+months?|(?:this|next|last)\\s+(?:month|quarter)|monthly|by month|per month)\\b`, 'i');
const SHOW = /^(?:(?:can|could)\s+you\s+|please\s+|pls\s+)?(?:show|graph|chart|plot|draw|forecast|project|predict|visuali[sz]e)\b/i;
const FORECAST_ALONE = /^(?:my\s+)?(?:(?:sales|revenue|income|earnings)\s+)?(?:projections?|forecasts?|trend)[\s?!.]*$/i;
const HOW_TRENDING = /^how\s+(?:are|is)\s+(?:my\s+)?(?:sales|revenue|income|earnings)\s+(?:doing|trending|going)\b/i;

const countIn = (m: RegExpMatchArray | null) => (m ? NUMBER_WORDS[m[1].toLowerCase()] ?? Number(m[1]) : null);
const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));

/** The chart the owner asks for, or null. `back`: full months of history (2-12); `ahead`: estimated months (1-6). */
export function chartAsk(text: string): ChartAsk | null {
  const s = lastSentence(text);
  // "your chart", "the client's graph": someone else's chart, not the owner's money.
  if (!s || s.length > 160 || /\byour\b/i.test(s)) return null;
  const asked = CHART_ALONE.test(s) || FORECAST_ALONE.test(s) || HOW_TRENDING.test(s)
    || (CHART_NOUN.test(s) && (SALES.test(s) || CHART_MONTHS.test(s)))
    || (SHOW.test(s) && SALES.test(s));
  if (!asked) return null;
  const back = countIn(s.match(new RegExp(`\\b(?:last|past)\\s+(${COUNT})\\s+months?\\b`, 'i')));
  const ahead = countIn(s.match(new RegExp(`\\b(?:next|coming)\\s+(${COUNT})\\s+months?\\b`, 'i')));
  return { kind: /\bline\b/i.test(s) ? 'line' : 'bar', back: clamp(back ?? 6, 2, 12), ahead: clamp(ahead ?? 3, 1, 6) };
}

const GLUE_WORDS = new Set(['the', 'a', 'an', 'for', 'of', 'and', 'my', 'your', 'to', 'with', 'on', 'in', 'at']);
const stemWord = (w: string) => w.toLowerCase().replace(/(?:es|s)$/, '');
/**
 * True when every main word of `words` is a word of `typed` ("screens" in "two screens for 50"; "Logo design" is not).
 * A word may differ by a plural ending or be a short form of a longer typed word.
 */
export function saidAll(words: string, typed: string): boolean {
  const said = (typed.toLowerCase().match(/[\p{L}\d]+/gu) ?? []).map(stemWord);
  const need = (words.toLowerCase().match(/[\p{L}\d]+/gu) ?? []).filter((w) => !GLUE_WORDS.has(w)).map(stemWord);
  return need.length > 0 && need.every((w) => said.some((s) => s === w || (s.length >= 4 && w.startsWith(s)) || (w.length >= 4 && s.startsWith(w))));
}
