"""
Plot iMessages sent per day over the past 365 days with a 7-day rolling average.

Requirements:
  - macOS with Messages.app
  - Terminal/iTerm granted Full Disk Access
  - pip install matplotlib pandas

Run:
  python3 /tmp/sent_messages_chart.py
"""

import os
import sqlite3
import sys
from datetime import datetime, timedelta

import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

DB = os.path.expanduser("~/Library/Messages/chat.db")
DAYS = 365
OUT_PNG = "/tmp/sent_messages_per_day.png"


def load_sent_per_day(db_path: str, days: int) -> pd.DataFrame:
    # Open read-only so we never accidentally touch the live DB.
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    cur = conn.cursor()

    # `message.date` is Mac absolute time:
    #   - Post-macOS 10.13: nanoseconds since 2001-01-01 UTC
    #   - Pre-10.13:        seconds since 2001-01-01 UTC
    # The SQL below auto-handles both: anything > 1e12 we treat as nanoseconds.
    cutoff_unix = (datetime.now() - timedelta(days=days)).timestamp()
    mac_epoch = 978307200  # 2001-01-01 UTC in unix seconds
    cutoff_mac_s = cutoff_unix - mac_epoch
    cutoff_mac_ns = cutoff_mac_s * 1e9

    cur.execute(
        """
        SELECT
            date(
                datetime(
                    CASE WHEN date > 1000000000000
                         THEN date / 1000000000
                         ELSE date
                    END + 978307200,
                    'unixepoch', 'localtime'
                )
            ) AS day,
            COUNT(*) AS sent
        FROM message
        WHERE is_from_me = 1
          AND associated_message_type = 0    -- exclude tapbacks/reactions
          AND (
                (date > 1000000000000 AND date > ?)
             OR (date <= 1000000000000 AND date > ?)
          )
        GROUP BY day
        ORDER BY day
        """,
        (cutoff_mac_ns, cutoff_mac_s),
    )
    rows = cur.fetchall()
    conn.close()

    if not rows:
        sys.exit("No sent messages found in the last %d days." % days)

    df = pd.DataFrame(rows, columns=["day", "sent"])
    df["day"] = pd.to_datetime(df["day"])

    # Fill missing days with 0 so the rolling average is honest.
    full_range = pd.date_range(
        end=pd.Timestamp.today().normalize(),
        periods=days,
        freq="D",
    )
    df = df.set_index("day").reindex(full_range, fill_value=0).rename_axis("day").reset_index()
    df["rolling_7d"] = df["sent"].rolling(window=7, min_periods=1).mean()
    return df


def plot(df: pd.DataFrame, out_path: str) -> None:
    fig, ax = plt.subplots(figsize=(13, 5.5))
    ax.plot(df["day"], df["sent"], color="#9ecae1", linewidth=1, label="Sent per day")
    ax.plot(df["day"], df["rolling_7d"], color="#08519c", linewidth=2.2, label="7-day rolling avg")

    ax.set_title(f"iMessages sent per day — last {len(df)} days")
    ax.set_ylabel("Messages sent")
    ax.set_xlabel("Date")
    ax.grid(True, alpha=0.25)
    ax.legend(loc="upper left")

    ax.xaxis.set_major_locator(mdates.MonthLocator())
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    fig.autofmt_xdate()

    total = int(df["sent"].sum())
    avg = df["sent"].mean()
    peak_day = df.loc[df["sent"].idxmax()]
    ax.text(
        0.99, 0.97,
        f"Total: {total:,}\nMean/day: {avg:.1f}\nPeak: {int(peak_day['sent'])} on {peak_day['day'].date()}",
        transform=ax.transAxes, ha="right", va="top",
        fontsize=9, family="monospace",
        bbox=dict(boxstyle="round,pad=0.4", facecolor="white", alpha=0.85, edgecolor="#cccccc"),
    )

    fig.tight_layout()
    fig.savefig(out_path, dpi=140)
    print(f"Saved chart: {out_path}")
    print(f"Total sent (365d): {total:,}")
    print(f"Daily mean: {avg:.1f}")
    print(f"Peak day: {peak_day['day'].date()} ({int(peak_day['sent'])} sent)")


def main() -> None:
    if not os.path.exists(DB):
        sys.exit(f"chat.db not found at {DB}")
    df = load_sent_per_day(DB, DAYS)
    plot(df, OUT_PNG)


if __name__ == "__main__":
    main()
