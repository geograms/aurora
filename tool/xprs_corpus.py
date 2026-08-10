#!/usr/bin/env python3
"""Regenerate test/xprs_corpus.json from docs/XPRS.md.

The specification is the test corpus. Every example packet in the document,
the byte count the document claims for it, and the identifier derived by this
script are written out as fixtures for test/xprs_packet_test.dart.

The identifier here is computed independently of the Dart codec, deliberately.
Two implementations in two languages agreeing on all ~200 identifiers is the
only evidence that either of them reads section 5 correctly; a codec checked
against itself proves nothing.

Run after editing any example packet in the specification:

    python3 tool/xprs_corpus.py

CI note: if this output differs from the committed file, either the document
changed or a derivation did. Both want a human to look.
"""

import hashlib
import json
import pathlib
import re

DOC = pathlib.Path("docs/XPRS.md")
OUT = pathlib.Path("test/xprs_corpus.json")

# The document writes placeholders for values it does not spell out in full.
EXPAND = {"<60 characters>": "K" * 60, "<64 characters>": "C" * 64}

KEY = re.compile(r"[a-z][a-z0-9]{0,7}")


def expand(t):
    for k, v in EXPAND.items():
        t = t.replace(k, v)
    return t


def fields(wire):
    """Parse a packet the way section 4 says to. Mirrors XprsPacket.parse."""
    out, i = [], 0
    while i < len(wire):
        if wire.startswith("m:", i):  # `m:` is last and runs to the end
            out.append(("m", wire[i + 2:]))
            break
        end = wire.find(" ", i)
        end = len(wire) if end < 0 else end
        tok, i = wire[i:end], end + 1
        c = tok.find(":")
        if c <= 0:
            continue
        key = tok[:c]
        if not KEY.fullmatch(key):
            continue
        out.append((key, tok[c + 1:]))
    return out


def identifier(wire):
    """Section 5: sha256 of the packet with sig: and via: removed, first 6 hex."""
    canon = " ".join(
        f"{k}:{v}" for k, v in fields(wire) if k not in ("sig", "via"))
    return hashlib.sha256(canon.encode()).hexdigest()[:6]


def stated_bytes(doc):
    """Every byte count the document claims, keyed by the packet it describes."""
    out = {}
    # one fenced packet, then "N bytes"
    for m in re.finditer(r"```\n(t:[^\n]*)\n```\n\n(\d+) bytes", doc):
        out[expand(m.group(1))] = int(m.group(2))
    # a fenced block of several, then "A, B and C bytes"
    for m in re.finditer(
            r"```\n((?:(?:\d+  )?t:[^\n]*\n|   [^\n]*\n)+)```\n\n([\d,and ]+?) bytes",
            doc):
        lines = [re.sub(r"^\d+  ", "", l)
                 for l in m.group(1).strip().split("\n")
                 if re.match(r"(\d+  )?t:", l)]
        want = [int(x) for x in re.findall(r"\d+", m.group(2))]
        if len(want) == len(lines):
            for l, w in zip(lines, want):
                out[expand(l)] = w
    # the inline "NNN  t:..." form; below 40 it is a step number, not a count
    for m in re.finditer(r"^(\d+)  (t:\S.*)$", doc, re.M):
        if int(m.group(1)) >= 40:
            out[expand(m.group(2))] = int(m.group(1))
    return out


def main():
    doc = DOC.read_text(encoding="utf-8")
    counts = stated_bytes(doc)

    corpus, seen = [], set()
    for line in doc.split("\n"):
        m = re.match(r"\s*(?:\d+  )?(t:\w+ f:.*)$", line)
        if not m:
            continue
        wire = expand(m.group(1))
        if wire in seen:
            continue
        seen.add(wire)
        corpus.append({
            "wire": wire,
            "bytes": counts.get(wire),
            "id": identifier(wire),
        })

    OUT.write_text(json.dumps(corpus, indent=0), encoding="utf-8")
    withb = sum(1 for c in corpus if c["bytes"])
    print(f"{OUT}: {len(corpus)} packets, {withb} with a stated byte count")


if __name__ == "__main__":
    main()
