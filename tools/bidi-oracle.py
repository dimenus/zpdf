# /// script
# requires-python = ">=3.11"
# dependencies = ["python-bidi==0.4.2"]
# ///
"""Write tests/bidi/cases.tsv: mixed Hebrew/Latin/digit/punctuation lines and their visual order
by Unicode's bidi algorithm (UAX #9), for the test that measures zpdf's line order.

    uv run tools/bidi-oracle.py tests/bidi/cases.tsv

The oracle is python-bidi 0.4.2's pure-Python UAX #9 (an implementation zpdf shares nothing with):
each character is tagged with its logical index before rule L reorders them, so the output is the
visual order of indices. One line per case:

    <paragraph direction: ltr | rtl | auto>\t<visual order, comma-separated codepoint indices>\t<text>

The texts are random joins (fixed seed) of a few words, digits and punctuation, chosen so that
NotoIKEAHebrewLatin-Regular shapes one glyph per codepoint (no ligatures, no marks), plus a few
hand-picked lines. Regenerating gives the same file; changing the word list changes the cases.
"""

import random
import sys

from bidi import algorithm as a

WORDS = ["שלום", "עולם", "abc", "dex", "123", "45", "(", ")", ".", ",", "!", "-", "\"", "[", "]"]
EXTRA = ["שלום abc", "(שלום", "abc (שלום)", "שלום (abc)", "abc 123 שלום", "שלום 123 abc", "שלום, abc! עולם."]


def visual(text, direction):
    storage = a.get_empty_storage()
    base_level = a.get_base_level(text, False) if direction == "auto" else a.PARAGRAPH_LEVELS["L" if direction == "ltr" else "R"]
    storage["base_level"] = base_level
    storage["base_dir"] = ("L", "R")[base_level]
    a.get_embedding_levels(text, storage, False, False)
    for i, ch in enumerate(storage["chars"]):
        ch["idx"] = i
    a.explicit_embed_and_overrides(storage, False)
    a.resolve_weak_types(storage, False)
    a.resolve_neutral_types(storage, False)
    a.resolve_implicit_levels(storage, False)
    a.reorder_resolved_levels(storage, False)
    return [c["idx"] for c in storage["chars"]]


def main():
    random.seed(7)
    texts = set(EXTRA)
    for n in range(2, 6):
        for _ in range(60):
            parts = [random.choice(WORDS) for _ in range(n)]
            texts.add(" ".join(parts))
            texts.add("".join(parts))
    with open(sys.argv[1], "w", encoding="utf-8") as out:
        for text in sorted(texts):
            for direction in ("ltr", "rtl", "auto"):
                order = ",".join(map(str, visual(text, direction)))
                out.write(f"{direction}\t{order}\t{text}\n")


if __name__ == "__main__":
    main()
