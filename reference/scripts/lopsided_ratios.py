"""
Most lopsided sent/received ratios in 1:1 chats.
Default window: 2025-26 school year (Sep 1 → today). Min 100 messages total.
"""

from __future__ import annotations

import glob
import os
import re
import sqlite3

import pandas as pd

DB = os.path.expanduser("~/Library/Messages/chat.db")
MAC_EPOCH = 978307200

WINDOWS = {
    "2025-26 (Sep 1 → today)": (pd.Timestamp("2025-09-01"), pd.Timestamp.today().normalize() + pd.Timedelta(days=1)),
    "All-time":                (pd.Timestamp("2000-01-01"), pd.Timestamp.today().normalize() + pd.Timedelta(days=1)),
}
MIN_TOTAL = 100
TOP_N = 15


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


def fetch(names: dict, start: pd.Timestamp, end: pd.Timestamp) -> list[dict]:
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
            merged[merge_key] = {"name": name or "(unknown)", "handle": h, "sent": 0, "recv": 0}
        merged[merge_key]["sent"] += sent
        merged[merge_key]["recv"] += recv
    return list(merged.values())


def label(name: str, handle: str) -> str:
    if name != "(unknown)":
        return name
    return handle  # fall back to phone/email


def print_ratios(window_name: str, contacts: list[dict]) -> None:
    # Keep only contacts with at least MIN_TOTAL combined.
    qualified = [c for c in contacts if c["sent"] + c["recv"] >= MIN_TOTAL]
    print(f"\n{'=' * 88}")
    print(f"{window_name}   (min {MIN_TOTAL} total messages, {len(qualified)} contacts qualify)")
    print("=" * 88)

    # 1) They text you way more than you text them (recv >> sent)
    them = sorted(qualified, key=lambda e: e["recv"] / max(e["sent"], 1), reverse=True)[:TOP_N]
    print(f"\nThey >> You  (ratio = recv ÷ sent, most one-sided in their favor)")
    print(f"  {'Name':<30s} {'Sent':>6} {'Recv':>6} {'Ratio':>8}  {'Note':<30s}")
    print(f"  {'-'*30} {'-'*6} {'-'*6} {'-'*8}  {'-'*30}")
    for c in them:
        ratio = c["recv"] / max(c["sent"], 1)
        note = "you barely reply" if c["sent"] < 20 else f"they text {ratio:.1f}x more"
        nm = label(c["name"], c["handle"])
        print(f"  {nm:<30s} {c['sent']:>6,} {c['recv']:>6,} {ratio:>7.2f}x  {note:<30s}")

    # 2) You text them way more than they text you (sent >> recv)
    me = sorted(qualified, key=lambda e: e["sent"] / max(e["recv"], 1), reverse=True)[:TOP_N]
    print(f"\nYou >> Them  (ratio = sent ÷ recv, most one-sided in your favor)")
    print(f"  {'Name':<30s} {'Sent':>6} {'Recv':>6} {'Ratio':>8}  {'Note':<30s}")
    print(f"  {'-'*30} {'-'*6} {'-'*6} {'-'*8}  {'-'*30}")
    for c in me:
        ratio = c["sent"] / max(c["recv"], 1)
        note = "they barely reply" if c["recv"] < 20 else f"you text {ratio:.1f}x more"
        nm = label(c["name"], c["handle"])
        print(f"  {nm:<30s} {c['sent']:>6,} {c['recv']:>6,} {ratio:>7.2f}x  {note:<30s}")


def main() -> None:
    names = build_name_map()
    for label_, (s, e) in WINDOWS.items():
        contacts = fetch(names, s, e)
        print_ratios(label_, contacts)


if __name__ == "__main__":
    main()
