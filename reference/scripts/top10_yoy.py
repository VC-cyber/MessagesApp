"""
Top 10 1:1 contacts in each school year (Sep 1 → May 21), side by side.
Ranks by total messages exchanged. Shows sent / received / total + rank delta.
"""

from __future__ import annotations

import glob
import os
import re
import sqlite3

import pandas as pd

DB = os.path.expanduser("~/Library/Messages/chat.db")
MAC_EPOCH = 978307200

YEARS = {
    "2024-25": (pd.Timestamp("2024-09-01"), pd.Timestamp("2025-05-22")),
    "2025-26": (pd.Timestamp("2025-09-01"), pd.Timestamp("2026-05-22")),
}
TOP_N = 10


def build_name_map() -> dict:
    name_map: dict = {}
    pattern = os.path.expanduser(
        "~/Library/Application Support/AddressBook/Sources/*/AddressBook-v22.abcddb"
    )
    for db in glob.glob(pattern):
        try:
            c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            cur = c.cursor()
            cur.execute(
                """
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, p.ZFULLNUMBER, e.ZADDRESS
                FROM ZABCDRECORD r
                LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
                LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
                """
            )
            for fn, ln, ph, em in cur.fetchall():
                name = " ".join(x for x in [fn, ln] if x).strip()
                if not name:
                    continue
                if ph:
                    d = re.sub(r"\D", "", ph)
                    if d:
                        if len(d) == 10:
                            d = "1" + d
                        name_map["+" + d] = name
                if em:
                    name_map[em.lower()] = name
            c.close()
        except Exception:
            pass
    return name_map


def fetch_year(names: dict, start: pd.Timestamp, end: pd.Timestamp) -> list[dict]:
    c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    cur = c.cursor()
    s_s = start.timestamp() - MAC_EPOCH
    e_s = end.timestamp() - MAC_EPOCH
    cur.execute(
        """
        SELECT
            h.id,
            SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
            SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS recv
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat ch ON ch.ROWID = cmj.chat_id
        JOIN handle h ON h.ROWID = COALESCE(
            m.handle_id,
            (SELECT chj.handle_id FROM chat_handle_join chj WHERE chj.chat_id = ch.ROWID LIMIT 1)
        )
        WHERE m.associated_message_type = 0
          AND ch.style = 45
          AND (
                (m.date > 1000000000000 AND m.date >= ? AND m.date < ?)
             OR (m.date <= 1000000000000 AND m.date >= ? AND m.date < ?)
          )
        GROUP BY h.id
        """,
        (s_s * 1e9, e_s * 1e9, s_s, e_s),
    )
    rows = cur.fetchall()
    c.close()

    merged: dict = {}
    for h, sent, recv in rows:
        key_lookup = h.lower() if "@" in h else h
        name = names.get(key_lookup)
        merge_key = ("name", name) if name else ("handle", h)
        if merge_key not in merged:
            merged[merge_key] = {"name": name or "(unknown)", "sent": 0, "recv": 0}
        merged[merge_key]["sent"] += sent
        merged[merge_key]["recv"] += recv
    for e in merged.values():
        e["total"] = e["sent"] + e["recv"]
    return sorted(merged.values(), key=lambda e: e["total"], reverse=True)


def main() -> None:
    names = build_name_map()
    rankings = {label: fetch_year(names, s, e) for label, (s, e) in YEARS.items()}

    # Rank lookup tables
    rank_of = {
        label: {e["name"]: i + 1 for i, e in enumerate(ranked)}
        for label, ranked in rankings.items()
    }

    labels = list(YEARS.keys())  # ["2024-25", "2025-26"]
    print(f"\nTop {TOP_N} 1:1 contacts by total messages — Sep 1 → May 21\n")
    header = (
        f"{'#':>2}  "
        f"{labels[0]:<32s} {'Sent':>6} {'Recv':>6} {'Total':>7}     "
        f"{labels[1]:<32s} {'Sent':>6} {'Recv':>6} {'Total':>7}  Δrank"
    )
    print(header)
    print("-" * len(header))
    for i in range(TOP_N):
        a = rankings[labels[0]][i] if i < len(rankings[labels[0]]) else None
        b = rankings[labels[1]][i] if i < len(rankings[labels[1]]) else None
        a_str = (
            f"{a['name']:<32s} {a['sent']:>6,} {a['recv']:>6,} {a['total']:>7,}"
            if a else " " * 56
        )
        b_str = (
            f"{b['name']:<32s} {b['sent']:>6,} {b['recv']:>6,} {b['total']:>7,}"
            if b else " " * 56
        )
        # Δrank: where was this year's #i in last year?
        delta = ""
        if b:
            prev = rank_of[labels[0]].get(b["name"])
            if prev is None:
                delta = "NEW"
            else:
                d = prev - (i + 1)
                if d > 0:
                    delta = f"+{d}"
                elif d < 0:
                    delta = str(d)
                else:
                    delta = "="
        print(f"{i+1:>2}  {a_str}     {b_str}  {delta:>5}")

    # Movers in/out
    top_a_names = {e["name"] for e in rankings[labels[0]][:TOP_N]}
    top_b_names = {e["name"] for e in rankings[labels[1]][:TOP_N]}
    dropped = top_a_names - top_b_names
    new_entries = top_b_names - top_a_names
    print(f"\nDropped out of top {TOP_N}: {sorted(dropped) if dropped else 'none'}")
    print(f"New in top {TOP_N}:        {sorted(new_entries) if new_entries else 'none'}")

    # Per-contact deltas for everyone who was top-10 in either year
    print(f"\nYear-over-year change for contacts in either top {TOP_N}:")
    union = sorted(top_a_names | top_b_names)
    print(f"  {'Name':<28} {'24-25 total':>11} {'25-26 total':>11} {'Δ':>8} {'Δ%':>7}")
    a_totals = {e["name"]: e["total"] for e in rankings[labels[0]]}
    b_totals = {e["name"]: e["total"] for e in rankings[labels[1]]}
    rows = []
    for name in union:
        a_t = a_totals.get(name, 0)
        b_t = b_totals.get(name, 0)
        d = b_t - a_t
        d_pct = (d / a_t * 100) if a_t else float("inf")
        rows.append((name, a_t, b_t, d, d_pct))
    rows.sort(key=lambda r: r[3], reverse=True)
    for name, a_t, b_t, d, d_pct in rows:
        d_pct_str = "  NEW" if d_pct == float("inf") else f"{d_pct:+6.0f}%"
        print(f"  {name:<28} {a_t:>11,} {b_t:>11,} {d:>+8,} {d_pct_str:>7}")


if __name__ == "__main__":
    main()
