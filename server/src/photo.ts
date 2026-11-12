// Catalog photos: JPEG or PNG only, at most 1 MB. The app re-encodes each photo before upload; the server
// still checks the file structure and rebuilds it without metadata blocks (EXIF, GPS, comments, text), so no client can store them.

export const PHOTO_MAX_BYTES = 1024 * 1024;
/** All of one owner's catalog photos together. */
export const PHOTO_TOTAL_BYTES = 50 * 1024 * 1024;
export const CATALOG_MAX_ITEMS = 200;
export type PhotoMime = 'image/jpeg' | 'image/png';

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
// The PNG chunks needed to draw the image. Everything else (tEXt, iTXt, zTXt, eXIf, tIME, ...) is dropped.
const PNG_KEEP = new Set(['IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND', 'gAMA', 'cHRM', 'sRGB', 'iCCP', 'sBIT', 'pHYs', 'bKGD']);

export function sniffPhoto(b: Buffer): PhotoMime | null {
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
  if (b.length > 8 && b.subarray(0, 8).equals(PNG_SIG)) return 'image/png';
  return null;
}

/** The photo without metadata blocks, or null when the bytes are not a well-formed JPEG or PNG. */
export function cleanPhoto(b: Buffer, mime: PhotoMime): Buffer | null {
  return mime === 'image/png' ? cleanPng(b) : cleanJpeg(b);
}

function cleanPng(b: Buffer): Buffer | null {
  const out: Buffer[] = [PNG_SIG];
  let i = 8;
  let first = true;
  while (i + 12 <= b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString('latin1', i + 4, i + 8);
    const end = i + 12 + len;
    if (end > b.length) return null;
    if (first && type !== 'IHDR') return null;
    first = false;
    if (PNG_KEEP.has(type)) out.push(b.subarray(i, end));
    i = end;
    if (type === 'IEND') return out.length > 2 ? Buffer.concat(out) : null;
  }
  return null;
}

function cleanJpeg(b: Buffer): Buffer | null {
  const out: Buffer[] = [b.subarray(0, 2)];
  let i = 2;
  while (i + 4 <= b.length) {
    if (b[i] !== 0xff) return null;
    const marker = b[i + 1];
    // Start of scan: the image data runs to the end of the file.
    if (marker === 0xda) {
      out.push(b.subarray(i));
      return Buffer.concat(out);
    }
    const len = b.readUInt16BE(i + 2);
    const end = i + 2 + len;
    if (len < 2 || end > b.length) return null;
    // APP1..APP15 (EXIF, XMP, ...) and COM hold metadata. APP0 (JFIF) stays.
    const meta = (marker >= 0xe1 && marker <= 0xef) || marker === 0xfe;
    if (!meta) out.push(b.subarray(i, end));
    i = end;
  }
  return null;
}
