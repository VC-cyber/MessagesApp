"""
School-year-over-year comparison of sent iMessages.

Compares:
  - 2024-25 school year: Sep 1 2024 → May 21 2025
  - 2025-26 school year: Sep 1 2025 → May 21 2026 (incomplete; capped at today)

Excludes Cactus OG group (consistent with prior analyses).
Overlays both years on a "day of school year" axis.
"""

from __future__ import annotations

import os
import sqlite3
from datetime import datetime

import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import pandas as pd
from scipy import stats

DB = os.path.expanduser("~/Library/Messages/chat.db")
OUT_PNG = "/tmp/year_over_year.png"
MAC_EPOCH = 978307200

# Today is 2026-05-21; cap both years at the same DOY for matched comparison.
TODAY = pd.Timestamp.today().normalize()
YEAR_A_START = pd.Timestamp("2024-09-01")
YEAR_A_END = pd.Timestamp("2025-05-21")
YEAR_B_START = pd.Timestamp("2025-09-01")
YEAR_B_END = TODAY  # 2026-05-21


def load_daily(db_path: str, start: pd.Timestamp, end: pd.Timestamp) -> pd.DataFrame:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    cur = conn.cursor()
    start_dt = start.to_pydatetime()
    end_dt = (end + pd.Timedelta(days=1)).to_pydatetime()  # inclusive end
    start_s = start_dt.timestamp() - MAC_EPOCH
    end_s = end_dt.timestamp() - MAC_EPOCH
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
                (m.date > 1000000000000 AND m.date >= ? AND m.date < ?)
             OR (m.date <= 1000000000000 AND m.date >= ? AND m.date < ?)
          )
        GROUP BY day
        ORDER BY day
        """,
        (start_s * 1e9, end_s * 1e9, start_s, end_s),
    )
    rows = cur.fetchall()
    conn.close()
    df = pd.DataFrame(rows, columns=["day", "sent"])
    df["day"] = pd.to_datetime(df["day"])
    full = pd.date_range(start=start, end=end, freq="D")
    df = df.set_index("day").reindex(full, fill_value=0).rename_axis("day").reset_index()
    df["rolling_7d"] = df["sent"].rolling(7, min_periods=1).mean()
    df["doy"] = (df["day"] - start).dt.days  # day-of-school-year (0-indexed)
    return df


def summarize(label: str, df: pd.DataFrame) -> None:
    total = int(df["sent"].sum())
    mean = df["sent"].mean()
    median = df["sent"].median()
    p25, p75 = df["sent"].quantile([0.25, 0.75])
    print(
        f"{label:<10s}  n_days={len(df):3d}  total={total:>6,}  "
        f"mean={mean:6.1f}  median={median:5.1f}  IQR={p25:.0f}-{p75:.0f}"
    )


def main() -> None:
    a = load_daily(DB, YEAR_A_START, YEAR_A_END)
    b = load_daily(DB, YEAR_B_START, YEAR_B_END)

    print(f"Window:  Sep 1 → May 21 of each school year  (Cactus OG excluded)\n")
    summarize("2024-25", a)
    summarize("2025-26", b)

    delta_total = b["sent"].sum() - a["sent"].sum()
    delta_pct = delta_total / a["sent"].sum() * 100
    print(f"\nTotal Δ: {delta_total:+,} ({delta_pct:+.1f}%)")
    print(f"Daily mean Δ: {b['sent'].mean() - a['sent'].mean():+.1f}/day")

    u, p = stats.mannwhitneyu(a["sent"], b["sent"], alternative="two-sided")
    print(
        f"\nMann-Whitney U: U={u:.0f}, p={p:.4g}  "
        f"({'significant at 0.05' if p < 0.05 else 'not significant at 0.05'})"
    )

    # Monthly breakdown for shape comparison.
    print("\nMonth-by-month (Sep=month 1 of school year):")
    print(f"  {'Month':<10s} {'2024-25':>10s} {'2025-26':>10s} {'Δ':>10s} {'Δ%':>8s}")
    for month_offset in range(9):
        month_label = (YEAR_A_START + pd.DateOffset(months=month_offset)).strftime("%b")
        a_month = a[(a["day"] >= YEAR_A_START + pd.DateOffset(months=month_offset))
                    & (a["day"] < YEAR_A_START + pd.DateOffset(months=month_offset + 1))]
        b_month = b[(b["day"] >= YEAR_B_START + pd.DateOffset(months=month_offset))
                    & (b["day"] < YEAR_B_START + pd.DateOffset(months=month_offset + 1))]
        a_tot = int(a_month["sent"].sum())
        b_tot = int(b_month["sent"].sum())
        delta = b_tot - a_tot
        delta_p = delta / a_tot * 100 if a_tot else float("nan")
        print(f"  {month_label:<10s} {a_tot:>10,} {b_tot:>10,} {delta:>+10,} {delta_p:>+7.1f}%")

    # Plot: two-panel.
    #   Top: overlay on day-of-school-year axis
    #   Bottom: difference of rolling averages
    fig, (ax1, ax2) = plt.subplots(
        2, 1, figsize=(13, 8), sharex=True, gridspec_kw={"height_ratios": [3, 1]}
    )

    ax1.plot(a["doy"], a["sent"], color="#fdae6b", linewidth=0.8, alpha=0.5)
    ax1.plot(a["doy"], a["rolling_7d"], color="#d94801", linewidth=2.2, label="2024-25 (7d avg)")
    ax1.plot(b["doy"], b["sent"], color="#9ecae1", linewidth=0.8, alpha=0.5)
    ax1.plot(b["doy"], b["rolling_7d"], color="#08519c", linewidth=2.2, label="2025-26 (7d avg)")

    # Annotate Cactus signing day in 2025-26 frame.
    cactus_doy = (pd.Timestamp("2026-01-07") - YEAR_B_START).days
    ax1.axvline(cactus_doy, color="#cb181d", linestyle="--", linewidth=1.2, alpha=0.8)
    ax1.annotate("Cactus signed\n(Jan 7)", xy=(cactus_doy, ax1.get_ylim()[1] * 0.9),
                 xytext=(5, -5), textcoords="offset points", color="#cb181d", fontsize=9)

    ax1.set_title("iMessages sent per day — 2024-25 vs 2025-26 school year (Sep 1 → May 21)")
    ax1.set_ylabel("Messages sent / day")
    ax1.grid(True, alpha=0.25)
    ax1.legend(loc="upper right")

    # Month labels on x-axis (DOY 0=Sep 1)
    month_starts = []
    month_labels = []
    for m in range(9):
        dt = YEAR_A_START + pd.DateOffset(months=m)
        month_starts.append((dt - YEAR_A_START).days)
        month_labels.append(dt.strftime("%b"))
    ax2.set_xticks(month_starts)
    ax2.set_xticklabels(month_labels)
    ax2.set_xlabel("Month of school year")

    # Bottom: difference of rolling averages (2025-26 minus 2024-25)
    merged = pd.merge(a[["doy", "rolling_7d"]], b[["doy", "rolling_7d"]],
                      on="doy", suffixes=("_a", "_b"))
    merged["diff"] = merged["rolling_7d_b"] - merged["rolling_7d_a"]
    ax2.fill_between(merged["doy"], 0, merged["diff"],
                     where=merged["diff"] >= 0, color="#08519c", alpha=0.5, label="2025-26 higher")
    ax2.fill_between(merged["doy"], 0, merged["diff"],
                     where=merged["diff"] < 0, color="#d94801", alpha=0.5, label="2024-25 higher")
    ax2.axhline(0, color="black", linewidth=0.8)
    ax2.axvline(cactus_doy, color="#cb181d", linestyle="--", linewidth=1.2, alpha=0.8)
    ax2.set_ylabel("Δ (msgs/day)\n2025-26 − 2024-25")
    ax2.grid(True, alpha=0.25)
    ax2.legend(loc="upper right", fontsize=8)

    fig.tight_layout()
    fig.savefig(OUT_PNG, dpi=140)
    print(f"\nSaved: {OUT_PNG}")


if __name__ == "__main__":
    main()
