"""
Rank vs total messages sent per contact (1:1 chats, merged handles).
Produces a linear + log-log pair per time window.
"""

import glob
import os
import re
import sqlite3
from datetime import datetime

import matplotlib.pyplot as plt

LABEL_TOP_N = 8
MAC_EPOCH = 978307200  # 2001-01-01 UTC in unix seconds

WINDOWS = [
    ("Past 365 days", datetime(2025, 5, 21), "/tmp/rank_vs_sent_365d.png"),
    ("2026 YTD",       datetime(2026, 1, 1), "/tmp/rank_vs_sent_2026.png"),
]


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


def fetch_sent_per_contact(cutoff: datetime) -> list:
    names = build_name_map()
    db = os.path.expanduser("~/Library/Messages/chat.db")
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    cur = c.cursor()
    cutoff_mac_s = cutoff.timestamp() - MAC_EPOCH
    cutoff_mac_ns = cutoff_mac_s * 1e9
    cur.execute(
        """
        SELECT h.id, COUNT(*) AS sent
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat ch ON ch.ROWID = cmj.chat_id
        JOIN handle h ON h.ROWID = COALESCE(
            m.handle_id,
            (SELECT chj.handle_id FROM chat_handle_join chj WHERE chj.chat_id = ch.ROWID LIMIT 1)
        )
        WHERE m.is_from_me = 1
          AND m.associated_message_type = 0
          AND ch.style = 45
          AND (
                (m.date > 1000000000000 AND m.date > ?)
             OR (m.date <= 1000000000000 AND m.date > ?)
          )
        GROUP BY h.id
        """,
        (cutoff_mac_ns, cutoff_mac_s),
    )
    rows = cur.fetchall()
    c.close()

    merged: dict = {}
    for h, sent in rows:
        key_lookup = h.lower() if "@" in h else h
        name = names.get(key_lookup)
        merge_key = ("name", name) if name else ("handle", h)
        if merge_key not in merged:
            merged[merge_key] = {"name": name or "(unknown)", "sent": 0}
        merged[merge_key]["sent"] += sent

    return sorted(merged.values(), key=lambda e: e["sent"], reverse=True)


def plot(ranked: list, out_path: str, window_label: str) -> None:
    ranks = list(range(1, len(ranked) + 1))
    sent = [e["sent"] for e in ranked]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5.5))

    # Linear
    ax1.plot(ranks, sent, color="#08519c", linewidth=1.6, marker="o", markersize=2.5)
    ax1.set_title("Linear")
    ax1.set_xlabel("Rank")
    ax1.set_ylabel(f"Total messages sent ({window_label})")
    ax1.grid(True, alpha=0.25)
    for i in range(min(LABEL_TOP_N, len(ranked))):
        ax1.annotate(
            ranked[i]["name"],
            (ranks[i], sent[i]),
            xytext=(8, 0), textcoords="offset points",
            fontsize=8, va="center",
        )

    # Log-log
    ax2.plot(ranks, sent, color="#08519c", linewidth=1.6, marker="o", markersize=2.5)
    ax2.set_xscale("log")
    ax2.set_yscale("log")
    ax2.set_title("Log-log (reveals the long tail)")
    ax2.set_xlabel("Rank (log)")
    ax2.set_ylabel("Total sent (log)")
    ax2.grid(True, which="both", alpha=0.25)
    for i in range(min(LABEL_TOP_N, len(ranked))):
        ax2.annotate(
            ranked[i]["name"],
            (ranks[i], sent[i]),
            xytext=(6, 4), textcoords="offset points",
            fontsize=8,
        )

    fig.suptitle(
        f"Rank vs messages sent ({window_label}) — {len(ranked):,} unique contacts, "
        f"{sum(sent):,} total sent (1:1 chats)",
        fontsize=11,
    )
    fig.tight_layout()
    fig.savefig(out_path, dpi=140)
    print(f"Saved: {out_path}")
    print(f"Contacts: {len(ranked):,}")
    print(f"Total sent: {sum(sent):,}")
    print(f"Top 20 share: {sum(sent[:20]) / sum(sent) * 100:.1f}%")
    print(f"Top 5  share: {sum(sent[:5]) / sum(sent) * 100:.1f}%")


def main() -> None:
    for label, cutoff, out in WINDOWS:
        print(f"\n=== {label} (since {cutoff.date()}) ===")
        ranked = fetch_sent_per_contact(cutoff)
        plot(ranked, out, label)


if __name__ == "__main__":
    main()
