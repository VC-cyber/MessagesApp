//
//  DashboardLoader.swift
//  BetterMessages
//
//  Aggregates `chat.db` into a `DashboardStats` snapshot. Pushes everything
//  reasonable into SQL — we count rows in the database, not in Swift. For
//  ~100k-row databases that means sub-100ms instead of multi-second.
//
//  Patterns ported from `reference/scripts/`:
//    - `sent_messages_chart.py` for the per-day bucketing expression
//    - `top_contacts.py` for the contact merge + handle resolution shape
//    - `year_over_year.py` for the matched-window date math
//
//  Honors the canon (plans.md → "Critical Technical Knowledge — chat.db"):
//    - `m.date` is Mac absolute time, dual-format (ns post-10.13, s legacy).
//      We disambiguate with the `> 1e12` rule everywhere.
//    - `m.associated_message_type = 0` ALWAYS — drops tapbacks and reactions
//      from every count.
//    - For 1:1 contact stats we fall back to chat participants when
//      `m.handle_id` is NULL (sent messages), per the `COALESCE` trick in
//      `top_contacts.py`.
//    - `chat.style = 45` = 1:1, `= 43` = group.
//

import Foundation
import GRDB

public enum DashboardLoader {

    /// User-selectable rollup window. Drives both the time-series bucketing
    /// resolution and the contact/group rankings (those are scoped to the
    /// window too — "people I've texted the most lately").
    public enum Window: Sendable, Hashable, CaseIterable, Identifiable {
        case last30Days
        case last12Months
        case allTime

        public var id: Self { self }

        public var label: String {
            switch self {
            case .last30Days: return "30d"
            case .last12Months: return "12m"
            case .allTime: return "All"
            }
        }

        public var bucketing: Bucketing {
            switch self {
            case .last30Days: return .day
            case .last12Months: return .month
            case .allTime: return .month
            }
        }
    }

    /// How we group the time series.
    public enum Bucketing: Sendable, Hashable {
        case day
        case week
        case month

        /// The SQLite `strftime` format for this resolution. Always anchored
        /// to local time — Mac absolute time goes through `localtime` first.
        var strftimeFormat: String {
            switch self {
            case .day:   return "%Y-%m-%d"
            case .week:  return "%Y-%W"     // ISO week number
            case .month: return "%Y-%m"
            }
        }

        /// Parse a bucket label back to a `Date` (start of bucket, local TZ).
        func parseBucket(_ label: String, calendar: Calendar) -> Date? {
            let df = DateFormatter()
            df.calendar = calendar
            df.timeZone = calendar.timeZone
            df.locale = Locale(identifier: "en_US_POSIX")
            switch self {
            case .day:
                df.dateFormat = "yyyy-MM-dd"
                return df.date(from: label)
            case .month:
                df.dateFormat = "yyyy-MM"
                return df.date(from: label)
            case .week:
                // SQLite's %W is 00-53, week of year, Monday-start. Parse via
                // year + week-of-year components.
                let parts = label.split(separator: "-")
                guard parts.count == 2,
                      let year = Int(parts[0]),
                      let week = Int(parts[1]) else { return nil }
                var comps = DateComponents()
                comps.weekOfYear = max(week, 1)
                comps.yearForWeekOfYear = year
                comps.weekday = calendar.firstWeekday
                return calendar.date(from: comps)
            }
        }
    }

    /// Load every panel's data in one batch. The work runs on the GRDB read
    /// queue; the caller awaits a single `Sendable` value.
    public static func load(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        window: Window,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> DashboardStats {

        // GRDB's read queue isn't async-throws-friendly across actors, so we
        // hop to a detached task. The work itself is plain SQL.
        return try await Task.detached(priority: .userInitiated) {
            try loadSync(
                database: database,
                contacts: contacts,
                window: window,
                now: now,
                calendar: calendar
            )
        }.value
    }

    /// Synchronous variant — exposed for tests so they can run without a
    /// surrounding async context.
    public static func loadSync(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        window: Window,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DashboardStats {

        let dateRange = dateRange(for: window, now: now, calendar: calendar)

        return try database.dbQueue.read { db in
            let overview = try loadOverview(db: db)
            let timeSeries = try loadTimeSeries(
                db: db,
                bucketing: window.bucketing,
                dateRange: dateRange,
                calendar: calendar
            )
            let topContacts = try loadTopContacts(
                db: db,
                dateRange: dateRange,
                contacts: contacts
            )
            let topGroups = try loadTopGroups(
                db: db,
                dateRange: dateRange,
                contacts: contacts
            )
            return DashboardStats(
                overview: overview,
                timeSeries: timeSeries,
                topContacts: topContacts,
                topGroups: topGroups
            )
        }
    }

    // MARK: - Overview

    /// Header strip: total / sent / received / chats / span. All-time scope —
    /// these are the "ever" numbers and don't track the time selector.
    static func loadOverview(db: Database) throws -> DashboardStats.OverviewCounters {
        struct Row1: FetchableRecord {
            let total: Int
            let sent: Int
            let received: Int
            let minDate: Int64?
            let maxDate: Int64?
            init(row: Row) {
                total = row["total"] ?? 0
                sent = row["sent"] ?? 0
                received = row["received"] ?? 0
                minDate = row["min_date"]
                maxDate = row["max_date"]
            }
        }

        // One query for the four counters and the date span. The COALESCE on
        // is_from_me defends against pathological rows where the column is
        // NULL — treat as received.
        let counters = try Row1.fetchOne(db, sql: """
            SELECT
                COUNT(*)                                                        AS total,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END)               AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END)  AS received,
                MIN(m.date)                                                     AS min_date,
                MAX(m.date)                                                     AS max_date
            FROM message m
            WHERE m.associated_message_type = 0
            """)

        let chats = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM chat
            """) ?? 0

        let oldest = counters?.minDate.map(MessageDate.date(fromRaw:))
        let newest = counters?.maxDate.map(MessageDate.date(fromRaw:))

        return DashboardStats.OverviewCounters(
            total: counters?.total ?? 0,
            sent: counters?.sent ?? 0,
            received: counters?.received ?? 0,
            chats: chats,
            oldest: oldest,
            newest: newest
        )
    }

    // MARK: - Time series

    /// Per-bucket sent/received counts.
    ///
    /// We do all the bucketing in SQL via `strftime` on the Mac→Unix
    /// conversion. Two important details:
    ///
    /// 1. The disambiguation expression
    ///    `CASE WHEN m.date > 1e12 THEN m.date / 1e9 ELSE m.date END`
    ///    runs INSIDE `strftime`, so ns and seconds rows go through the same
    ///    formatter. (Same pattern as `sent_messages_chart.py`.)
    /// 2. We use `'localtime'` for the conversion — buckets line up with the
    ///    user's local clock, not UTC.
    static func loadTimeSeries(
        db: Database,
        bucketing: Bucketing,
        dateRange: ClosedRange<Date>?,
        calendar: Calendar
    ) throws -> [DashboardStats.TimeBucket] {

        let (dateSQL, dateArgs) = dateClause(dateRange)
        let format = bucketing.strftimeFormat

        let sql = """
            SELECT
                strftime(?, datetime(
                    CASE WHEN m.date > 1000000000000
                         THEN m.date / 1000000000
                         ELSE m.date
                    END + 978307200,
                    'unixepoch', 'localtime'
                )) AS bucket,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
            FROM message m
            WHERE m.associated_message_type = 0
              \(dateSQL)
            GROUP BY bucket
            HAVING bucket IS NOT NULL
            ORDER BY bucket ASC
            """

        var args: [DatabaseValueConvertible] = [format]
        args.append(contentsOf: dateArgs)

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        var buckets: [DashboardStats.TimeBucket] = []
        buckets.reserveCapacity(rows.count)
        for row in rows {
            let bucket: String? = row["bucket"]
            let sent: Int = row["sent"] ?? 0
            let received: Int = row["received"] ?? 0
            guard let bucket,
                  let date = bucketing.parseBucket(bucket, calendar: calendar) else {
                continue
            }
            buckets.append(DashboardStats.TimeBucket(
                date: date,
                sent: sent,
                received: received
            ))
        }
        return buckets
    }

    // MARK: - Top contacts

    /// "People you text the most" — 1:1 chats only, sent + received pooled.
    /// Merges multiple handles per contact via the resolved name (same idea
    /// as `top_contacts.py`).
    static func loadTopContacts(
        db: Database,
        dateRange: ClosedRange<Date>?,
        contacts: ResolvedContacts,
        limit: Int = 12
    ) throws -> [DashboardStats.ContactStat] {

        let (dateSQL, dateArgs) = dateClause(dateRange)

        // SQL straight from top_contacts.py:
        //   join via chat_message_join → chat, restrict to style=45 (1:1),
        //   and COALESCE the sender handle to the chat's other participant
        //   for sent rows (which have NULL m.handle_id).
        let sql = """
            SELECT
                h.id AS handle,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received,
                COUNT(*) AS total
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            JOIN handle h ON h.ROWID = COALESCE(
                m.handle_id,
                (SELECT chj.handle_id FROM chat_handle_join chj
                 WHERE chj.chat_id = ch.ROWID LIMIT 1)
            )
            WHERE m.associated_message_type = 0
              AND ch.style = 45
              \(dateSQL)
            GROUP BY h.id
            """

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(dateArgs))

        // Merge handles that resolve to the same display name (one person,
        // many handles). For unknown handles we still aggregate per handle.
        struct Bucket {
            var name: String
            var sent: Int = 0
            var received: Int = 0
            var total: Int = 0
        }
        var merged: [String: Bucket] = [:]

        for row in rows {
            guard let raw: String = row["handle"] else { continue }
            let sent: Int = row["sent"] ?? 0
            let received: Int = row["received"] ?? 0
            let total: Int = row["total"] ?? 0

            let handle = Handle(raw: raw)
            let resolvedName = contacts.byHandle[handle]?.displayName
            let key: String
            let displayName: String
            if let resolvedName, !resolvedName.isEmpty {
                key = "name:\(resolvedName)"
                displayName = resolvedName
            } else {
                key = "handle:\(handle.normalized)"
                displayName = raw
            }

            var bucket = merged[key] ?? Bucket(name: displayName)
            bucket.sent += sent
            bucket.received += received
            bucket.total += total
            merged[key] = bucket
        }

        let ranked = merged
            .map { (key, b) in
                DashboardStats.ContactStat(
                    key: key,
                    displayName: b.name,
                    sent: b.sent,
                    received: b.received,
                    total: b.total
                )
            }
            .sorted { lhs, rhs in
                if lhs.total != rhs.total { return lhs.total > rhs.total }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .prefix(limit)

        return Array(ranked)
    }

    // MARK: - Top groups

    /// "Group chats you text the most" — ranked by your-sent count in the
    /// window. Limited to `chat.style = 43`.
    static func loadTopGroups(
        db: Database,
        dateRange: ClosedRange<Date>?,
        contacts: ResolvedContacts,
        limit: Int = 12
    ) throws -> [DashboardStats.GroupStat] {

        let (dateSQL, dateArgs) = dateClause(dateRange)

        // We aggregate count metrics per chat. The chat label (members for
        // unnamed groups) needs a second join, so we keep this query lean
        // and resolve labels in Swift.
        let sql = """
            SELECT
                ch.ROWID AS chat_rowid,
                ch.display_name AS display_name,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                COUNT(*) AS total
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            WHERE m.associated_message_type = 0
              AND ch.style = 43
              \(dateSQL)
            GROUP BY ch.ROWID, ch.display_name
            HAVING sent > 0
            ORDER BY sent DESC, total DESC
            LIMIT ?
            """

        var args: [DatabaseValueConvertible] = dateArgs
        args.append(limit)

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        // Resolve labels for groups without a display name. We need the
        // participant handle set — fetch in one shot for all candidate chats.
        let candidateRowIDs = rows.compactMap { $0["chat_rowid"] as Int64? }
        let participantNames = try loadGroupParticipantNames(
            db: db,
            chatRowIDs: candidateRowIDs,
            contacts: contacts
        )

        var stats: [DashboardStats.GroupStat] = []
        stats.reserveCapacity(rows.count)
        for row in rows {
            guard let rowID: Int64 = row["chat_rowid"] else { continue }
            let displayName: String? = row["display_name"]
            let sent: Int = row["sent"] ?? 0
            let total: Int = row["total"] ?? 0

            let label: String
            if let dn = displayName, !dn.trimmingCharacters(in: .whitespaces).isEmpty {
                label = dn
            } else {
                let names = participantNames[rowID] ?? []
                if names.isEmpty {
                    label = "Group chat"
                } else if names.count <= 3 {
                    label = "Group chat with " + names.joined(separator: ", ")
                } else {
                    let preview = names.prefix(2).joined(separator: ", ")
                    label = "Group chat with \(preview) +\(names.count - 2)"
                }
            }

            stats.append(DashboardStats.GroupStat(
                chatRowID: rowID,
                displayName: label,
                sentByYou: sent,
                total: total
            ))
        }
        return stats
    }

    /// One round-trip to fetch participant handles for a known set of chats,
    /// resolved to display names in Swift.
    private static func loadGroupParticipantNames(
        db: Database,
        chatRowIDs: [Int64],
        contacts: ResolvedContacts
    ) throws -> [Int64: [String]] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: chatRowIDs.count).joined(separator: ", ")
        let sql = """
            SELECT chj.chat_id AS chat_id, h.id AS handle_id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id IN (\(placeholders))
            """
        var args: [DatabaseValueConvertible] = []
        for rowID in chatRowIDs { args.append(rowID) }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        var byChat: [Int64: [String]] = [:]
        for row in rows {
            guard let chatID: Int64 = row["chat_id"],
                  let rawHandle: String = row["handle_id"] else { continue }
            let name = contacts.byHandle[Handle(raw: rawHandle)]?.displayName ?? rawHandle
            byChat[chatID, default: []].append(name)
        }
        return byChat
    }

    // MARK: - Date helpers

    /// Window → date range. `nil` means no constraint (all-time).
    static func dateRange(
        for window: Window,
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date>? {
        switch window {
        case .allTime:
            return nil
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return start...now
        case .last12Months:
            let start = calendar.date(byAdding: .month, value: -12, to: now) ?? now
            return start...now
        }
    }

    /// Build the `m.date` predicate that handles BOTH ns and seconds rows.
    /// Mirrors `MessageSearch.dateClause` exactly — kept local so the
    /// dashboard layer is independent.
    static func dateClause(_ range: ClosedRange<Date>?) -> (String, [DatabaseValueConvertible]) {
        guard let range else { return ("", []) }
        let loNS = MessageDate.nanosecondsSinceMacEpoch(from: range.lowerBound)
        let hiNS = MessageDate.nanosecondsSinceMacEpoch(from: range.upperBound)
        let loS = MessageDate.secondsSinceMacEpoch(from: range.lowerBound)
        let hiS = MessageDate.secondsSinceMacEpoch(from: range.upperBound)
        let sql = """
            AND (
                  (m.date > 1000000000000 AND m.date BETWEEN ? AND ?)
               OR (m.date <= 1000000000000 AND m.date BETWEEN ? AND ?)
            )
            """
        return (sql, [loNS, hiNS, loS, hiS])
    }
}
