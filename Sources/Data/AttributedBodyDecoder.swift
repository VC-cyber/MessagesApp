//
//  AttributedBodyDecoder.swift
//  BetterMessages
//
//  Decodes `message.attributedBody` (a binary NSAttributedString typedstream)
//  to a printable String suitable for substring search and display.
//
//  Why not parse the typedstream properly?
//    - We don't need rich attributes — we only want the text content.
//    - `NSUnarchiver` is removed from Swift; `NSKeyedUnarchiver` is for a
//      different format and won't decode `streamtyped` blobs.
//    - The reference Python scripts use the lossy-UTF-8 approach. We refine it
//      with metadata filtering + framing trimming.
//
//  Algorithm:
//    1. Lossy UTF-8 decode (invalid bytes become U+FFFD).
//    2. Split into runs of "printable" scalars. U+FFFD acts as a separator so
//       invalid byte sequences (e.g. a typedstream length byte adjacent to
//       text) cleanly break runs.
//    3. Strip typedstream framing chars (`+`, `@`, brackets, control chars)
//       from the edges of each run.
//    4. Drop runs that are typedstream metadata: class names (`NSString`,
//       `NSDictionary`, …) and IMCore attribute keys (`__kIM*`).
//    5. Return the longest remaining run.
//
//  Pure. No I/O, no global state.
//

import Foundation

public enum AttributedBodyDecoder {

    /// Decode the attributed-body blob to a best-effort plain-text string.
    /// Returns an empty string if the blob is nil or yields no candidate runs.
    public static func decode(_ blob: Data?) -> String {
        guard let blob, !blob.isEmpty else { return "" }
        let decoded = String(decoding: blob, as: UTF8.self)
        let candidates = printableRuns(in: decoded, minimumLength: 2)
            .map(strippedFraming)
            .filter { !$0.isEmpty && !looksLikeMetadata($0) }
        if let best = candidates.max(by: { $0.count < $1.count }) {
            return best
        }
        // Pure-emoji-body fallback. A message that's just `💀` decodes to a
        // single supplementary-plane scalar (1 char), which the
        // `minimumLength: 2` filter drops. Scan for the longest contiguous
        // run of emoji-related scalars: supplementary plane chars (>= U+10000),
        // zero-width joiners (U+200D), and variation selectors (U+FE00–U+FE0F)
        // — together that covers single emoji, skin-tone modifiers, and
        // ZWJ-composed sequences like family emoji.
        return longestEmojiRun(in: decoded)
    }

    /// Longest contiguous run of emoji / ZWJ-sequence scalars in `string`.
    /// Used as a last-resort fallback for pure-emoji message bodies.
    static func longestEmojiRun(in string: String) -> String {
        var best = String.UnicodeScalarView()
        var current = String.UnicodeScalarView()
        func reset() {
            if current.count > best.count { best = current }
            current.removeAll(keepingCapacity: true)
        }
        for s in string.unicodeScalars {
            let v = s.value
            let isEmojiLike =
                v >= 0x10000 ||                       // supplementary planes
                v == 0x200D ||                        // ZWJ
                (v >= 0xFE00 && v <= 0xFE0F) ||       // variation selectors
                (v >= 0x2600 && v <= 0x27BF)          // misc symbols (☀️, ✨, etc.)
            if isEmojiLike {
                current.append(s)
            } else {
                reset()
            }
        }
        reset()
        return String(best)
    }

    /// All printable runs in `string` at least `minimumLength` characters long.
    /// "Printable" excludes ASCII control chars and the U+FFFD replacement
    /// character — the latter so invalid UTF-8 bytes (which Foundation maps to
    /// U+FFFD) act as run separators.
    public static func printableRuns(in string: String, minimumLength: Int) -> [String] {
        var runs: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            if current.count >= minimumLength {
                runs.append(String(current))
            }
            current.removeAll(keepingCapacity: true)
        }

        for scalar in string.unicodeScalars {
            if isPrintable(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    /// True iff `scalar` is part of a "text run" — not a typedstream framing
    /// byte (control char) and not U+FFFD (which signals invalid UTF-8 and
    /// should split runs).
    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // Replacement char — invalid UTF-8 in source. Use as separator.
        if v == 0xFFFD { return false }
        // ASCII printable.
        if v >= 0x20 && v <= 0x7E { return true }
        // Useful whitespace.
        if v == 0x09 || v == 0x0A { return true }
        // Above-ASCII BMP, excluding C1 controls (already below by lower bound)
        // and surrogates (invalid as scalars anyway). Keep emoji + accents.
        if v >= 0xA0 && v <= 0xFFFC { return true }
        // Supplementary planes — emoji live here (e.g. 🥺 = U+1F97A). Without
        // this branch, ending-emoji bytes get stripped, which throws off the
        // length-prefix strip (the rest's byte count no longer matches the
        // leading length byte, so we leak it).
        if v >= 0x10000 && v <= 0x10FFFF { return true }
        return false
    }

    /// Strip typedstream framing chars from the edges of a run. These bytes
    /// are typedstream type markers / class-definition sigils that decode as
    /// printable ASCII and end up glued to the start or end of message text.
    static func strippedFraming(_ run: String) -> String {
        let edges = CharacterSet(charactersIn: "+@()[]{}<>!*&^%$#\u{0001}\u{0002}\u{0003}\u{0004}\u{0005}\u{0006}\u{0007}\u{0008}")
            .union(.whitespacesAndNewlines)
        let trimmed = run.trimmingCharacters(in: edges)
        return stripLengthPrefix(trimmed)
    }

    /// Typedstream NSString length-prefix detection — BROAD printable-ASCII variant.
    ///
    /// The typedstream 1-byte length header for an NSString of byte-length N
    /// is literally the byte value N. After lossy UTF-8 decoding, that byte
    /// survives as a single printable scalar exactly when N is in
    /// printable-ASCII range (0x20–0x7E, 32–126) — anywhere else it's
    /// non-printable and our run-splitter already breaks the run at it.
    ///
    /// So whenever the longest surviving run starts with a printable-ASCII
    /// scalar whose byte value equals the run-rest's UTF-8 byte length, that
    /// leading scalar is a length prefix and must be stripped. Strip iff:
    ///   1. leading scalar `v` is in 0x20–0x7E, AND
    ///   2. `rest.utf8.count == v`
    ///
    /// Examples that the bug used to leak (now stripped):
    ///   - "rSatyajit Kanna, you…"   ← 'r' = 0x72 = 114, rest 114 bytes
    ///   - "?So none of our chats…"  ← '?' = 0x3F = 63,  rest 63 bytes
    ///   - "DSatyajit Kanna, how…"   ← 'D' = 0x44 = 68,  rest 68 bytes
    ///   - "2Looks like Amma's…"     ← '2' = 0x32 = 50,  rest 50 bytes
    ///
    /// Examples that are still preserved (rest length doesn't match):
    ///   - "1st place"   → '1' (49) vs rest 8 bytes  → keep
    ///   - "2 hours"     → '2' (50) vs rest 6 bytes  → keep
    ///   - "$5 each"     → '$' (36) vs rest 6 bytes  → keep
    ///
    /// False positives now require BOTH content that legitimately starts
    /// with a single printable-ASCII byte `c` AND the rest of the message
    /// being EXACTLY `c` bytes long. Empirically (see
    /// docs/decoder-fix-empirical.md) this collision is ≤1 per 1000
    /// messages in the user's chat.db, while the bug it fixes affected
    /// ~15% of messages. When a collision does happen the displayed
    /// result is still typically the sensible reading — preferring
    /// correct display in the common case over preserving the rare aligned
    /// case is the right trade.
    ///
    /// The proper long-term fix is byte-level typedstream parsing
    /// (Round-3); this heuristic eliminates the visible bug class until then.
    static func stripLengthPrefix(_ run: String) -> String {
        guard let first = run.unicodeScalars.first else { return run }
        let v = Int(first.value)
        // Length prefix in the typedstream NSString header is a single byte.
        // After lossy UTF-8 decoding it survives as a printable scalar only
        // when its byte value sits in printable-ASCII range (0x20–0x7E).
        guard v >= 0x20 && v <= 0x7E else { return run }
        let rest = String(run.unicodeScalars.dropFirst())
        if rest.utf8.count == v { return rest }

        // Fallback heuristic: leading ASCII digit (0–9) immediately followed
        // by an uppercase letter is virtually never legitimate user content
        // (people write "2 hours", "1st place", "200 dollars" — never "6Noah"
        // or "2Looks"). When the precise-length-match above fails (typically
        // because the message has trailing typedstream metadata glued onto
        // the same run, throwing off the byte count), this catches the
        // digit-then-uppercase pattern explicitly.
        if (0x30...0x39).contains(v),
           let secondScalar = rest.unicodeScalars.first,
           secondScalar.value >= 0x41 && secondScalar.value <= 0x5A {
            return rest
        }
        return run
    }

    /// True if the run is typedstream metadata (class name or IMCore attribute
    /// key) rather than user text. Conservative — only known patterns.
    static func looksLikeMetadata(_ run: String) -> Bool {
        // Apple Foundation / typedstream class names that appear in every blob.
        let exactMatches: Set<String> = [
            "streamtyped",
            "NSObject",
            "NSString", "NSMutableString",
            "NSAttributedString", "NSMutableAttributedString",
            "NSDictionary", "NSMutableDictionary",
            "NSArray", "NSMutableArray",
            "NSNumber", "NSValue",
            "NSData", "NSMutableData",
            "NSDate", "NSUUID", "NSURL",
            "iI",
        ]
        if exactMatches.contains(run) { return true }
        // IMCore message-part attribute keys: __kIMMessagePartAttributeName,
        // __kIMFileTransferGUIDAttributeName, __kIMBaseWritingDirectionAttributeName, etc.
        if run.hasPrefix("__kIM") { return true }
        // NSKeyedArchiver / NSDictionary internals (NS.string, NS.objects, etc).
        if run.hasPrefix("NS.") { return true }

        // NSKeyedArchiver bplist00 structural keys. These leak when a message
        // contains rich content (link previews, polls, Apple Pay, location).
        // The bplist marker for an ASCII string of length N is the byte 0x50|N,
        // which for N=4..15 happens to be ASCII uppercase (T,U,V,W,X,Y,Z,[,\,],^,_).
        // Lossy UTF-8 decoding glues those markers to the strings they prefix,
        // producing runs like "X$versionY$archiverT$topX$objects" — a single
        // concatenated run we can't easily split into separate scalars.
        // Detect by signature substring: if the run contains ANY of the
        // distinctive bplist NSKeyedArchiver keys, the whole run is metadata.
        for marker in ["$version", "$archiver", "$objects", "$null", "$classname", "$classes"] {
            if run.contains(marker) { return true }
        }

        // IMAttachment / file-transfer placeholder identifiers. When a message
        // is an attachment-only post (image/file/sticker), the attributedBody
        // contains `at_<part>_<transferGUID>` (e.g. `at_0_7D294F11-…`) instead
        // of body text. Filter so we don't display the placeholder GUID as the
        // message body. (Result row shows empty for now — future enhancement:
        // join the `attachment` table and display "[Image]" / filename.)
        if run.hasPrefix("at_"),
           let firstUnderscore = run.dropFirst(3).firstIndex(of: "_"),
           run[run.startIndex..<firstUnderscore].dropFirst(3).allSatisfy(\.isNumber) {
            return true
        }

        return false
    }
}
