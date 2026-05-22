#!/usr/bin/env python3
"""
Empirical diagnostic for the typedstream length-prefix leak.

Pulls ~5000 random messages with attributedBody from the user's chat.db,
simulates the Swift `AttributedBodyDecoder` pipeline, and reports:

  1. How many decoded bodies have a leading-char artifact under the BROAD
     heuristic: leading printable-ASCII char whose byte value == rest of
     the body's UTF-8 byte length.
  2. Histogram of the leaked byte values (i.e. which one-byte string
     lengths leak — should cluster around printable ASCII 32-126).
  3. Spot-check: 30 random examples of the artifact for human review.
  4. False-positive check: count and print messages where the strip
     WOULD happen but it MIGHT be legit (e.g. message that legitimately
     starts with a letter and happens to be exactly V+1 bytes total).

Read-only against chat.db. No write side-effects.
"""

from __future__ import annotations

import random
import sqlite3
import unicodedata
from collections import Counter
from pathlib import Path

DB = Path("/Users/satyajit/Library/Messages/chat.db")
SAMPLE_SIZE = 5000


# ---------- replica of the Swift decoder pipeline ----------

EXACT_METADATA: set[str] = {
    "streamtyped",
    "NSObject",
    "NSString", "NSMutableString",
    "NSAttributedString", "NSMutableAttributedString",
    "NSDictionary", "NSMutableDictionary",
    "NSArray", "NSMutableArray",
    "NSNumber", "NSValue",
    "NSData", "NSMutableData",
    "NSDate", "NSUUID", "NSURL",
    "iI",
}

# Mirrors Swift's edge-stripping character set in AttributedBodyDecoder.strippedFraming.
EDGE_CHARS = set("+@()[]{}<>!*&^%$#")
EDGE_CHARS.update(chr(c) for c in range(0x01, 0x09))  # \x01..\x08
EDGE_CHARS.update(" \t\r\n ")  # whitespace incl. nbsp


def is_printable_scalar(ch: str) -> bool:
    """Replica of Swift AttributedBodyDecoder.isPrintable."""
    v = ord(ch)
    if v == 0xFFFD:
        return False
    if 0x20 <= v <= 0x7E:
        return True
    if v == 0x09 or v == 0x0A:
        return True
    if 0xA0 <= v <= 0xFFFC:
        return True
    return False


def printable_runs(s: str, minimum: int = 2) -> list[str]:
    runs: list[str] = []
    cur: list[str] = []
    for ch in s:
        if is_printable_scalar(ch):
            cur.append(ch)
        else:
            if len(cur) >= minimum:
                runs.append("".join(cur))
            cur = []
    if len(cur) >= minimum:
        runs.append("".join(cur))
    return runs


def strip_framing(run: str) -> str:
    """Trim edge-framing chars but DO NOT strip length prefix (we want to see
    it in the diagnostic)."""
    return run.strip("".join(EDGE_CHARS))


def looks_like_metadata(run: str) -> bool:
    if run in EXACT_METADATA:
        return True
    if run.startswith("__kIM"):
        return True
    if run.startswith("NS."):
        return True
    return False


def decode_body_with_prefix(blob: bytes) -> str:
    """Returns the longest non-metadata run AFTER edge-framing strip but
    BEFORE length-prefix removal. This is what the user sees when the
    prefix leaks."""
    decoded = blob.decode("utf-8", errors="replace")
    candidates = [strip_framing(r) for r in printable_runs(decoded, minimum=2)]
    candidates = [c for c in candidates if c and not looks_like_metadata(c)]
    if not candidates:
        return ""
    return max(candidates, key=len)


# ---------- the bug detector ----------

def detect_length_prefix(body: str) -> tuple[bool, int, int]:
    """Returns (is_artifact, leading_byte_value, rest_utf8_length).

    is_artifact is True iff:
      - leading char is printable ASCII (0x20-0x7E)
      - rest (everything after the first scalar) has UTF-8 byte length
        exactly equal to the leading char's byte value.
    """
    if not body:
        return (False, 0, 0)
    first = body[0]
    v = ord(first)
    if not (0x20 <= v <= 0x7E):
        return (False, v, 0)
    rest = body[1:]
    rest_len = len(rest.encode("utf-8"))
    return (rest_len == v, v, rest_len)


def could_be_legit(body: str) -> bool:
    """Heuristic: when stripping a leading printable-ASCII char that ISN'T a
    digit, the result COULD be legit content. Returns True if the leading
    char is:
      - a letter, AND
      - the next char is also a letter or punctuation (i.e. plausible start
        of a sentence/word/name)
    Mainly used to surface potentially scary cases for visual review.
    """
    if len(body) < 2:
        return False
    first, second = body[0], body[1]
    if not first.isalpha():
        return False
    if second.isalpha() or second in ".,!?;:'\" -":
        return True
    return False


# ---------- main ----------

def main() -> None:
    if not DB.exists():
        raise SystemExit(f"chat.db not found at {DB}")

    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    # Pull a random sample of messages with attributedBody.
    # Use ORDER BY RANDOM() over a COUNT-limited subset to avoid scanning
    # everything — but in practice the user has ~574k of these, and even
    # 5000 random is fast.
    rows = conn.execute(
        """
        SELECT ROWID, attributedBody
        FROM message
        WHERE attributedBody IS NOT NULL
        ORDER BY RANDOM()
        LIMIT ?
        """,
        (SAMPLE_SIZE,),
    ).fetchall()
    conn.close()

    print(f"Sampled {len(rows)} messages with attributedBody from chat.db")
    print()

    total_decoded = 0
    artifacts: list[tuple[int, int, str]] = []  # (rowid, leading_byte, decoded_body)
    histogram: Counter[int] = Counter()
    legit_suspects: list[tuple[int, str]] = []

    for rowid, blob in rows:
        if not blob:
            continue
        body = decode_body_with_prefix(bytes(blob))
        if not body:
            continue
        total_decoded += 1

        is_artifact, v, _ = detect_length_prefix(body)
        if is_artifact:
            artifacts.append((rowid, v, body))
            histogram[v] += 1
            if not body[0].isdigit() and could_be_legit(body):
                legit_suspects.append((rowid, body))

    print(f"Bodies successfully decoded:           {total_decoded}")
    print(f"Artifacts detected (broad heuristic):  {len(artifacts)}")
    print(f"  -> rate: {100*len(artifacts)/max(total_decoded,1):.2f}%")
    print()

    # Histogram by category.
    digits = sum(c for v, c in histogram.items() if 0x30 <= v <= 0x39)
    letters = sum(c for v, c in histogram.items() if (0x41 <= v <= 0x5A) or (0x61 <= v <= 0x7A))
    other_printable = sum(c for v, c in histogram.items() if 0x20 <= v <= 0x7E) - digits - letters
    print("By category (broad heuristic):")
    print(f"  ASCII digits (0x30-0x39):     {digits}   <- already covered by current narrow fix")
    print(f"  ASCII letters (A-Z, a-z):     {letters}  <- broad fix adds these")
    print(f"  Other printable (space, $, !, ?, etc.): {other_printable}")
    print()

    print("Histogram of leading byte values (top 30 by count):")
    for v, c in histogram.most_common(30):
        ch = chr(v) if 0x20 <= v <= 0x7E else f"\\x{v:02x}"
        kind = "digit" if 0x30 <= v <= 0x39 else ("letter" if v in range(0x41, 0x5B) or v in range(0x61, 0x7B) else "other")
        print(f"  v={v:3d} '{ch}' ({kind:6s}): {c} messages, msg-byte-len={v}")
    print()

    # Spot-check.
    if artifacts:
        sample_n = min(30, len(artifacts))
        sample = random.sample(artifacts, sample_n)
        print(f"Spot-check ({sample_n} random artifacts) — look for leading-char vs. real content:")
        for rowid, v, body in sample:
            display = body[:120] + ("..." if len(body) > 120 else "")
            print(f"  ROWID={rowid:8d} leadByte={v:3d} ('{chr(v) if 0x20<=v<=0x7E else '?'}'): {display!r}")
        print()

    # False-positive check — print ALL legit-looking suspects (letters case).
    print(f"False-positive suspects (leading-LETTER artifacts that LOOK like legit content): {len(legit_suspects)}")
    if legit_suspects:
        print()
        print("Full bodies of suspects (decide visually whether stripping would corrupt content):")
        for rowid, body in legit_suspects:
            print(f"  ROWID={rowid}: full body =")
            print(f"    {body!r}")
            print(f"    (full UTF-8 byte len of full body = {len(body.encode('utf-8'))})")
            print()


if __name__ == "__main__":
    random.seed(42)
    main()
