"""
Search iMessage text for a phrase within a date window.
Handles both `text` (plain) and `attributedBody` (NSAttributedString blob, post-2020).
"""

from __future__ import annotations

import glob
import os
import re
import sqlite3
from datetime import datetime

PHRASES = ["cactus offer", "BOTH:cactus+offer", "offer"]
START = datetime(2025, 12, 1)
END = datetime(2026, 2, 1)  # exclusive — covers Dec + Jan
MAC_EPOCH = 978307200
PRINT_BODIES_FOR = {"cactus offer", "BOTH:cactus+offer", "offer"}


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


def resolve(handle: str | None, names: dict) -> str:
    if not handle:
        return "(you)"
    key = handle.lower() if "@" in handle else handle
    return names.get(key, handle)


def extract_text(text: str | None, body: bytes | None) -> str:
    if text:
        return text
    if not body:
        return ""
    # attributedBody is a typedstream blob; the actual text bytes sit inside it.
    # Decoding with errors=ignore strips the binary framing well enough for search.
    decoded = body.decode("utf-8", errors="ignore")
    # The text is usually right after "NSString" + a length byte. Pull the longest
    # printable run, which is almost always the message body.
    runs = re.findall(r"[ -~\n -￿]{4,}", decoded)
    if not runs:
        return decoded.strip()
    return max(runs, key=len).strip()


def main() -> None:
    names = build_name_map()
    db = os.path.expanduser("~/Library/Messages/chat.db")
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    cur = c.cursor()

    start_s = START.timestamp() - MAC_EPOCH
    end_s = END.timestamp() - MAC_EPOCH
    start_ns = start_s * 1e9
    end_ns = end_s * 1e9

    # Pull all messages in the window; filter for the phrase in Python so we
    # can search both the text column and the binary attributedBody.
    cur.execute(
        """
        SELECT
            m.ROWID,
            m.date,
            m.is_from_me,
            m.text,
            m.attributedBody,
            h.id AS sender_handle,
            ch.ROWID AS chat_id,
            ch.display_name,
            ch.style
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat ch ON ch.ROWID = cmj.chat_id
        WHERE m.associated_message_type = 0
          AND (
                (m.date > 1000000000000 AND m.date BETWEEN ? AND ?)
             OR (m.date <= 1000000000000 AND m.date BETWEEN ? AND ?)
          )
        ORDER BY m.date ASC
        """,
        (start_ns, end_ns, start_s, end_s),
    )

    # For chat-partner resolution
    chat_partners: dict = {}

    def partners_for(chat_id: int, display: str | None, style: int) -> str:
        if chat_id in chat_partners:
            return chat_partners[chat_id]
        if display:
            label = f"[group] {display}"
        elif style == 43:
            cur2 = c.cursor()
            cur2.execute(
                """
                SELECT h.id FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = ?
                """,
                (chat_id,),
            )
            members = [resolve(r[0], names) for r in cur2.fetchall()]
            label = "[group] " + ", ".join(members[:4]) + (f" +{len(members)-4}" if len(members) > 4 else "")
        else:
            cur2 = c.cursor()
            cur2.execute(
                """
                SELECT h.id FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = ?
                LIMIT 1
                """,
                (chat_id,),
            )
            row = cur2.fetchone()
            label = resolve(row[0] if row else None, names)
        chat_partners[chat_id] = label
        return label

    all_rows = cur.fetchall()

    print(f"Scanned {len(all_rows):,} messages between {START.date()} and {END.date()}\n")

    for phrase in PHRASES:
        if phrase.startswith("BOTH:"):
            needles = phrase[len("BOTH:"):].split("+")
            needles = [n.lower() for n in needles]
            match = lambda txt, ns=needles: all(n in txt.lower() for n in ns)
        else:
            needle = phrase.lower()
            match = lambda txt, n=needle: n in txt.lower()
        hits = []
        for row in all_rows:
            rowid, date_raw, is_from_me, text, body, sender, chat_id, display, style = row
            full_text = extract_text(text, body)
            if not match(full_text):
                continue
            ts = date_raw / 1e9 if date_raw > 1_000_000_000_000 else date_raw
            dt = datetime.fromtimestamp(ts + MAC_EPOCH)
            sender_label = "You" if is_from_me else resolve(sender, names)
            partner_label = partners_for(chat_id, display, style)
            hits.append((dt, sender_label, partner_label, full_text))

        print(f"=== '{phrase}': {len(hits)} hit(s) ===")
        if phrase in PRINT_BODIES_FOR:
            for dt, sender, partner, text in hits:
                preview = text if len(text) < 400 else text[:380] + "…"
                print(f"  [{dt:%Y-%m-%d %H:%M}] {partner}  |  {sender}: {preview}")
        elif hits:
            # Just show counts by sender (you vs others) and a sample
            from_you = sum(1 for h in hits if h[1] == "You")
            print(f"  {from_you} from you, {len(hits) - from_you} from others")
            print(f"  sample: [{hits[0][0]:%Y-%m-%d %H:%M}] {hits[0][1]}: {hits[0][3][:120]}")
        print()

    c.close()


if __name__ == "__main__":
    main()
