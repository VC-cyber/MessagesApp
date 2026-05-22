"""How many messages in 2026 so far (Jan 1 → today)."""

import os
import sqlite3
from datetime import datetime

DB = os.path.expanduser("~/Library/Messages/chat.db")
MAC_EPOCH = 978307200
START = datetime(2026, 1, 1)
END = datetime.now()

start_s = START.timestamp() - MAC_EPOCH
end_s = END.timestamp() - MAC_EPOCH

c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
cur = c.cursor()
cur.execute(
    """
    SELECT
        SUM(CASE WHEN is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
        SUM(CASE WHEN is_from_me = 0 THEN 1 ELSE 0 END) AS recv,
        COUNT(*) AS total
    FROM message
    WHERE associated_message_type = 0
      AND (
            (date > 1000000000000 AND date >= ? AND date < ?)
         OR (date <= 1000000000000 AND date >= ? AND date < ?)
      )
    """,
    (start_s * 1e9, end_s * 1e9, start_s, end_s),
)
sent, recv, total = cur.fetchone()
c.close()

days = (END - START).days + 1
print(f"2026 so far ({START.date()} → {END.date()}, {days} days):")
print(f"  Sent by you:   {sent:>7,}  ({sent / days:.1f}/day)")
print(f"  Received:      {recv:>7,}  ({recv / days:.1f}/day)")
print(f"  Total:         {total:>7,}  ({total / days:.1f}/day)")
