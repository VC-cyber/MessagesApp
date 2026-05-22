#!/usr/bin/env python3
"""
Post-fix verification — measure the residual artifact rate after applying
the broadened `stripLengthPrefix` rule. Counts:

  - Before (broad rule unfixed):  artifacts in the decoded bodies
  - After  (broad rule applied):  residual artifacts in the decoded bodies

Same chat.db sample. Read-only.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).parent))
from diagnose_length_prefix import (
    decode_body_with_prefix,
    detect_length_prefix,
)

DB = Path("/Users/satyajit/Library/Messages/chat.db")
SAMPLE_SIZE = 5000


def strip_length_prefix_broad(body: str) -> str:
    """Replica of the new broadened Swift stripLengthPrefix."""
    if not body:
        return body
    v = ord(body[0])
    if not (0x20 <= v <= 0x7E):
        return body
    rest = body[1:]
    if len(rest.encode("utf-8")) != v:
        return body
    return rest


def main() -> None:
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
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

    decoded_count = 0
    before_artifacts = 0
    after_artifacts = 0

    for rowid, blob in rows:
        if not blob:
            continue
        body = decode_body_with_prefix(bytes(blob))
        if not body:
            continue
        decoded_count += 1

        is_artifact_before, _, _ = detect_length_prefix(body)
        if is_artifact_before:
            before_artifacts += 1

        fixed = strip_length_prefix_broad(body)
        is_artifact_after, _, _ = detect_length_prefix(fixed)
        if is_artifact_after:
            after_artifacts += 1

    print(f"Sample size:                   {len(rows)}")
    print(f"Successfully decoded:          {decoded_count}")
    print(f"Artifacts BEFORE broad fix:    {before_artifacts}  ({100*before_artifacts/max(decoded_count,1):.2f}%)")
    print(f"Artifacts AFTER broad fix:     {after_artifacts}  ({100*after_artifacts/max(decoded_count,1):.2f}%)")
    print(f"Reduction:                     {before_artifacts - after_artifacts} fewer leaks")
    print()
    if after_artifacts:
        print("Note: residual non-zero counts would indicate the stripped body STILL")
        print("matches the broad-rule pattern (e.g. the new first byte is again a")
        print("printable-ASCII char whose value equals the rest's byte length).")
        print("These are vanishingly rare cascades; we don't loop in the production code.")


if __name__ == "__main__":
    import random
    random.seed(42)
    main()
