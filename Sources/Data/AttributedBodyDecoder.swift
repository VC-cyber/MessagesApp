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
        return candidates.max(by: { $0.count < $1.count }) ?? ""
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

    /// Typedstream NSString length-prefix detection — DIGITS ONLY variant.
    ///
    /// The typedstream 1-byte length header for an NSString of byte-length N
    /// is literally the byte value N. For N in 0x30–0x39 (48–57) that byte
    /// decodes as ASCII '0'–'9' and sticks to the front of the run after
    /// lossy UTF-8 decoding, e.g. `"2Looks like Amma's flights..."`
    /// where the leading `'2'` is the byte `0x32` (= 50), not part of the body.
    ///
    /// We only strip when the leading scalar is an ASCII digit AND the
    /// remainder's UTF-8 byte length equals that digit's byte value. This is
    /// the user-visible symptom; broader heuristics (letters and punctuation)
    /// risked stripping legitimate content for messages of specific byte
    /// lengths (a 73-byte message starting with 'H' would have 'H' stripped).
    ///
    /// False positives within this narrower rule require: content starting
    /// with digit D, and total byte length D+1. Rare. Examples that AREN'T
    /// false-positive-stripped (rest length doesn't match digit value):
    ///   - "1st place"   → '1' (49) vs rest 8 bytes → keep
    ///   - "2 hours"     → '2' (50) vs rest 6 bytes → keep
    ///   - "$5 each"     → leading '$' isn't a digit → keep
    static func stripLengthPrefix(_ run: String) -> String {
        guard let first = run.unicodeScalars.first else { return run }
        let v = Int(first.value)
        guard v >= 0x30 && v <= 0x39 else { return run }       // ASCII digits only
        let rest = String(run.unicodeScalars.dropFirst())
        guard rest.utf8.count == v else { return run }
        return rest
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
        // NSKeyedArchiver / NSDictionary internals.
        if run.hasPrefix("NS.") { return true }
        return false
    }
}
