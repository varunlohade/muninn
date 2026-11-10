const ch = (code: number) => String.fromCharCode(code);
const range = (from: number, to: number) => `${ch(from)}-${ch(to)}`;
// Bidi marks and overrides: LRM, RLM, LRE..RLO, LRI..PDI.
const BIDI = new RegExp(`[${ch(0x200e)}${ch(0x200f)}${range(0x202a, 0x202e)}${range(0x2066, 0x2069)}]`, 'g');
// C0 and C1 controls (newlines, tabs included) plus the Unicode line and paragraph separators.
const CONTROL = new RegExp(`[${range(0x00, 0x1f)}${range(0x7f, 0x9f)}${ch(0x2028)}${ch(0x2029)}]`, 'g');

export const clean = (s: string) => s.replace(BIDI, '').replace(CONTROL, ' ').replace(/\s+/g, ' ').trim();
