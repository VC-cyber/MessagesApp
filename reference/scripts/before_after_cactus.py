"""
Did sent-per-day drop after Jan 7, 2026 (Cactus signing day)?

- Pulls sent messages from chat.db (all chats, no reactions).
- Compares means over 30/60/90/all-days windows on either side of Jan 7.
- Runs a Mann-Whitney U test for the 90-day windows (non-parametric, no normality assumption).
- Plots daily + 7-day rolling avg with a vertical line at Jan 7.
"""

from __future__ import annotations

import os
import sqlite3
from datetime import datetime, timedelta

import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import pandas as pd
from scipy import stats

DB = os.path.expanduser("~/Library/Messages/chat.db")
SIGN_DATE = pd.Timestamp("2026-01-07")
OUT_PNG = "/tmp/before_after_cactus_no_og.png"
MAC_EPOCH = 978307200


def load_daily(db_path: str) -> pd.DataFrame:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    cur = conn.cursor()
    # Pull from 2025-01-01 so we have plenty of "before" context.
    cutoff = datetime(2025, 1, 1)
    cutoff_mac_s = cutoff.timestamp() - MAC_EPOCH
    cutoff_mac_ns = cutoff_mac_s * 1e9
    # Exclude messages that belong to the "Cactus OG" group chat. Use NOT IN
    # rather than JOIN+filter so any oddities in chat_message_join (duplicate
    # rows, etc.) don't inflate the count.
    cur.execute(
        """
        SELECT
            date(
                datetime(
                    CASE WHEN m.date > 1000000000000 THEN m.date / 1000000000 ELSE m.date END
                    + 978307200,
                    'unixepoch', 'localtime'
                )
            ) AS day,
            COUNT(*) AS sent
        FROM message m
        WHERE m.is_from_me = 1
          AND m.associated_message_type = 0
          AND m.ROWID NOT IN (
              SELECT cmj.message_id FROM chat_message_join cmj
              JOIN chat ch ON ch.ROWID = cmj.chat_id
              WHERE ch.display_name = 'Cactus OG'
          )
          AND (
                (m.date > 1000000000000 AND m.date > ?)
             OR (m.date <= 1000000000000 AND m.date > ?)
          )
        GROUP BY day
        ORDER BY day
        """,
        (cutoff_mac_ns, cutoff_mac_s),
    )
    rows = cur.fetchall()
    conn.close()
    df = pd.DataFrame(rows, columns=["day", "sent"])
    df["day"] = pd.to_datetime(df["day"])
    # Fill missing days with 0.
    end = pd.Timestamp.today().normalize()
    full = pd.date_range(start=cutoff, end=end, freq="D")
    df = df.set_index("day").reindex(full, fill_value=0).rename_axis("day").reset_index()
    df["rolling_7d"] = df["sent"].rolling(7, min_periods=1).mean()
    return df


def window_compare(df: pd.DataFrame, sign: pd.Timestamp, days: int) -> dict:
    before = df[(df["day"] >= sign - pd.Timedelta(days=days)) & (df["day"] < sign)]["sent"]
    after = df[(df["day"] >= sign) & (df["day"] < sign + pd.Timedelta(days=days))]["sent"]
    return {
        "days": days,
        "before_n": len(before),
        "after_n": len(after),
        "before_mean": before.mean(),
        "after_mean": after.mean(),
        "before_median": before.median(),
        "after_median": after.median(),
        "delta_pct": (after.mean() - before.mean()) / before.mean() * 100,
        "before_arr": before.values,
        "after_arr": after.values,
    }


def main() -> None:
    df = load_daily(DB)

    today = pd.Timestamp.today().normalize()
    days_after = (today - SIGN_DATE).days

    print(f"Sign date: {SIGN_DATE.date()}  |  Today: {today.date()}  |  Days after: {days_after}\n")

    rows = []
    for w in (14, 30, 60, 90, days_after):
        r = window_compare(df, SIGN_DATE, w)
        rows.append(r)
        arrow = "↓" if r["after_mean"] < r["before_mean"] else "↑"
        print(
            f"±{w:>3}d   before mean={r['before_mean']:6.1f}   "
            f"after mean={r['after_mean']:6.1f}   {arrow} {r['delta_pct']:+6.1f}%   "
            f"(before n={r['before_n']}, after n={r['after_n']})"
        )

    # Stats test on the largest matched window (90d before vs 90d after).
    r90 = next(r for r in rows if r["days"] == 90)
    u, p = stats.mannwhitneyu(r90["before_arr"], r90["after_arr"], alternative="two-sided")
    print(
        f"\nMann-Whitney U (90d windows): U={u:.0f}, p={p:.4g}  "
        f"({'significant at 0.05' if p < 0.05 else 'not significant at 0.05'})"
    )

    # Plot
    fig, ax = plt.subplots(figsize=(13, 5.5))
    ax.plot(df["day"], df["sent"], color="#9ecae1", linewidth=1, label="Sent per day")
    ax.plot(df["day"], df["rolling_7d"], color="#08519c", linewidth=2.2, label="7-day rolling avg")
    ax.axvline(SIGN_DATE, color="#cb181d", linestyle="--", linewidth=1.5, alpha=0.9,
               label="Cactus signed (Jan 7)")

    # Shade before/after means on top of the plot for the matched ±90d window
    pre_start = SIGN_DATE - pd.Timedelta(days=90)
    post_end = SIGN_DATE + pd.Timedelta(days=min(90, days_after))
    ax.hlines(r90["before_mean"], pre_start, SIGN_DATE,
              colors="#08519c", linestyles=":", linewidth=2)
    ax.hlines(r90["after_mean"], SIGN_DATE, post_end,
              colors="#cb181d", linestyles=":", linewidth=2)
    ax.annotate(f"mean {r90['before_mean']:.0f}/day",
                xy=(pre_start + (SIGN_DATE - pre_start) / 2, r90["before_mean"]),
                xytext=(0, 8), textcoords="offset points", ha="center",
                fontsize=9, color="#08519c", fontweight="bold")
    ax.annotate(f"mean {r90['after_mean']:.0f}/day",
                xy=(SIGN_DATE + (post_end - SIGN_DATE) / 2, r90["after_mean"]),
                xytext=(0, 8), textcoords="offset points", ha="center",
                fontsize=9, color="#cb181d", fontweight="bold")

    ax.set_title(f"iMessages sent per day — Cactus OG group excluded (before vs after Jan 7, 2026)")
    ax.set_ylabel("Messages sent")
    ax.set_xlabel("Date")
    ax.grid(True, alpha=0.25)
    ax.legend(loc="upper left")
    ax.xaxis.set_major_locator(mdates.MonthLocator())
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    fig.autofmt_xdate()

    fig.tight_layout()
    fig.savefig(OUT_PNG, dpi=140)
    print(f"\nSaved: {OUT_PNG}")


if __name__ == "__main__":
    main()
