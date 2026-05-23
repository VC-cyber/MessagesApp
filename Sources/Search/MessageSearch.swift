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
        /// Raw PNG / JPEG bytes of the sender's contact photo, resolved via
        /// `ContactResolver`. Nil when the sender is "You" (we don't render
        /// our own avatar for own-sent messages — the chat partner identity
        /// matters more here), when the sender is an unresolved handle, or
        /// when the resolved contact has no photo. UI falls back to initials
        /// via `AvatarView`.
        public let senderAvatar: Data?
        /// What kind of content this message carries — text, image, video,
        /// sticker, link preview, etc. Populated by a single batched
        /// `AttachmentLoader.types(forMessageGUIDs:database:)` call after the
        /// main result query (same place `reactions` are spliced in). Default
        /// `.text` so empty-loader / lookup-miss / no-GUID rows stay textual.
        public let messageType: MessageType

        public init(
            message: Message,
            partnerName: String,
            senderName: String,
            chatGUID: String? = nil,
            reactions: [Reaction] = [],
            senderAvatar: Data? = nil,
            messageType: MessageType = .text
        ) {
            self.message = message
            self.partnerName = partnerName
            self.senderName = senderName
            self.chatGUID = chatGUID
            self.reactions = reactions
            self.senderAvatar = senderAvatar
            self.messageType = messageType
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
    /// - `type:image` / `type:video` / `type:audio` / `type:sticker` /
    ///   `type:link` / `type:file` / `type:text` / `type:attachment`. Multiple
    ///   `type:` tokens OR together (so `type:image type:video` = images OR
    ///   videos). `type:attachment` is sugar for any non-text non-link kind.
    ///
    /// All filters AND together (within a category — multiple `type:` tokens
    /// OR within the type category, see above). Caller-supplied `person` /
    /// `dateRange` AND with anything parsed from the phrase.
    public func search(
        phrase: String,
        person: Contact? = nil,
        dateRange: ClosedRange<Date>? = nil,
        limit: Int? = nil,
        now: Date = Date()
    ) throws -> [Result] {

        let parsed = Self.parseQuery(phrase, contacts: contacts, now: now)
        let needles = Self.parseNeedles(parsed.freeText, preserveCase: parsed.caseSensitive)
        // If phrase is non-empty but parses to no needles (e.g. just "+"),
        // treat as no-text-filter so person/date/chat filters still work.

        // Combine caller-supplied date range with any parsed date range. Both
        // narrow the search; intersection (AND) is the semantically correct
        // composition. If they don't overlap, the result is empty.
        let combinedRange = Self.intersect(dateRange, parsed.dateRange)

        let (dateSQL, dateArgs) = Self.dateClause(combinedRange)
        let (phraseSQL, phraseArgs) = Self.phraseClause(needles, caseSensitive: parsed.caseSensitive)
        let (chatSQL, chatArgs) = Self.chatClause(parsed.chatFilters, contacts: contacts)
        let (fromSQL, fromArgs) = Self.fromClause(parsed.fromFilters, contacts: contacts)
        let (toSQL, toArgs) = Self.toClause(parsed.toFilters, contacts: contacts)
        let (reactionsSQL, reactionsArgs) = Self.reactionsClause(parsed.reactionFilters)
        let typeSQL = Self.typeClause(parsed.typeFilters)
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
              \(typeSQL)
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

            // Phrase filter — all needles required. Case sensitivity follows
            // the parsed `case:sensitive` modifier. In the default (case-
            // insensitive) path, `needles` are already lowercased by
            // parseNeedles; we just lowercase the body to match. In the
            // case-sensitive path, `needles` retain user-typed case and we
            // compare the body verbatim.
            if !needles.isEmpty {
                let comparedBody = parsed.caseSensitive ? body : body.lowercased()
                var matchedAll = true
                for n in needles {
                    if !comparedBody.contains(n) {
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
            let senderAvatar: Data?
            if isFromMe {
                sender = "You"
                // "You" gets initials — we don't have a self-avatar source
                // and surfacing it isn't useful in search results anyway
                // (every own-sent row would carry it).
                senderAvatar = nil
            } else if let raw = senderHandle {
                sender = contacts.name(forRawHandle: raw)
                senderAvatar = contacts.avatarData(forRawHandle: raw)
            } else {
                sender = "(unknown)"
                senderAvatar = nil
            }

            results.append(Result(
                message: message,
                partnerName: partner,
                senderName: sender,
                chatGUID: chatGUID,
                senderAvatar: senderAvatar
            ))
        }

        // Batched post-processing — ONE SQL query each for reactions and for
        // message types. Both keyed off the same set of result message GUIDs;
        // we collect once, then splice back in. No N+1 anywhere.
        //
        // Reactions: per-message tapback list. UI wants them on every row so
        // we always load them. Failures load empty rather than blowing up the
        // whole search — a broken reactions subquery shouldn't kill results.
        //
        // Types: per-message MessageType (text/image/video/audio/sticker/link/
        // file/applePay/location/other) derived from the attachment join and
        // balloon_bundle_id. Default `.text` so GUID-less rows (very old DBs)
        // and absent-from-map rows keep the textual default.
        let guids = results.compactMap { $0.message.guid }
        let reactionMap: [String: [Reaction]]
        let typeMap: [String: MessageType]
        if guids.isEmpty {
            reactionMap = [:]
            typeMap = [:]
        } else {
            reactionMap = (try? ReactionLoader.reactions(
                forTargetGUIDs: guids,
                database: database,
                contacts: contacts
            )) ?? [:]
            typeMap = (try? AttachmentLoader.types(
                forMessageGUIDs: guids,
                database: database
            )) ?? [:]
        }
        if !reactionMap.isEmpty || !typeMap.isEmpty {
            results = results.map { r in
                let guid = r.message.guid
                let rxns = guid.flatMap { reactionMap[$0] } ?? []
                let kind = guid.flatMap { typeMap[$0] } ?? .text
                // Skip allocating a new Result if there's nothing to splice.
                if rxns.isEmpty && kind == .text { return r }
                return Result(
                    message: r.message,
                    partnerName: r.partnerName,
                    senderName: r.senderName,
                    chatGUID: r.chatGUID,
                    reactions: rxns,
                    senderAvatar: r.senderAvatar,
                    messageType: kind
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

    /// One content-type filter parsed from a `type:` token.
    ///
    /// `type:image`, `type:video`, `type:audio`, `type:sticker`, `type:link`,
    /// `type:file`, `type:text`, `type:attachment` (sugar for any non-text
    /// non-link). Unrecognized values fall through to free text.
    ///
    /// Multiple `type:` tokens OR together — `type:image type:video` means
    /// "images OR videos". This matches user intuition: most filter prefixes
    /// AND, but `type:` is a discriminator where OR is what people want.
    public enum TypeFilter: Sendable, Equatable, Hashable {
        case image
        case video
        case audio
        case sticker
        case link
        case file
        case text
        /// Sugar — expands to `[image, video, audio, sticker, file, other]`
        /// at SQL build time. Excludes `.text` and `.linkPreview`.
        case attachment

        /// Resolve the filter to the concrete `MessageType` values it matches.
        public var messageTypes: [MessageType] {
            switch self {
            case .image:    return [.image]
            case .video:    return [.video]
            case .audio:    return [.audio]
            case .sticker:  return [.sticker]
            case .link:     return [.linkPreview]
            case .file:     return [.file, .applePay, .location, .other]
            case .text:     return [.text]
            case .attachment: return [.image, .video, .audio, .sticker, .file, .other]
            }
        }

        /// Parse a `type:` value. Returns nil for unrecognized inputs so the
        /// caller can fall back to treating the whole token as free text.
        public static func parse(_ value: String) -> TypeFilter? {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "image", "img", "photo": return .image
            case "video", "vid": return .video
            case "audio", "voice": return .audio
            case "sticker": return .sticker
            case "link", "url": return .link
            case "file", "doc", "pdf": return .file
            case "text", "plain": return .text
            case "attachment", "media", "any": return .attachment
            default: return nil
            }
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
        /// Content-type filters parsed from `type:` tokens. Multiple values
        /// OR together (so `type:image type:video` matches both).
        public let typeFilters: [TypeFilter]
        /// When true, the phrase match is case-sensitive (uses SQLite `GLOB`
        /// + byte-exact `INSTR` instead of the default `LIKE` + 3-variant
        /// case-fold INSTR). Toggled by the modifier `case:sensitive`
        /// (aliases `case:cs`, `case:on`) appearing anywhere in the query.
        public let caseSensitive: Bool
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
            typeFilters: [TypeFilter] = [],
            caseSensitive: Bool = false,
            tokens: [Token] = []
        ) {
            self.freeText = freeText
            self.chatFilters = chatFilters
            self.fromFilters = fromFilters
            self.toFilters = toFilters
            self.dateRange = dateRange
            self.reactionFilters = reactionFilters
            self.typeFilters = typeFilters
            self.caseSensitive = caseSensitive
            self.tokens = tokens
        }
    }

    /// Extract a `case:sensitive` / `case:cs` / `case:on` modifier from `text`
    /// (anywhere, whitespace-bounded) and return the cleaned text plus the
    /// flag. Case-insensitive on the modifier itself, so users can type
    /// `Case:Sensitive` etc.
    static func extractCaseFlag(_ text: String) -> (cleaned: String, caseSensitive: Bool) {
        let aliases = ["case:sensitive", "case:cs", "case:on"]
        var t = text
        var found = false
        for alias in aliases {
            // Use regex with word boundaries so we don't strip `case:cs` out of
            // a longer literal like `case:csv`. Tokens are whitespace-bounded.
            let pattern = "(?i)(?:^|\\s)\(NSRegularExpression.escapedPattern(for: alias))(?=\\s|$)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(t.startIndex..., in: t)
            if re.firstMatch(in: t, range: range) != nil {
                t = re.stringByReplacingMatches(in: t, range: range, withTemplate: "")
                found = true
            }
        }
        t = t.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return (t, found)
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
        var typeFilters: [TypeFilter] = []
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
            case .type:
                if let f = TypeFilter.parse(raw) {
                    typeFilters.append(f)
                } else {
                    // Unrecognized type value — fall through to free text.
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

        // Extract case-sensitivity modifier from the free text *after* the
        // tokenizer has consumed every recognized token. The modifier is
        // intentionally NOT in `TokenPrefix` — it doesn't take a value and
        // there's nothing to autocomplete.
        let (cleanedFreeText, caseSensitive) = Self.extractCaseFlag(freeText)

        return ParsedQuery(
            freeText: cleanedFreeText,
            chatFilters: chats,
            fromFilters: froms,
            toFilters: tos,
            dateRange: combined,
            reactionFilters: reactionFilters,
            typeFilters: typeFilters,
            caseSensitive: caseSensitive,
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
    /// Build the chat-filter predicate.
    ///
    /// A chat matches `in:value` (case-insensitive substring) if ANY of:
    /// 1. `chat.display_name` contains the substring — covers named group chats.
    /// 2. The chat has a participant resolved to a contact whose `displayName`
    ///    contains the substring — covers 1:1 chats (which always have empty
    ///    `display_name`) and unnamed groups when the user types a contact name.
    ///    Uses `resolveHandles` — the same helper `from:`/`to:` use.
    /// 3. The chat has a participant whose raw `handle.id` contains the
    ///    substring — covers e.g. `in:hoogar` matching the handle
    ///    `keeshant.hoogar@gmail.com` even when there's no contact entry.
    ///
    /// Multiple `in:` filters AND together. Within each filter, the three
    /// match conditions OR together.
    static func chatClause(
        _ filters: [String],
        contacts: ResolvedContacts
    ) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            var orParts: [String] = []

            // (1) Group display_name substring.
            orParts.append("ch.display_name LIKE ?")
            args.append("%\(filter)%")

            // (2) Contact-resolved participant.
            let resolved = resolveHandles(forFilter: filter, contacts: contacts)
            if !resolved.isEmpty {
                let placeholders = Array(repeating: "?", count: resolved.count).joined(separator: ", ")
                orParts.append("""
                    ch.ROWID IN (
                        SELECT chj.chat_id
                        FROM chat_handle_join chj
                        JOIN handle ph ON ph.ROWID = chj.handle_id
                        WHERE ph.id IN (\(placeholders))
                    )
                    """)
                for h in resolved { args.append(h) }
            }

            // (3) Raw handle substring.
            orParts.append("""
                ch.ROWID IN (
                    SELECT chj.chat_id
                    FROM chat_handle_join chj
                    JOIN handle ph ON ph.ROWID = chj.handle_id
                    WHERE ph.id LIKE ?
                )
                """)
            args.append("%\(filter)%")

            clauses.append("(" + orParts.joined(separator: " OR ") + ")")
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

    /// Parse the phrase into needles (lowercased by default). Empty needles
    /// (from trailing `+`) and pure-whitespace tokens are discarded. Pass
    /// `preserveCase: true` for case-sensitive search — the needles retain
    /// their original spelling and downstream SQL+Swift comparisons match
    /// exact case.
    static func parseNeedles(_ phrase: String, preserveCase: Bool = false) -> [String] {
        phrase
            .split(separator: "+", omittingEmptySubsequences: true)
            .map {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return preserveCase ? trimmed : trimmed.lowercased()
            }
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
    static func phraseClause(
        _ needles: [String],
        caseSensitive: Bool = false
    ) -> (String, [DatabaseValueConvertible]) {
        guard !needles.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for needle in needles {
            if caseSensitive {
                // Case-sensitive variant: GLOB is byte-exact in SQLite (LIKE
                // does ASCII case-folding). INSTR is always byte-exact; we
                // skip the 3-variant fan-out so the user gets EXACT case.
                clauses.append("(m.text GLOB ? OR INSTR(m.attributedBody, ?) > 0)")
                args.append("*\(needle)*")
                args.append(Data(needle.utf8))
            } else {
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
            // Per-sender dedup: a sender who switched reactions (e.g. love →
            // like) has TWO rows in `message`, but the UI's ReactionLoader
            // shows only their latest. The reactions count badge users see
            // is the count of DISTINCT senders with a non-removed reaction
            // — so the filter must dedupe the same way, otherwise
            // `reactions:>=6` matches messages whose badge shows 3.
            // GROUP BY (handle_id, is_from_me) collapses to one row per
            // sender; the outer SELECT COUNT(*) then counts senders.
            let baseSub = """
                SELECT COUNT(*) FROM (
                    SELECT 1 FROM message r
                    WHERE r.associated_message_type BETWEEN 2000 AND 2999
                      AND m.guid IS NOT NULL
                      AND r.associated_message_guid IN (\(inExpressions))
                    GROUP BY r.handle_id, r.is_from_me
                )
                """
            switch filter {
            case .count(let cmp, let n):
                clauses.append("((\(baseSub)) \(cmp.rawValue) ?)")
                args.append(n)
            case .any:
                // Sugar for count >= 1.
                clauses.append("((\(baseSub)) >= 1)")
            case .kind(let kind):
                // Same base but additionally constrained to one type value.
                // The inner-select WHERE adds the type predicate before the
                // GROUP BY so we count distinct senders whose latest reaction
                // is the requested kind. We still rely on the BETWEEN bound
                // dropping removed reactions; if a sender added love then
                // removed it, their love row remains and (by ReactionLoader's
                // own logic) they'd still count — both sides match.
                let typed = """
                    SELECT COUNT(*) FROM (
                        SELECT 1 FROM message r
                        WHERE r.associated_message_type = ?
                          AND m.guid IS NOT NULL
                          AND r.associated_message_guid IN (\(inExpressions))
                        GROUP BY r.handle_id, r.is_from_me
                    )
                    """
                clauses.append("((\(typed)) >= 1)")
                args.append(kind.typeValue)
            }
        }
        if clauses.isEmpty { return ("", []) }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Build the content-type predicate.
    ///
    /// Push as much as we can down to SQL so we don't waste candidates on the
    /// Swift side. SQL handles two cuts:
    ///   1. Attachment-based: messages whose ROWID is in the join target set
    ///      with attachments matching the filter (image/video/audio/sticker/
    ///      file mime prefix or is_sticker).
    ///   2. Balloon-based: messages whose `balloon_bundle_id` matches the
    ///      provider for link previews (`URLBalloonProvider`), Apple Pay,
    ///      etc. Captured as a `balloon_bundle_id LIKE '%...%'` clause.
    ///
    /// `type:text` is special — it's the NEGATION of any-attachment AND
    /// any-balloon. We emit:
    ///   AND m.ROWID NOT IN (SELECT message_id FROM message_attachment_join)
    ///   AND (m.balloon_bundle_id IS NULL OR m.balloon_bundle_id = '')
    ///
    /// `type:attachment` expands to `image OR video OR audio OR sticker OR file`
    /// (any non-text non-link content type). See `TypeFilter.messageTypes`.
    ///
    /// Multiple `type:` filters OR together at the top level — `type:image
    /// type:video` means "image OR video". This differs from how `chat:` /
    /// `from:` work (those AND) because users overwhelmingly want OR for type.
    ///
    /// Empty input → no predicate.
    static func typeClause(_ filters: [TypeFilter]) -> String {
        guard !filters.isEmpty else { return "" }

        // Flatten the requested types — dedup, preserving order. `attachment`
        // sugar expands here. Multiple `type:` tokens unify into a single OR.
        var requested: Set<MessageType> = []
        for f in filters {
            for t in f.messageTypes { requested.insert(t) }
        }
        guard !requested.isEmpty else { return "" }

        // Special case: `type:text` (and nothing else) — exclude any row that
        // has an attachment or a known balloon_bundle_id. We could mix text
        // with other types (`type:text type:image` ⇒ "text OR image") but
        // that's a strange query; we still support it via the union below.
        let wantsText = requested.contains(.text)
        // Attachment-based predicates: assembled into a single subquery
        // against the join. Each MIME class contributes a row-filter on the
        // attachment table; we union them in a single inner SELECT.
        let mimePreds = mimePredicates(for: requested)
        // Balloon-based predicates: link previews, Apple Pay, location, other.
        let balloonPreds = balloonPredicates(for: requested)

        var ors: [String] = []
        if !mimePreds.isEmpty {
            let mimeWhere = mimePreds.joined(separator: " OR ")
            ors.append("""
                m.ROWID IN (
                    SELECT mj.message_id
                    FROM message_attachment_join mj
                    JOIN attachment a ON a.ROWID = mj.attachment_id
                    WHERE \(mimeWhere)
                )
                """)
        }
        if !balloonPreds.isEmpty {
            ors.append("(" + balloonPreds.joined(separator: " OR ") + ")")
        }
        if wantsText {
            // A pure text message has no attachment row AND no balloon bundle.
            // (Empty string treated equivalently to NULL — both occur in real
            // DBs for the no-balloon case.)
            ors.append("""
                (
                  m.ROWID NOT IN (SELECT mj.message_id FROM message_attachment_join mj)
                  AND (m.balloon_bundle_id IS NULL OR m.balloon_bundle_id = '')
                )
                """)
        }
        if ors.isEmpty { return "" }
        return "AND (" + ors.joined(separator: " OR ") + ")"
    }

    /// Build the per-attachment mime/sticker predicates for the requested
    /// types. Each clause matches one attachment row's columns.
    private static func mimePredicates(for kinds: Set<MessageType>) -> [String] {
        var out: [String] = []
        if kinds.contains(.sticker) {
            out.append("a.is_sticker = 1")
        }
        if kinds.contains(.image) {
            out.append("(a.mime_type LIKE 'image/%' AND (a.is_sticker = 0 OR a.is_sticker IS NULL))")
        }
        if kinds.contains(.video) {
            out.append("a.mime_type LIKE 'video/%'")
        }
        if kinds.contains(.audio) {
            out.append("a.mime_type LIKE 'audio/%'")
        }
        if kinds.contains(.file) {
            // "File" here means: a real attachment row that ISN'T image/
            // video/audio/sticker. PDFs, vcards, docx, source files, plugin
            // payloads that didn't already get matched by balloon predicates.
            out.append("""
                (
                  (a.is_sticker = 0 OR a.is_sticker IS NULL)
                  AND (
                    a.mime_type IS NULL OR a.mime_type = ''
                    OR (
                      a.mime_type NOT LIKE 'image/%'
                      AND a.mime_type NOT LIKE 'video/%'
                      AND a.mime_type NOT LIKE 'audio/%'
                    )
                  )
                )
                """)
        }
        return out
    }

    /// Build the balloon_bundle_id predicates for the requested types. Each
    /// clause matches one row of `message` directly.
    private static func balloonPredicates(for kinds: Set<MessageType>) -> [String] {
        var out: [String] = []
        if kinds.contains(.linkPreview) {
            out.append("m.balloon_bundle_id LIKE '%URLBalloonProvider%'")
        }
        if kinds.contains(.applePay) {
            out.append("(m.balloon_bundle_id LIKE '%PeerPaymentMessagesExtension%' OR m.balloon_bundle_id LIKE '%PassbookUI%')")
        }
        if kinds.contains(.location) {
            out.append("m.balloon_bundle_id LIKE '%FindMyMessagesApp%'")
        }
        if kinds.contains(.other) {
            // "Other" captures the remaining balloon plugins (GamePigeon,
            // polls, handwriting, digital touch, …) — anything that has a
            // balloon_bundle_id but isn't one we recognize. Used by
            // `type:attachment` to sweep up plugin payloads.
            out.append("""
                (
                  m.balloon_bundle_id IS NOT NULL
                  AND m.balloon_bundle_id != ''
                  AND m.balloon_bundle_id NOT LIKE '%URLBalloonProvider%'
                  AND m.balloon_bundle_id NOT LIKE '%PeerPaymentMessagesExtension%'
                  AND m.balloon_bundle_id NOT LIKE '%PassbookUI%'
                  AND m.balloon_bundle_id NOT LIKE '%FindMyMessagesApp%'
                )
                """)
        }
        return out
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
