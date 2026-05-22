//
//  MessageSearch.swift
//  BetterMessages
//
//  Phase 1 phrase search across the user's chat.db.
//
//  Query model
//  -----------
//  - `phrase`: case-insensitive substring(s). If it contains `+`, we split on
//    `+` and require ALL parts to appear in the message body (co-occurrence).
//    Empty parts are ignored, so "foo+" == "foo".
//  - `person`: optional Contact filter — restrict to messages whose
//    participant (sender for received, chat-partner for sent in 1:1) maps to
//    this contact's handle set.
//  - `dateRange`: optional ClosedRange<Date>. Pushed down into SQL.
//
//  Pipeline (matches `reference/scripts/search_messages.py`):
//    1. Pull candidate rows by date range AND a coarse phrase pre-filter from
//       SQL (fast — `date` is indexed, LIKE on `attributedBody` byte-scans but
//       it's much smaller than fetching every row).
//       Filter `associated_message_type = 0` to drop tapbacks here.
//    2. Decode body in-process (text || attributedBody) using the
//       metadata-aware AttributedBodyDecoder.
//    3. Substring match (case-insensitive) on the *decoded* body — refines the
//       SQL coarse match and rejects metadata-only false positives.
//    4. Person filter applied last (we have to know the sender to filter).
//
//  Returns messages sorted **descending** by date (newest first). This matches
//  Spotlight-style "show me recent matches first" expectations, and means the
//  LIMIT clause keeps the most recent candidates, not the oldest.
//

import Foundation
import GRDB

public struct MessageSearch: Sendable {

    public struct Result: Sendable {
        public let message: Message
        /// Resolved display name of the OTHER party in the chat (the partner,
        /// not the user). Filled in when we can determine it from chat_handle_join.
        public let partnerName: String
        /// Resolved sender display name ("You" or contact name or raw handle).
        public let senderName: String
        /// `chat.guid` — the canonical chat identifier (e.g.
        /// `"iMessage;-;+15551234567"` for a 1:1 or `"iMessage;+;chat0123..."`
        /// for a group). Surfaced so the reveal layer can use it for
        /// AppleScript-based jump-to-chat lookups; `nil` if the row didn't
        /// carry one (very old DBs).
        public let chatGUID: String?
        /// Reactions on this message, oldest first. Populated by
        /// `MessageSearch.search` via a single batched `ReactionLoader` call
        /// after the main result query — never N+1.
        public let reactions: [Reaction]

        public init(
            message: Message,
            partnerName: String,
            senderName: String,
            chatGUID: String? = nil,
            reactions: [Reaction] = []
        ) {
            self.message = message
            self.partnerName = partnerName
            self.senderName = senderName
            self.chatGUID = chatGUID
            self.reactions = reactions
        }
    }

    public let database: ChatDatabase
    public let contacts: ResolvedContacts

    public init(database: ChatDatabase, contacts: ResolvedContacts) {
        self.database = database
        self.contacts = contacts
    }

    /// Run a search. Returns matches sorted by date **descending** (newest first).
    ///
    /// `limit` is `nil` by default — **search is exhaustive**: every message
    /// matching the filters is returned. Pass an explicit limit only when you
    /// know you want to cap (e.g. a thumbnail preview that needs the top 20).
    /// Latency protection for typing-on-every-keystroke is the *caller's*
    /// responsibility (debounce + cancellation in `SearchViewModel`).
    ///
    /// **Query syntax** in `phrase`:
    /// - Plain phrase: substring match (case-insensitive, lossy across `text`
    ///   and `attributedBody`).
    /// - `a+b`: co-occurrence — both substrings must appear.
    /// - `chat:name` / `in:name`: scope to chats whose `display_name` contains
    ///   `name` (case-insensitive substring). Combine freely.
    ///   Multiple `chat:` tokens are AND'd. Multi-word values via quotes:
    ///   `chat:"Amme Satyajit"`.
    /// - `from:person`: messages SENT BY person (matches contact display name
    ///   or raw handle). Multiple `from:` AND together.
    /// - `to:person`: messages SENT TO person — `is_from_me = 1` AND chat
    ///   participants include `person`. Multiple `to:` AND together.
    /// - `before:date` / `after:date` / `on:date`: explicit date operators.
    ///   `on:` is shorthand for "between start and end of that day".
    /// - `last:7d` / `last:24h` / `last:2w` / `last:3mo` / `last:1y`: relative
    ///   delta from now. `last:N` (bare) means N days.
    /// - Natural date strings as operator values: `before:yesterday`,
    ///   `after:"may 8 2026"`. Or as standalone tokens for callers using
    ///   `dateRange` directly. ISO `YYYY-MM-DD` and `MM/DD/YYYY` accepted.
    ///
    /// All filters AND together. Caller-supplied `person` / `dateRange` AND
    /// with anything parsed from the phrase.
    public func search(
        phrase: String,
        person: Contact? = nil,
        dateRange: ClosedRange<Date>? = nil,
        limit: Int? = nil,
        now: Date = Date()
    ) throws -> [Result] {

        let parsed = Self.parseQuery(phrase, contacts: contacts, now: now)
        let needles = Self.parseNeedles(parsed.freeText)
        // If phrase is non-empty but parses to no needles (e.g. just "+"),
        // treat as no-text-filter so person/date/chat filters still work.

        // Combine caller-supplied date range with any parsed date range. Both
        // narrow the search; intersection (AND) is the semantically correct
        // composition. If they don't overlap, the result is empty.
        let combinedRange = Self.intersect(dateRange, parsed.dateRange)

        let (dateSQL, dateArgs) = Self.dateClause(combinedRange)
        let (phraseSQL, phraseArgs) = Self.phraseClause(needles)
        let (chatSQL, chatArgs) = Self.chatClause(parsed.chatFilters)
        let (fromSQL, fromArgs) = Self.fromClause(parsed.fromFilters, contacts: contacts)
        let (toSQL, toArgs) = Self.toClause(parsed.toFilters, contacts: contacts)
        let (reactionsSQL, reactionsArgs) = Self.reactionsClause(parsed.reactionFilters)
        let limitSQL = limit.map { _ in "LIMIT ?" } ?? ""
        let sql = """
            SELECT
                m.ROWID                    AS rowid,
                m.guid                     AS guid,
                m.date                     AS date,
                m.is_from_me               AS is_from_me,
                m.text                     AS text,
                m.attributedBody           AS attributedBody,
                m.associated_message_type  AS associated_message_type,
                h.id                       AS sender_handle,
                cmj.chat_id                AS chat_id,
                ch.style                   AS chat_style,
                ch.display_name            AS chat_display_name,
                ch.guid                    AS chat_guid
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type = 0
              \(dateSQL)
              \(phraseSQL)
              \(chatSQL)
              \(fromSQL)
              \(toSQL)
              \(reactionsSQL)
            ORDER BY m.date DESC
            \(limitSQL)
            """

        var args: [DatabaseValueConvertible] = dateArgs
        args.append(contentsOf: phraseArgs)
        args.append(contentsOf: chatArgs)
        args.append(contentsOf: fromArgs)
        args.append(contentsOf: toArgs)
        args.append(contentsOf: reactionsArgs)
        if let limit { args.append(limit) }

        let rows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }

        // Cache: chat_id -> partner display name (for 1:1 we look up the
        // other participant; for groups we use the chat display_name).
        var partnerNameCache: [Int64: String] = [:]
        // Cache: chat_id -> [normalized handles] (for person filtering on
        // sent messages — we need to know who you sent to).
        var chatHandlesCache: [Int64: [Handle]] = [:]

        var results: [Result] = []
        results.reserveCapacity(min(rows.count, 256))

        for row in rows {
            let rawDate: Int64 = row["date"]
            let date = MessageDate.date(fromRaw: rawDate)

            let isFromMe: Bool = (row["is_from_me"] as Int? ?? 0) == 1
            let text: String? = row["text"]
            let blob: Data? = row["attributedBody"]
            let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)

            // Phrase filter — case-insensitive substring, all needles required.
            if !needles.isEmpty {
                let lowerBody = body.lowercased()
                var matchedAll = true
                for n in needles {
                    if !lowerBody.contains(n) {
                        matchedAll = false
                        break
                    }
                }
                if !matchedAll { continue }
            }

            let chatID: Int64 = row["chat_id"]
            let senderHandle: String? = row["sender_handle"]
            let chatStyle: Int? = row["chat_style"]
            let chatDisplayName: String? = row["chat_display_name"]
            let messageGUID: String? = row["guid"]
            let chatGUID: String? = row["chat_guid"]

            // Person filter
            if let person {
                let participantHandles: [Handle]
                if isFromMe {
                    // Sent: look up the chat's other participants.
                    participantHandles = handles(forChat: chatID, cache: &chatHandlesCache)
                } else {
                    // Received: the sender IS the participant.
                    participantHandles = senderHandle.map { [Handle(raw: $0)] } ?? []
                }
                let matches = participantHandles.contains { person.handles.contains($0) }
                if !matches { continue }
            }

            let message = Message(
                id: row["rowid"],
                guid: messageGUID,
                date: date,
                isFromMe: isFromMe,
                chatRowID: chatID,
                senderHandle: senderHandle,
                chatStyle: chatStyle,
                chatDisplayName: chatDisplayName,
                body: body,
                associatedMessageType: row["associated_message_type"] as Int? ?? 0
            )

            let partner = partnerName(
                forChat: chatID,
                style: chatStyle,
                displayName: chatDisplayName,
                cache: &partnerNameCache,
                handlesCache: &chatHandlesCache
            )

            let sender: String
            if isFromMe {
                sender = "You"
            } else if let raw = senderHandle {
                sender = contacts.name(forRawHandle: raw)
            } else {
                sender = "(unknown)"
            }

            results.append(Result(
                message: message,
                partnerName: partner,
                senderName: sender,
                chatGUID: chatGUID
            ))
        }

        // Batched reaction load — ONE SQL query for the entire result set.
        // We collect every target GUID, hand them to `ReactionLoader`, and
        // splice reactions back onto each result. No N+1 in sight.
        //
        // Pre-MVP: search has no concept of "include reactions" toggle — we
        // always load them, since the UI now wants them on every row. If
        // perf becomes a problem on huge result sets we'd add a flag here;
        // the typical panel result is ≤ 200 rows so it's fine.
        let guids = results.compactMap { $0.message.guid }
        let reactionMap: [String: [Reaction]]
        if guids.isEmpty {
            reactionMap = [:]
        } else {
            // Failures load empty rather than failing the whole search —
            // a broken reaction subquery shouldn't kill the user's search.
            reactionMap = (try? ReactionLoader.reactions(
                forTargetGUIDs: guids,
                database: database,
                contacts: contacts
            )) ?? [:]
        }
        if !reactionMap.isEmpty {
            results = results.map { r in
                guard let guid = r.message.guid,
                      let rxns = reactionMap[guid], !rxns.isEmpty else { return r }
                return Result(
                    message: r.message,
                    partnerName: r.partnerName,
                    senderName: r.senderName,
                    chatGUID: r.chatGUID,
                    reactions: rxns
                )
            }
        }

        return results
    }

    // MARK: - Helpers

    /// One reaction-related filter parsed from a `reactions:` token.
    ///
    /// Three flavors:
    /// - `.count(.greaterEqual, 3)` — count comparator
    /// - `.any` — at least 1 reaction (sugar for `.count(.greaterEqual, 1)`)
    /// - `.kind(.love)` — at least one reaction of the named type
    ///
    /// Multiple filters AND together at SQL time. `reactions:>=3 reactions:love`
    /// means "at least 3 total reactions AND at least one is a love".
    public enum ReactionFilter: Sendable, Equatable {

        public enum Comparator: String, Sendable, Equatable {
            case greaterEqual = ">="
            case lessEqual = "<="
            case greater = ">"
            case less = "<"
            case equal = "="
        }

        /// Match by name. We only allow the *named* tapback kinds — the
        /// custom-emoji (`2006`) and sticker (`2007`) types don't have a
        /// stable user-facing keyword, so they're not addressable here.
        public enum Kind: String, Sendable, Equatable, CaseIterable {
            case love, like, laugh, emphasize, question, dislike

            /// The `associated_message_type` value this name maps to.
            public var typeValue: Int {
                switch self {
                case .love: return 2000
                case .like: return 2001
                case .dislike: return 2002
                case .laugh: return 2003
                case .emphasize: return 2004
                case .question: return 2005
                }
            }
        }

        case count(Comparator, Int)
        case any
        case kind(Kind)

        /// Parse the value side of `reactions:<value>`. Returns nil if the
        /// value isn't one of the recognized shapes — the caller drops the
        /// token (it stays in `freeText` so the user isn't punished for a
        /// typo).
        public static func parse(_ value: String) -> ReactionFilter? {
            let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty else { return nil }
            if trimmed == "any" { return .any }
            if let kind = Kind(rawValue: trimmed) { return .kind(kind) }
            // Comparator shapes: ">=N", "<=N", ">N", "<N", "=N", or bare "N".
            // Order matters — check 2-char prefixes before 1-char.
            let comparators: [(String, Comparator)] = [
                (">=", .greaterEqual),
                ("<=", .lessEqual),
                (">", .greater),
                ("<", .less),
                ("=", .equal),
            ]
            for (sym, cmp) in comparators {
                if trimmed.hasPrefix(sym) {
                    let rest = trimmed.dropFirst(sym.count)
                    if let n = Int(rest), n >= 0 {
                        return .count(cmp, n)
                    }
                    return nil
                }
            }
            if let n = Int(trimmed), n >= 0 {
                return .count(.equal, n)
            }
            return nil
        }
    }

    /// Parsed structured query.
    ///
    /// All filters AND together. `freeText` feeds `parseNeedles`; the others
    /// drop into their respective SQL clauses.
    public struct ParsedQuery: Sendable, Equatable {
        public let freeText: String
        public let chatFilters: [String]
        public let fromFilters: [String]
        public let toFilters: [String]
        public let dateRange: ClosedRange<Date>?
        /// Reaction-thresholds + kind filters parsed from `reactions:` tokens.
        public let reactionFilters: [ReactionFilter]
        /// The tokens we recognized, in order, with their original spelling.
        /// Used by the UI to highlight active filters inline.
        public let tokens: [Token]

        public init(
            freeText: String,
            chatFilters: [String] = [],
            fromFilters: [String] = [],
            toFilters: [String] = [],
            dateRange: ClosedRange<Date>? = nil,
            reactionFilters: [ReactionFilter] = [],
            tokens: [Token] = []
        ) {
            self.freeText = freeText
            self.chatFilters = chatFilters
            self.fromFilters = fromFilters
            self.toFilters = toFilters
            self.dateRange = dateRange
            self.reactionFilters = reactionFilters
            self.tokens = tokens
        }
    }

    /// A single recognized token, with the substring range it occupied in the
    /// original query — handy for inline highlighting in the UI.
    public struct Token: Sendable, Equatable {
        public let prefix: TokenPrefix
        public let value: String
        public let range: Range<String.Index>
        public init(prefix: TokenPrefix, value: String, range: Range<String.Index>) {
            self.prefix = prefix
            self.value = value
            self.range = range
        }
    }

    /// Extract recognized tokens from the phrase. Everything else stays in
    /// `freeText`. Supports quoted values: `chat:"Amme Satyajit"`.
    ///
    /// Unknown token prefixes (e.g. `foo:bar`) are treated as free text — the
    /// parser is permissive so users don't get punished for typos.
    public static func parseQuery(
        _ phrase: String,
        contacts: ResolvedContacts? = nil,
        now: Date = Date()
    ) -> ParsedQuery {
        let tokens = tokenize(phrase)
        var freeText = ""
        var chats: [String] = []
        var froms: [String] = []
        var tos: [String] = []
        var dateRanges: [ClosedRange<Date>] = []
        var dateInstants: [(TokenPrefix, Date)] = []
        var reactionFilters: [ReactionFilter] = []
        var recognized: [Token] = []

        for token in tokens {
            if token.prefix == nil {
                // Free text — preserve original substring.
                if !freeText.isEmpty { freeText.append(" ") }
                freeText.append(String(phrase[token.range]))
                continue
            }
            guard let prefix = token.prefix else { continue }
            let raw = token.value
            if raw.isEmpty {
                // Graceful: `from:` with no value is a no-op, not a syntax error.
                // Don't add it to the filters; don't remove from query.
                recognized.append(Token(prefix: prefix, value: raw, range: token.range))
                continue
            }
            switch prefix {
            case .chat, .in:
                chats.append(raw)
            case .from:
                froms.append(raw)
            case .to:
                tos.append(raw)
            case .reactions:
                if let f = ReactionFilter.parse(raw) {
                    reactionFilters.append(f)
                } else {
                    // Unrecognized reactions value — treat the WHOLE token as
                    // free text so the user sees what they typed survive into
                    // results (matches how `foo:bar` falls through).
                    if !freeText.isEmpty { freeText.append(" ") }
                    freeText.append(String(phrase[token.range]))
                    continue
                }
            case .before, .after, .on, .last:
                if let expr = DateParser.parse(raw, now: now) {
                    switch expr {
                    case .range(let r):
                        switch prefix {
                        case .on, .last:
                            dateRanges.append(r)
                        case .before:
                            dateRanges.append(Date.distantPast...r.lowerBound)
                        case .after:
                            dateRanges.append(r.upperBound...Date.distantFuture)
                        default: break
                        }
                    case .instant(let d):
                        dateInstants.append((prefix, d))
                    }
                }
            }
            recognized.append(Token(prefix: prefix, value: raw, range: token.range))
        }

        // Combine all date constraints by intersection.
        var combined: ClosedRange<Date>? = nil
        for r in dateRanges {
            combined = combined.map { intersect($0, r) ?? $0 } ?? r
        }
        for (op, d) in dateInstants {
            let r: ClosedRange<Date>
            switch op {
            case .before: r = Date.distantPast...d
            case .after: r = d...Date.distantFuture
            case .on:
                let cal = Calendar.current
                let start = cal.startOfDay(for: d)
                let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
                r = start...end
            default: continue
            }
            combined = combined.map { intersect($0, r) ?? $0 } ?? r
        }

        return ParsedQuery(
            freeText: freeText,
            chatFilters: chats,
            fromFilters: froms,
            toFilters: tos,
            dateRange: combined,
            reactionFilters: reactionFilters,
            tokens: recognized
        )
    }

    /// Internal token result of `tokenize`.
    struct RawToken {
        let prefix: TokenPrefix?
        let value: String
        let range: Range<String.Index>
    }

    /// Walk the query string, splitting on whitespace but respecting quoted
    /// segments (`chat:"Amme Satyajit"`). Returns tokens with their ranges so
    /// callers (the highlighter, the autocomplete) know where to draw.
    static func tokenize(_ phrase: String) -> [RawToken] {
        var tokens: [RawToken] = []
        var i = phrase.startIndex
        while i < phrase.endIndex {
            // Skip whitespace.
            while i < phrase.endIndex, phrase[i].isWhitespace {
                i = phrase.index(after: i)
            }
            guard i < phrase.endIndex else { break }

            let tokenStart = i
            var inQuotes = false
            while i < phrase.endIndex {
                let ch = phrase[i]
                if ch == "\"" {
                    inQuotes.toggle()
                    i = phrase.index(after: i)
                    continue
                }
                if ch.isWhitespace && !inQuotes {
                    break
                }
                i = phrase.index(after: i)
            }
            let tokenEnd = i
            let token = String(phrase[tokenStart..<tokenEnd])
            let lower = token.lowercased()

            var matched: (TokenPrefix, String)? = nil
            for p in TokenPrefix.allCases where lower.hasPrefix(p.rawValue) {
                var v = String(token.dropFirst(p.rawValue.count))
                // Strip surrounding quotes.
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                    v.removeFirst()
                    v.removeLast()
                } else if v.hasPrefix("\"") {
                    v.removeFirst()
                }
                matched = (p, v)
                break
            }
            if let (prefix, value) = matched {
                tokens.append(RawToken(prefix: prefix, value: value, range: tokenStart..<tokenEnd))
            } else {
                tokens.append(RawToken(prefix: nil, value: token, range: tokenStart..<tokenEnd))
            }
        }
        return tokens
    }

    /// Intersect two optional ranges. If either is nil, returns the other.
    /// If they don't overlap, returns nil.
    static func intersect(_ a: ClosedRange<Date>?, _ b: ClosedRange<Date>?) -> ClosedRange<Date>? {
        guard let a, let b else { return a ?? b }
        return intersect(a, b)
    }

    static func intersect(_ a: ClosedRange<Date>, _ b: ClosedRange<Date>) -> ClosedRange<Date>? {
        let lower = max(a.lowerBound, b.lowerBound)
        let upper = min(a.upperBound, b.upperBound)
        guard lower <= upper else { return nil }
        return lower...upper
    }

    /// Build the chat predicate. Each filter does a case-insensitive substring
    /// match on `chat.display_name`. Filters AND together (every named chat
    /// must match — uncommon but consistent with how phrase needles AND).
    static func chatClause(_ filters: [String]) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            clauses.append("ch.display_name LIKE ?")
            args.append("%\(filter)%")
        }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Resolve a person-filter substring to a list of (raw or normalized)
    /// handle strings. The substring may match a contact's `displayName`
    /// (case-insensitive substring), or a raw/normalized handle directly
    /// (so `from:415` finds messages from a number containing "415").
    ///
    /// All distinct handles that ANY matching contact owns are OR'd together
    /// — so `from:satyajit` catches messages from BOTH the user's phone and
    /// email if the contact entry has both.
    static func resolveHandles(forFilter filter: String, contacts: ResolvedContacts) -> [String] {
        let lower = filter.lowercased()
        var handles: Set<String> = []
        // Contact display name matches.
        for c in contacts.allContacts where c.displayName.lowercased().contains(lower) {
            for h in c.handles {
                handles.insert(h.normalized)
                handles.insert(h.raw)
            }
        }
        // Raw/normalized handle substring match. Cheap — set is small.
        for (handle, _) in contacts.byHandle {
            if handle.raw.lowercased().contains(lower) || handle.normalized.lowercased().contains(lower) {
                handles.insert(handle.raw)
                handles.insert(handle.normalized)
            }
        }
        // Important: if no contact / handle matched, still try the raw filter
        // as a literal handle search. Catches "+1415..." style queries where
        // the contact isn't in AddressBook.
        if handles.isEmpty {
            handles.insert(filter)
        }
        return Array(handles)
    }

    /// Build the `from:` predicate. Each filter restricts to messages that:
    ///   - are NOT from me (is_from_me = 0)
    ///   - have a sender handle that matches the resolved person.
    ///
    /// Multiple `from:` AND together (a message can't be from two people, so
    /// AND across filters in practice means "all filters must match the same
    /// sender" — most users will use one). For OR-within-filter we just dump
    /// all candidate handles into an `IN` list.
    static func fromClause(
        _ filters: [String],
        contacts: ResolvedContacts
    ) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            let candidates = resolveHandles(forFilter: filter, contacts: contacts)
            guard !candidates.isEmpty else { continue }
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
            // is_from_me = 0 means received, and the sender's handle must
            // match one of our resolved candidates. We compare on `h.id`
            // (the raw string from `handle` table) — that's why we include
            // both raw and normalized forms in the candidate set.
            clauses.append("(m.is_from_me = 0 AND h.id IN (\(placeholders)))")
            for c in candidates { args.append(c) }
        }
        if clauses.isEmpty { return ("", []) }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Build the `to:` predicate. Each filter restricts to:
    ///   - is_from_me = 1 (you sent it)
    ///   - the chat's participants include the named person.
    ///
    /// We enumerate the candidate chats via a subquery against
    /// `chat_handle_join`, then constrain `cmj.chat_id` to that set.
    static func toClause(
        _ filters: [String],
        contacts: ResolvedContacts
    ) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            let candidates = resolveHandles(forFilter: filter, contacts: contacts)
            guard !candidates.isEmpty else { continue }
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
            clauses.append("""
                (m.is_from_me = 1 AND cmj.chat_id IN (
                    SELECT chj.chat_id
                    FROM chat_handle_join chj
                    JOIN handle h2 ON h2.ROWID = chj.handle_id
                    WHERE h2.id IN (\(placeholders))
                ))
                """)
            for c in candidates { args.append(c) }
        }
        if clauses.isEmpty { return ("", []) }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Parse the phrase into lowercased needles. Empty needles (from trailing
    /// `+`) and pure-whitespace tokens are discarded.
    static func parseNeedles(_ phrase: String) -> [String] {
        phrase
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Build a *coarse* SQL pre-filter for the phrase.
    ///
    /// For each needle we OR together:
    ///   - `m.text LIKE '%needle%'` — case-insensitive ASCII LIKE on the legacy
    ///     text column (NULL for modern messages, so no-op there).
    ///   - `INSTR(m.attributedBody, <bytes>) > 0` repeated for each ASCII case
    ///     variant of the needle (lowercase, titlecase, UPPERCASE). `INSTR`
    ///     does an exact byte-match against the BLOB. `LIKE` on a BLOB does
    ///     NOT work — SQLite returns no matches even when the bytes are
    ///     present — and `CAST(blob AS TEXT)` produces an empty string for
    ///     blobs containing invalid UTF-8 (which all attributedBody blobs do).
    ///
    /// All needles must match (AND between needles, OR within each needle's
    /// "text or blob-variant" options).
    ///
    /// **Case-sensitivity caveat**: byte-level `INSTR` is case-sensitive. We
    /// search three variants (lower/Title/UPPER) which captures ~99% of real-
    /// world messages (proper nouns are usually Title; sentence-starts are
    /// often Title; ALL-CAPS is rare). Edge cases like "iPhone" or "macOS"
    /// where multiple-letter casing matters slip through. The final Swift
    /// filter on the decoded body is case-insensitive and will refine — but
    /// it can't recover rows the SQL pre-filter never fetched. Fully fixed by
    /// the FTS5 mirror (Round 2 item #4).
    static func phraseClause(_ needles: [String]) -> (String, [DatabaseValueConvertible]) {
        guard !needles.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for needle in needles {
            let lower = needle.lowercased()
            let title = lower.capitalized       // "henry" -> "Henry"
            let upper = lower.uppercased()      // "henry" -> "HENRY"

            clauses.append("""
                (
                    m.text LIKE ?
                    OR INSTR(m.attributedBody, ?) > 0
                    OR INSTR(m.attributedBody, ?) > 0
                    OR INSTR(m.attributedBody, ?) > 0
                )
                """)
            args.append("%\(lower)%")
            args.append(Data(lower.utf8))
            args.append(Data(title.utf8))
            args.append(Data(upper.utf8))
        }
        return ("AND " + clauses.joined(separator: " AND "), args)
    }

    /// Build the reactions predicate.
    ///
    /// Reactions live in the same `message` table — they're rows where
    /// `associated_message_type` is in 2000-2999. To filter a target message
    /// by reaction count or kind we use a correlated subquery against
    /// `message` itself, matched on `associated_message_guid`.
    ///
    /// The join key is **not** equal to `m.guid` directly — real rows carry
    /// a positional prefix (`p:N/`, `bp:`). We enumerate the known variants
    /// in an IN list rather than using `LIKE '%' || m.guid`:
    ///   - `m.guid` (bare — rare, but does appear)
    ///   - `'p:0/' || m.guid` (most common, ~92%)
    ///   - `'p:1/' || m.guid` … `'p:N/' || m.guid` for N up to 9
    ///   - `'bp:' || m.guid`
    ///
    /// A leading-wildcard LIKE turns the subquery into a full scan of every
    /// tapback row per candidate, which collapsed an empirical real-world DB
    /// (~200k messages, ~50k tapbacks) into multi-minute query times. The
    /// IN approach can use the implicit index on `associated_message_guid`
    /// and stays sub-second.
    ///
    /// SQL shape for a single `.count(>=, 3)` filter:
    /// ```
    /// AND (
    ///   SELECT COUNT(*) FROM message r
    ///   WHERE r.associated_message_type BETWEEN 2000 AND 2999
    ///     AND r.associated_message_guid IN (
    ///         m.guid, 'p:0/' || m.guid, 'p:1/' || m.guid, …, 'bp:' || m.guid
    ///     )
    /// ) >= 3
    /// ```
    ///
    /// For `.kind(.love)` we add `AND r.associated_message_type = 2000` and
    /// require count > 0.
    ///
    /// Multiple filters AND together (each becomes its own subquery).
    /// `reactions:>=3 reactions:love` ⇒ at least 3 total AND at least one love.
    ///
    /// Empty input → no predicate.
    static func reactionsClause(_ filters: [ReactionFilter]) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        // Build the IN list of join-key variants. We cover `p:0/` through
        // `p:9/` (the parts with single-digit indices that we've actually
        // observed in real-world DBs), `bp:`, and the bare GUID. Beyond
        // p:9/ is extraordinarily rare (multi-part attachment messages
        // with 10+ segments are essentially non-existent in iMessage's
        // history) — if it ever needed expanding we'd add up to 19.
        let prefixes: [String] = [""] + (0...9).map { "p:\($0)/" } + ["bp:"]
        let inExpressions = prefixes.map { p in
            p.isEmpty ? "m.guid" : "'\(p)' || m.guid"
        }.joined(separator: ", ")

        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            // Common subquery template — the join key IN list and the
            // type range. The `m.guid IS NOT NULL` guard prevents matching
            // every NULL-GUID row to empty-prefix variants on a few very
            // old rows that have no guid.
            let baseSub = """
                SELECT COUNT(*) FROM message r
                WHERE r.associated_message_type BETWEEN 2000 AND 2999
                  AND m.guid IS NOT NULL
                  AND r.associated_message_guid IN (\(inExpressions))
                """
            switch filter {
            case .count(let cmp, let n):
                clauses.append("((\(baseSub)) \(cmp.rawValue) ?)")
                args.append(n)
            case .any:
                // Sugar for count >= 1.
                clauses.append("((\(baseSub)) >= 1)")
            case .kind(let kind):
                // Same base but additionally constrained to one type value,
                // and we require count > 0.
                let typed = baseSub + " AND r.associated_message_type = ?"
                clauses.append("((\(typed)) >= 1)")
                args.append(kind.typeValue)
            }
        }
        if clauses.isEmpty { return ("", []) }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Build the date predicate. Handles the nanoseconds-OR-seconds case from
    /// `plans.md`. Empty range → no predicate.
    static func dateClause(_ range: ClosedRange<Date>?) -> (String, [DatabaseValueConvertible]) {
        guard let range else { return ("", []) }
        let lo = range.lowerBound
        let hi = range.upperBound
        let loNS = MessageDate.nanosecondsSinceMacEpoch(from: lo)
        let hiNS = MessageDate.nanosecondsSinceMacEpoch(from: hi)
        let loS = MessageDate.secondsSinceMacEpoch(from: lo)
        let hiS = MessageDate.secondsSinceMacEpoch(from: hi)
        let sql = """
            AND (
                  (m.date > 1000000000000 AND m.date BETWEEN ? AND ?)
               OR (m.date <= 1000000000000 AND m.date BETWEEN ? AND ?)
            )
            """
        return (sql, [loNS, hiNS, loS, hiS])
    }

    /// Resolve a chat's "partner" name — what we'd show in a results list
    /// as the conversation identity.
    private func partnerName(
        forChat chatID: Int64,
        style: Int?,
        displayName: String?,
        cache: inout [Int64: String],
        handlesCache: inout [Int64: [Handle]]
    ) -> String {
        if let cached = cache[chatID] { return cached }

        let label: String
        if let displayName, !displayName.isEmpty {
            label = "[group] \(displayName)"
        } else if style == 43 {
            // Group without a name: list a few members.
            let hs = handles(forChat: chatID, cache: &handlesCache)
            let names = hs.map { contacts.byHandle[$0]?.displayName ?? $0.raw }
            let preview = names.prefix(4).joined(separator: ", ")
            let suffix = names.count > 4 ? " +\(names.count - 4)" : ""
            label = "[group] " + preview + suffix
        } else {
            // 1:1: the single other participant.
            let hs = handles(forChat: chatID, cache: &handlesCache)
            if let first = hs.first {
                label = contacts.byHandle[first]?.displayName ?? first.raw
            } else {
                label = "(unknown)"
            }
        }

        cache[chatID] = label
        return label
    }

    /// Fetch & cache the participant handles for a chat (excluding the user).
    private func handles(forChat chatID: Int64, cache: inout [Int64: [Handle]]) -> [Handle] {
        if let cached = cache[chatID] { return cached }
        let rows: [String] = (try? database.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT h.id
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = ?
                """, arguments: [chatID])
        }) ?? []
        let hs = rows.map { Handle(raw: $0) }
        cache[chatID] = hs
        return hs
    }
}
