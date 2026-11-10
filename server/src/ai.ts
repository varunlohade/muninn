import { z } from 'zod';
import { config, INTENTS, type Intent } from './config.ts';
import { log } from './log.ts';

export type Classification = { intent: Intent; confidence: number; ms: number };
export type Extraction = {
  client_name: string | null; client_email: string | null; amount: number | null; currency: string | null; item: string | null;
};
export type Ai = {
  classify(text: string): Promise<Classification>;
  extract(text: string, catalog: string): Promise<Extraction>;
  reply(text: string, profile: { business_name: string; tone: string }, catalog: string): Promise<string>;
};

const CRITERIA: Record<Intent, string> = {
  create_invoice: 'The owner tells a client what they owe for a job or item, so the owner should send an invoice.',
  pay_link: 'The owner wants to give the client a quick link to pay now, e.g. "send me a link", "how can I pay you".',
  payment_status: 'The owner asks or wonders whether someone has paid, who paid, or what is still owed.',
  send_reminder: 'The owner wants to nudge a client about an unpaid or overdue invoice.',
  refund: 'The owner agrees to give a client money back or refund a payment.',
  catalog_reply: 'A client asks about prices, services, products, or availability, and the owner should reply with the catalog.',
  none: 'Ordinary chat with no payment, pricing or invoice action.',
};

async function postJson(url: string, key: string, body: unknown, timeoutMs: number): Promise<any> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} from ${new URL(url).host}`);
  return res.json();
}

const nullish = (v: unknown) => (v === undefined || v === null || (typeof v === 'string' && ['', 'null', 'none', 'n/a', 'unknown'].includes(v.trim().toLowerCase())) ? null : v);
const NullableString = z.preprocess(nullish, z.string().trim().max(120).nullable()).catch(null);

export const ExtractionSchema = z.object({
  client_name: NullableString,
  client_email: z.preprocess(nullish, z.string().trim().toLowerCase().email().nullable()).catch(null),
  amount: z.preprocess((v) => {
    const n = nullish(v);
    return typeof n === 'string' ? Number(n.replace(/[$€£,\s]/g, '')) : n;
  }, z.number().finite().nullable()).catch(null),
  currency: z.preprocess(nullish, z.string().trim().toUpperCase().regex(/^[A-Z]{3}$/).nullable()).catch(null),
  item: NullableString,
});

export function parseModelJson(content: string): unknown {
  const s = content.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  const start = s.indexOf('{');
  const end = s.lastIndexOf('}');
  if (start < 0 || end < start) throw new Error('model returned no JSON object');
  return JSON.parse(s.slice(start, end + 1));
}

export function createAi(env: { typesafeKey: string; openrouterKey: string }): Ai {
  async function chat(messages: { role: string; content: string }[], maxTokens: number, purpose: string): Promise<string> {
    const attempts = [config.llm.primary, config.llm.fallback];
    let lastErr: unknown;
    for (const m of attempts) {
      const t = performance.now();
      try {
        const data = await postJson(config.llm.url, env.openrouterKey, { ...m, messages, temperature: 0, max_tokens: maxTokens }, config.llm.timeoutMs);
        const content = data?.choices?.[0]?.message?.content;
        if (typeof content !== 'string' || !content.trim()) throw new Error('empty completion');
        log('llm', { purpose, model: m.model, ms: Math.round(performance.now() - t), ok: true });
        return content;
      } catch (e) {
        lastErr = e;
        log('llm', { purpose, model: m.model, ms: Math.round(performance.now() - t), ok: false, err: (e as Error).message });
      }
    }
    throw lastErr;
  }

  return {
    async classify(text) {
      const t = performance.now();
      const body = {
        model: config.jev.model,
        state: { context: text.slice(0, config.maxTextChars) },
        questions: {
          q: {
            type: 'choice',
            criteria: Object.fromEntries(INTENTS.map((k, i) => [String(i + 1), CRITERIA[k]])),
            instructions: { question: 'A small business owner is typing this chat message. Which payment action fits it best?' },
          },
        },
      };
      const res = await postJson(config.jev.url, env.typesafeKey, body, config.jev.timeoutMs);
      const ans = res?.answers?.q;
      const idx = Number(ans?.choice) - 1;
      const intent = INTENTS[idx] ?? 'none';
      return { intent, confidence: Number(ans?.confidence ?? 0), ms: Math.round(performance.now() - t) };
    },

    async extract(text, catalog) {
      const content = await chat([
        {
          role: 'system',
          content: 'Extract payment details from a chat message a small business owner is writing to a client. ' +
            'Reply with one JSON object only, no prose: {"client_name": string|null, "client_email": string|null, ' +
            '"amount": number|null, "currency": "USD"|"EUR"|"GBP"|"CAD"|"AUD"|null, "item": string|null}. ' +
            'Use null for anything not stated. item is a short product or service name. ' +
            (catalog ? `The owner's catalog: ${catalog}` : ''),
        },
        { role: 'user', content: text.slice(0, config.maxTextChars) },
      ], 120, 'extract');
      return ExtractionSchema.parse(parseModelJson(content));
    },

    async reply(text, profile, catalog) {
      const content = await chat([
        {
          role: 'system',
          content: `You write chat replies for ${profile.business_name}, a small business. Tone: ${profile.tone}. ` +
            `Use only these items and prices; never invent prices: ${catalog || 'no catalog yet'}. ` +
            'Reply with the message text only, 1-3 short sentences.',
        },
        { role: 'user', content: `The client wrote: ${text.slice(0, config.maxTextChars)}` },
      ], 160, 'reply');
      return content.trim().replace(/^"|"$/g, '');
    },
  };
}
