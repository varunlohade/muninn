"""Builds ios/Tests/Fixtures/sentences.txt: 500 lowercase sentences from public-domain Project Gutenberg books.
Run: python3 tools/build_sentences.py ios/Tests/Fixtures/sentences.txt pg1342.txt pg1661.txt
"""
import re, sys
out = []
for path in sys.argv[2:]:
    t = open(path, encoding="utf-8-sig").read()
    t = t[t.find("*** START"):t.find("*** END")]
    t = re.sub(r"\s+", " ", t.replace("’", "'").replace("“", '"').replace("”", '"'))
    for s in re.split(r"(?<=[.!?])\s+", t):
        s = s.strip().strip('"').strip()
        s = re.sub(r"[,;:.!?\"]", "", s)
        words = s.split(" ")
        if not 4 <= len(words) <= 12: continue
        if not all(re.fullmatch(r"[a-zA-Z]+", w) for w in words): continue
        # Names and the first word's capital do not matter to the keys: type it all lowercase, skip names.
        if any(w[0].isupper() for w in words[1:] ): continue
        out.append(s.lower())
step = len(out) / 500
pick = [out[int(i * step)] for i in range(500)]
with open(sys.argv[1], "w") as o:
    o.write("# 500 sentences for the touch decoder harness, lowercase, no punctuation or apostrophes.\n")
    o.write("# From two public-domain books (Project Gutenberg #1342 Pride and Prejudice, #1661 The Adventures of Sherlock Holmes).\n")
    for s in pick: o.write(s + "\n")
print(len(out), len(pick))
