// Natural money requests: what an owner really types, with no "invoice" keyword. Shared by the mocked test
// (natural-eval.test.ts) and the live eval (scripts/eval-natural.ts).
// A positive wants an invoice or pay link chip with this amount, this client (when named) and a reason made of
// the owner's own words. A negative is normal chat: it wants no money chip at all.

export type Positive = {
  say: string;
  amount: string;
  /** The client the text names: matched against client_name or client_email. */
  client?: string;
  /** Words the chip's reason (payload.item) must hold, lowercased. Left out: any reason the owner typed. */
  reason?: string[];
};

export type EvalBusiness = {
  id: string;
  /** What the owner said in onboarding: "What does your business do?". Empty for a fresh account that skipped it. */
  description: string;
  /** A client with one unpaid invoice and one with a paid one, so the owner's records are not empty. */
  unpaid: string;
  paid: string;
  pos: Positive[];
  neg: string[];
};

const p = (say: string, amount: number, reason?: string[], client?: string): Positive =>
  ({ say, amount: amount.toFixed(2), reason, client });

export const EVAL: EvalBusiness[] = [
  {
    id: 'appdev', description: 'app development', unpaid: 'Dana Wu', paid: 'Leo Martins',
    pos: [
      p('two screens for 50', 50, ['screen']),
      p("done with the 2 screens, that's $50", 50, ['screen']),
      p('sam owes me 50 for the app screens', 50, ['screen'], 'sam'),
      p('can you pay me 50 for the screens', 50, ['screen']),
      p('the login page is ready, $120 please', 120, ['login']),
      p('invoice dana $300 for the onboarding flow', 300, ['onboarding'], 'dana'),
      p("that'll be 450 for the push notifications work", 450, ['push']),
      p('send me 80 for the bug fixes when you can', 80, ['bug']),
      p('logo design for leo, $350', 350, ['logo'], 'leo'),
      p("for the api integration it's $600", 600, ['api']),
      p('you can pay the $200 for the beta build here', 200, ['beta']),
      p('mike, 75 for the icon tweaks', 75, ['icon'], 'mike'),
    ],
    neg: ['the 2 screens look great!', 'I paid 50 for lunch', 'my phone bill was $80 this month', 'see you at 5'],
  },
  {
    id: 'barber', description: 'Barber shop: cuts, fades and beard trims', unpaid: 'Jake Moss', paid: 'Marco Diaz',
    pos: [
      p('$45 for the haircut', 45, ['haircut']),
      p('can you pay $45 for the haircut', 45, ['haircut']),
      p('send me 45 for the haircut', 45, ['haircut']),
      p("that's 30 for the cut bro", 30, ['cut']),
      p('jay owes me 15 for the beard trim', 15, ['beard'], 'jay'),
      p('pay me 35 for the fade when you get a sec', 35, ['fade']),
      p('cut was 30, you can send it here', 30, ['cut']),
      p('leo still owes me 40 for the cut last week', 40, ['cut'], 'leo'),
      p('kids cut for your son, $20', 20, ['kids']),
      p('$25 for the line up', 25, ['line']),
    ],
    neg: ['running 10 min late sorry!!', 'the bus was $2', 'lol that movie was 2 hours long', 'got 5 new followers today'],
  },
  {
    id: 'tutor', description: 'math and physics tutoring for high school students', unpaid: 'Noah Kim', paid: 'Priya Shah',
    pos: [
      p("that's $40 for today's lesson", 40, ['lesson']),
      p('pay me 150 for the exam prep', 150, ['exam']),
      p('$60 for the physics session tonight', 60, ['physics']),
      p('noah, 120 for the three calculus lessons', 120, ['calculus'], 'noah'),
      p('can you send the 45 for the essay review', 45, ['essay']),
      p("done with the mock test grading, that's $30", 30, ['mock']),
      p('invoice priya 200 for the sat prep', 200, ['sat'], 'priya'),
      p("lesson fee is 40, here's how to pay", 40, ['lesson']),
      p('$40 for the lesson', 40, ['lesson']),
      p('great class today! 40 for the hour', 40),
    ],
    neg: ['see you tuesday at 3, bring your calculator', 'it was 50 degrees today', 'we have 2 kids and a dog', 'the game starts at 7:30'],
  },
  {
    id: 'bakery', description: 'home bakery: custom cakes, cupcakes and cookies', unpaid: 'Sara Lee', paid: 'Tom Hale',
    pos: [
      p('your cake is ready! $60', 60, ['cake']),
      p('two dozen cupcakes, 55 total', 55, ['cupcake']),
      p('sara owes me 20 for the cookie box', 20, ['cookie'], 'sara'),
      p("that's 75 for the wedding cake tasting", 75, ['wedding']),
      p('can you pay 35 for the sourdough order', 35, ['sourdough']),
      p('$18 for the cinnamon rolls', 18, ['cinnamon']),
      p('the custom cake is $90, pay whenever', 90, ['cake']),
      p('lisa, 40 for the brownies', 40, ['brownie'], 'lisa'),
      p("done with your order, that'll be $25", 25),
      p('invoice tom 120 for the party platter', 120, ['platter'], 'tom'),
    ],
    neg: ['my rent is $1200 this month ugh', 'lunch was 15 bucks lol', 'she paid 20 for the tickets', 'happy birthday!! hope its a good one'],
  },
  {
    id: 'plumber', description: 'plumbing repairs and installs', unpaid: 'Ed Kowalski', paid: 'Ana Ruiz',
    pos: [
      p("fixed the leak, that's $150", 150, ['leak']),
      p('drain is clear, 120 please', 120, ['drain']),
      p('mr kowalski owes 300 for the water heater install', 300, ['water heater'], 'kowalski'),
      p('can you send 80 for the call out', 80, ['call']),
      p('$95 for replacing the faucet', 95, ['faucet']),
      p('toilet repair done, 110', 110, ['toilet']),
      p('the pipe burst job came to 400', 400, ['pipe']),
      p('dave, 200 for the shower valve', 200, ['shower'], 'dave'),
      p('invoice ana@x.com $90 for the drain clean', 90, ['drain'], 'ana@x.com'),
      p("that's 65 for the inspection", 65, ['inspection']),
    ],
    neg: ['I spent $30 on gas today', 'can you send me the address', 'call me when you are free, I am around after 4', 'how was your weekend'],
  },
  {
    // A fresh account: skipped "What does your business do?", no records yet.
    id: 'fresh', description: '', unpaid: '', paid: '',
    pos: [
      p('$45 for the haircut', 45, ['haircut']),
      p('two screens for 50', 50, ['screen']),
      p('sam owes me 50 for the app screens', 50, ['screen'], 'sam'),
      p('can you pay me 50 for the screens', 50, ['screen']),
      p("done with the 2 screens, that's $50", 50, ['screen']),
      p('$30 for the dog walk', 30, ['dog']),
    ],
    neg: ['thanks so much, see you soon', 'the screens arrived at the office', 'I paid 50 for lunch', 'the bus was $2'],
  },
];

export type ChipOut = { kind: string; label: string; payload: Record<string, any> };
export const MONEY_KINDS = new Set(['invoice', 'paylink', 'remind', 'refund', 'payout', 'subscribe']);

const STOP = new Set(['the', 'a', 'an', 'for', 'of', 'and', 'my', 'your', 'to', 'payment', 'with', 'on', 'in']);
const stem = (w: string) => w.toLowerCase().replace(/(?:es|s)$/, '');
/** True when every word of the reason is a word the owner typed (a reason never names what was not said). */
export function groundedReason(reason: string, typed: string): boolean {
  const said = (typed.toLowerCase().match(/[a-z]+/g) ?? []).map(stem);
  const words = (reason.toLowerCase().match(/[a-z]+/g) ?? []).filter((w) => !STOP.has(w));
  return words.every((w) => said.some((s) => s === stem(w) || (s.length >= 4 && stem(w).startsWith(s)) || (stem(w).length >= 4 && s.startsWith(stem(w)))));
}

export type Score = { shown: boolean; amount: boolean; client: boolean; reason: boolean; ok: boolean; got: string };

/** How a positive did: the first invoice or pay link chip, checked field by field. */
export function scorePositive(pos: Positive, chips: ChipOut[]): Score {
  const c = chips.find((x) => x.kind === 'invoice' || x.kind === 'paylink');
  const got = chips.length ? chips.map((x) => `${x.kind}:${x.label}`).join(' | ') : 'none';
  if (!c) return { shown: false, amount: false, client: false, reason: false, ok: false, got };
  const amount = c.payload.amount === pos.amount;
  const who = `${c.payload.client_name ?? ''} ${c.payload.client_email ?? ''}`.toLowerCase();
  const client = pos.client ? who.includes(pos.client.toLowerCase()) : true;
  const item = String(c.payload.item ?? '');
  const reason = groundedReason(item, pos.say) && (pos.reason ?? []).every((w) => item.toLowerCase().includes(w));
  return { shown: true, amount, client, reason, ok: amount && client && reason, got };
}

/** A negative is right when no chip would move or ask for money. */
export const negativeOk = (chips: ChipOut[]) => !chips.some((c) => MONEY_KINDS.has(c.kind));
