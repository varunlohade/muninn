"""Builds ios/Shared/Typing/en-words.txt from AOSP LatinIME's en_US_wordlist.combined (Apache-2.0).

Get the source:
  curl -s "https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/refs/heads/main/dictionaries/en_US_wordlist.combined.gz?format=TEXT" | base64 -d | gunzip > en_US_wordlist.combined
Run:
  python3 tools/build_words.py en_US_wordlist.combined ios/Shared/Typing/en-words.txt 60000
"""
import re
import sys

src, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
skip = {"offensive", "nonword", "babytalk", "drugs"}
rows = []
for line in open(src, encoding="utf-8"):
    if not line.startswith(" word="):
        continue
    kv = dict(p.split("=", 1) for p in line.strip().split(",") if "=" in p)
    w, f = kv["word"], int(kv["f"])
    if set(kv.get("flags", "").split("|")) & skip or "possibly_offensive" in kv:
        continue
    if not re.fullmatch(r"[a-z']+", w) or w.startswith("'"):
        continue
    rows.append((f, w))
rows.sort(key=lambda r: (-r[0], r[1]))
seen, keep = set(), []
for f, w in rows:
    if w not in seen:
        seen.add(w)
        keep.append((w, f))
keep = keep[:n]
with open(out, "w") as o:
    o.write("# English words and frequencies for the touch decoder: one \"word<TAB>f\" per line, commonest first.\n")
    o.write("# f is AOSP's 0-255 log scale: f = 255 + 8.59 * log2(p).\n")
    o.write("# Source: AOSP LatinIME dictionaries/en_US_wordlist.combined (version 54), Apache License 2.0,\n")
    o.write("# Copyright (c) 2008 The Android Open Source Project. https://www.apache.org/licenses/LICENSE-2.0\n")
    o.write("# Built by tools/build_words.py: lowercase words only (no names); offensive, nonword, babytalk and drugs entries dropped.\n")
    for w, f in keep:
        o.write(f"{w}\t{f}\n")
print(len(keep))
