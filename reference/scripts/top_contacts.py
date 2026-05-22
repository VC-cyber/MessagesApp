"""
Top 20 iMessage contacts by total messages exchanged (1:1 chats, no reactions).
Shows sent/received breakdown. Uses macOS Contacts to resolve names.

Requirements: terminal with Full Disk Access, Python 3.
Run: python3 /tmp/top_contacts.py
"""

import glob
import os
import re
import sqlite3

LIMIT = 20


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


def main() -> None:
    names = build_name_map()
    db = os.path.expanduser("~/Library/Messages/chat.db")
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    cur = c.cursor()
    cur.execute(
        """
        SELECT
            h.id,
            SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
            SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS recv,
            COUNT(*) AS total
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat ch ON ch.ROWID = cmj.chat_id
        JOIN handle h ON h.ROWID = COALESCE(
            m.handle_id,
            (SELECT chj.handle_id FROM chat_handle_join chj WHERE chj.chat_id = ch.ROWID LIMIT 1)
        )
        WHERE m.associated_message_type = 0
          AND ch.style = 45
        GROUP BY h.id
        """
    )
    rows = cur.fetchall()
    c.close()

    # Merge handles that resolve to the same contact name.
    merged: dict = {}  # key -> {"name", "handles":[...], "sent", "recv", "total"}
    for h, sent, recv, total in rows:
        key_lookup = h.lower() if "@" in h else h
        name = names.get(key_lookup)
        merge_key = ("name", name) if name else ("handle", h)
        entry = merged.setdefault(
            merge_key,
            {"name": name or "(unknown)", "handles": [], "sent": 0, "recv": 0, "total": 0},
        )
        entry["handles"].append(h)
        entry["sent"] += sent
        entry["recv"] += recv
        entry["total"] += total

    top = sorted(merged.values(), key=lambda e: e["total"], reverse=True)[:LIMIT]

    print(f"{'#':>3}  {'Name':<26} {'Handle(s)':<32} {'Sent':>7} {'Recv':>7} {'Total':>8}")
    print("-" * 88)
    for i, e in enumerate(top, 1):
        handle_str = e["handles"][0]
        if len(e["handles"]) > 1:
            handle_str += f" (+{len(e['handles']) - 1})"
        print(
            f"{i:>3}  {e['name']:<26} {handle_str:<32} "
            f"{e['sent']:>7,} {e['recv']:>7,} {e['total']:>8,}"
        )


if __name__ == "__main__":
    main()
