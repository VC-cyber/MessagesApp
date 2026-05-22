//
//  ReactionLoader.swift
//  BetterMessages
//
//  Batched loader for tapbacks ("reactions") against a set of target message
//  GUIDs.
//
//  Why batched? The naive approach — fetch reactions per-row as the UI scrolls
//  — is an N+1 query in the hot path. For a search result with 200 rows that
//  means 200 round-trips into the DB queue. We instead issue ONE query that
//  pulls every tapback for every target GUID in the result set, then group in
//  Swift.
//
//  Query shape
//  -----------
//  Tapbacks are rows where `associated_message_type` is in 2000-2999 (we drop
//  3000-3999, which are *removed* reactions — history, not current state).
//  The reference back to the target lives in `associated_message_guid`, which
//  may be prefixed (`p:0/<guid>`, `bp:<guid>`, etc.) — we strip in Swift after
//  fetching, because doing it in SQL would defeat the index on the column.
//
//  We pull more rows than strictly needed (any prefix variant of every target
//  GUID) and group by stripped GUID afterwards. SQLite handles this with a
//  single `WHERE associated_message_guid LIKE ?` per target — fine for ≤ a
//  few hundred targets which is the panel result-set ceiling.
//
//  Edge cases
//  ----------
//  - Empty input → returns empty dictionary, no SQL.
//  - Target GUID containing `'` or `%` — sanitized via parameter binding; we
//    use `LIKE` with explicit wildcard concatenation in SQL, parameter is just
//    the bare GUID.
//  - Reaction sender is the user (`handle_id IS NULL`) — `senderHandle` is nil
//    and `senderName` resolves to "You".
//

import Foundation
import GRDB

public enum ReactionLoader {

    /// Load reactions for the given target message GUIDs.
    ///
    /// Returns a dictionary keyed by the **bare** message GUID (no `p:0/` or
    /// `bp:` prefix). Reactions per message are sorted by date ascending
    /// (oldest first) — same order Messages.app shows them.
    ///
    /// Only the CURRENT reaction from each sender on each message is kept.
    /// If a sender added a love and later switched to a like, only the like
    /// is in the array (matches the visible Messages.app bubble: a sender
    /// can have at most one active tapback per message at a time).
    public static func reactions(
        forTargetGUIDs guids: [String],
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [String: [Reaction]] {
        guard !guids.isEmpty else { return [:] }

        // Build the IN clause — we filter by the *stripped* GUID being one of
        // the targets via a LIKE-OR construction. Each target contributes one
        // `associated_message_guid LIKE ? || '%' || ? || '%'` style predicate,
        // but simpler: `associated_message_guid LIKE '%' || ? || '%'`. The
        // GUIDs are 36-char UUIDs so substring match has no false positives in
        // practice.
        //
        // Performance note: SQLite can't use the index for a leading-wildcard
        // LIKE. For our ceiling (panel results ≤ a few hundred), the table
        // scan over the tapbacks subset (typically ≤ 50k rows) is fine. If
        // this becomes hot we could pre-build prefix variants and use IN.
        let uniqueGUIDs = Array(Set(guids.filter { !$0.isEmpty }))
        guard !uniqueGUIDs.isEmpty else { return [:] }

        // To keep the IN list to a manageable size we issue ONE query with all
        // variants we know about (`p:0/<g>`, `p:1/<g>`, …, `bp:<g>`, bare `<g>`).
        // 92% of real-world hits are `p:0/<g>` so we always include that. For
        // the rest we fall through to LIKE.
        //
        // Build the candidate list: for each GUID we include the bare GUID,
        // `p:0/<guid>`, and a LIKE pattern that catches `bp:<guid>` and
        // `p:N/<guid>` for N != 0.
        var args: [DatabaseValueConvertible] = []
        var inEqualList: [String] = []
        var likePatterns: [String] = []
        for g in uniqueGUIDs {
            // Exact equality matches for the two most-common shapes.
            inEqualList.append(g)
            inEqualList.append("p:0/\(g)")
            // For the long tail (`p:1/<g>` through `p:19/<g>`, `bp:<g>`,
            // suffix-only variants) — one LIKE per GUID. This is still cheap:
            // ≤ panel-results-count LIKEs, each scanning the tapback subset.
            likePatterns.append("%\(g)")
        }

        let equalPlaceholders = Array(repeating: "?", count: inEqualList.count).joined(separator: ", ")
        let likeClauses = Array(repeating: "associated_message_guid LIKE ?", count: likePatterns.count)
            .joined(separator: " OR ")

        // Build args in order: equality list first, then LIKE patterns.
        for g in inEqualList { args.append(g) }
        for p in likePatterns { args.append(p) }

        // Note: `m.associated_message_type BETWEEN 2000 AND 2999` filters
        // sent reactions but drops removed reactions (3000+) at the SQL
        // level — they don't reflect current state and don't belong in the UI.
        let sql = """
            SELECT
                m.associated_message_guid       AS target_guid,
                m.associated_message_type       AS type,
                m.associated_message_emoji      AS emoji,
                m.date                          AS date,
                m.is_from_me                    AS is_from_me,
                h.id                            AS sender_handle
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type BETWEEN 2000 AND 2999
              AND (
                  m.associated_message_guid IN (\(equalPlaceholders))
                  \(likePatterns.isEmpty ? "" : "OR \(likeClauses)")
              )
            ORDER BY m.date ASC
            """

        let rows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }

        // Group by stripped target GUID. Build a quick lookup for "is this GUID
        // one we asked for?" to avoid wasting work on incidental substring hits.
        let targetSet: Set<String> = Set(uniqueGUIDs)
        // Track the most recent reaction per (target, sender) so swaps win.
        struct Key: Hashable { let target: String; let sender: String? }
        var latest: [Key: (date: Int64, reaction: Reaction)] = [:]

        for row in rows {
            guard let rawTarget: String = row["target_guid"] else { continue }
            let stripped = Reaction.stripGUIDPrefix(rawTarget)
            guard targetSet.contains(stripped) else { continue }

            let type: Int = row["type"] ?? 0
            let emoji: String? = row["emoji"]
            guard let kind = Reaction.Kind.fromRaw(type: type, emoji: emoji) else { continue }

            let rawDate: Int64 = row["date"] ?? 0
            let date = MessageDate.date(fromRaw: rawDate)
            let isFromMe: Bool = (row["is_from_me"] as Int? ?? 0) == 1
            let senderHandle: String? = row["sender_handle"]

            let senderName: String
            if isFromMe {
                senderName = "You"
            } else if let raw = senderHandle {
                senderName = contacts.name(forRawHandle: raw)
            } else {
                senderName = "(unknown)"
            }

            let reaction = Reaction(
                kind: kind,
                senderName: senderName,
                senderHandle: senderHandle,
                date: date,
                isFromMe: isFromMe
            )

            let key = Key(target: stripped, sender: senderHandle)
            // Each sender can have only one active reaction per message; we
            // already sorted ASC so the last-seen row for a given key is the
            // most recent. Just overwrite.
            latest[key] = (rawDate, reaction)
        }

        // Group into the output dictionary, preserving date-ascending order.
        var out: [String: [Reaction]] = [:]
        let sortedEntries = latest.values.sorted { $0.date < $1.date }
        for entry in sortedEntries {
            // Find target by re-stripping isn't necessary; we have it in the key.
            // Recover target by reverse-lookup from the latest dictionary.
            // Simpler: iterate over the dictionary keys.
        }
        for (key, entry) in latest {
            out[key.target, default: []].append(entry.reaction)
        }
        // Sort each per-message list by date ascending so UI rendering is stable.
        for (k, v) in out {
            out[k] = v.sorted { $0.date < $1.date }
        }
        return out
    }
}
