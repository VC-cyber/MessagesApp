//
//  AttributedBodyDecoderTests.swift
//  BetterMessagesTests
//
//  Locks the typedstream length-prefix stripping behavior in
//  `Sources/Data/AttributedBodyDecoder.swift`.
//
//  Background: attributedBody NSStrings are stored with a 1-byte length
//  prefix. After lossy UTF-8 decoding, that prefix survives as a single
//  scalar exactly when its byte value is in printable-ASCII range
//  (0x20–0x7E). The decoder strips it iff the rest of the run's UTF-8
//  byte length equals the leading scalar's byte value.
//
//  Test names follow the spec in `.claude/agents/features-agent.md`:
//    - testStrip_digitLengthPrefix         (regression-protect digits)
//    - testStrip_punctuationLengthPrefix   (broadened — '?' = 63)
//    - testStrip_letterLengthPrefix        (broadened — 'D' = 68)
//    - testStrip_emojiNotStripped          (above 0x7E never stripped)
//    - testStrip_lengthMismatchPreserved   ("1st place", "$5 each")
//    - testStrip_realFixtureRow            (end-to-end through ChatDatabase)
//

import XCTest
import GRDB
@testable import BetterMessages

final class AttributedBodyDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Build a string whose first scalar is `prefix` (a single-byte UTF-8
    /// char) and whose body has `bodyLength` UTF-8 bytes.
    private func runWithPrefix(_ prefix: Character, bodyByteLength: Int) -> String {
        // Use ASCII 'a' filler — 1 byte each. UTF-8 byte length == count.
        precondition(prefix.utf8.count == 1, "Prefix must be a single ASCII byte for these tests.")
        let body = String(repeating: "a", count: bodyByteLength)
        XCTAssertEqual(body.utf8.count, bodyByteLength, "Filler byte length should equal char count for ASCII filler.")
        return "\(prefix)\(body)"
    }

    // MARK: - Digit prefix (regression-protect the original narrow fix)

    /// A run that starts with an ASCII digit whose value equals the rest's
    /// UTF-8 byte length must be stripped. This was the entirety of the
    /// pre-broadening behavior — keep it nailed down.
    func testStrip_digitLengthPrefix() {
        // '2' = 0x32 = 50. Body of 50 'a's = 50 bytes. Should strip.
        let run = runWithPrefix("2", bodyByteLength: 50)
        let stripped = AttributedBodyDecoder.stripLengthPrefix(run)
        XCTAssertEqual(stripped, String(repeating: "a", count: 50),
                       "Digit length prefix '2' (50) over 50-byte body should be stripped.")

        // '5' = 0x35 = 53. Body of 53 'a's.
        let run2 = runWithPrefix("5", bodyByteLength: 53)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run2),
                       String(repeating: "a", count: 53))
    }

    // MARK: - Punctuation prefix (new — covers '?', '"', '/', etc.)

    /// User-reported pattern: `"?So none of our chats are private…"`. '?' is
    /// 0x3F = 63. Synthesize a 63-byte body and assert the '?' is stripped.
    func testStrip_punctuationLengthPrefix() {
        // '?' = 63.
        let body = "So none of our chats are private. Should we use cactus instead?"
        XCTAssertEqual(body.utf8.count, 63,
                       "Body length must match the prefix byte value for this test.")
        let run = "?\(body)"
        let stripped = AttributedBodyDecoder.stripLengthPrefix(run)
        XCTAssertEqual(stripped, body,
                       "'?' (63) over a 63-byte body must be stripped.")
    }

    /// Synthetic case where the prefix is a different punctuation char.
    func testStrip_punctuationLengthPrefix_otherChars() {
        // '"' = 0x22 = 34. 34-byte body of 'a's.
        let run34 = runWithPrefix("\"", bodyByteLength: 34)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run34),
                       String(repeating: "a", count: 34),
                       "'\"' (34) over 34-byte body must be stripped.")

        // '/' = 0x2F = 47. 47-byte body.
        let run47 = runWithPrefix("/", bodyByteLength: 47)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run47),
                       String(repeating: "a", count: 47),
                       "'/' (47) over 47-byte body must be stripped.")
    }

    // MARK: - Letter prefix (new — covers 'D', 'r', 'A', …)

    /// User-reported pattern: `"DSatyajit Kanna, how does Turboquant…"`.
    /// 'D' is 0x44 = 68. Synthesize a 68-byte body and assert stripped.
    func testStrip_letterLengthPrefix() {
        // 'D' = 68. 68-byte body of 'a's.
        let run = runWithPrefix("D", bodyByteLength: 68)
        let stripped = AttributedBodyDecoder.stripLengthPrefix(run)
        XCTAssertEqual(stripped, String(repeating: "a", count: 68),
                       "'D' (68) over 68-byte body must be stripped.")

        // 'A' = 0x41 = 65. 65-byte body.
        let run65 = runWithPrefix("A", bodyByteLength: 65)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run65),
                       String(repeating: "a", count: 65),
                       "'A' (65) over 65-byte body must be stripped.")

        // 'r' = 0x72 = 114. 114-byte body — matches the user-reported
        // "rSatyajit Kanna, you're getting paid $4,254 …" pattern.
        let run114 = runWithPrefix("r", bodyByteLength: 114)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run114),
                       String(repeating: "a", count: 114),
                       "'r' (114) over 114-byte body must be stripped.")
    }

    // MARK: - Non-ASCII / emoji prefix (must NEVER strip)

    /// A real message that starts with an emoji must not be touched. Emoji
    /// scalars are all above 0x7E, so they never qualify as length-prefix
    /// candidates — even if the rest of the body coincidentally matched.
    func testStrip_emojiNotStripped() {
        // 🎉 is U+1F389. 4 UTF-8 bytes (F0 9F 8E 89). Way above 0x7E.
        // Body byte length is irrelevant — the rule short-circuits on the
        // printable-ASCII check.
        let bodies = [
            "🎉 party time",
            "👋 hi",
            "❤️ love this",
            "🤓",  // single-emoji message
        ]
        for body in bodies {
            XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(body), body,
                           "Emoji-led body must be preserved verbatim: \(body)")
        }

        // Also try the worst case: emoji scalar followed by content whose
        // byte length coincidentally happens to be small — still no-op.
        let mixed = "🎂cake"  // 4-byte emoji + 4-byte word = body bytes irrelevant
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(mixed), mixed)
    }

    /// Non-ASCII Latin-1 (accented chars above 0x7E) also must not strip,
    /// even with byte counts that look "right".
    func testStrip_accentedLeadingCharNotStripped() {
        // 'é' is U+00E9 = 0xC3 0xA9 in UTF-8. Its scalar value is 0xE9
        // which is above the 0x7E ceiling, so the length-prefix rule must
        // never fire on it.
        let run = "épicé"
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run), run,
                       "Above-ASCII scalar must not be considered a length prefix.")
    }

    // MARK: - Length mismatch (must preserve real content)

    /// The classic preservation cases from the (lead's) original change-log
    /// entry — these messages legitimately start with the listed char and
    /// the rest of the body is NOT the byte-length the rule would require.
    func testStrip_lengthMismatchPreserved() {
        let cases: [(input: String, why: String)] = [
            // '1' = 49, rest "st place" = 8 bytes. Mismatch → keep.
            ("1st place", "'1' (49) vs rest 8 bytes — preserve"),
            // '2' = 50, rest " hours" = 6 bytes. Mismatch → keep.
            ("2 hours", "'2' (50) vs rest 6 bytes — preserve"),
            // '$' = 36, rest "5 each" = 6 bytes. Mismatch → keep.
            ("$5 each", "'$' (36) vs rest 6 bytes — preserve"),
            // 'H' = 72, rest "ello there" = 10 bytes. Mismatch → keep.
            ("Hello there", "'H' (72) vs rest 10 bytes — preserve"),
            // 'A' = 65, rest " is the first letter." = 21 bytes. Mismatch → keep.
            ("A is the first letter.", "'A' (65) vs rest 21 bytes — preserve"),
        ]
        for (input, why) in cases {
            XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(input), input,
                           "Length mismatch must preserve: \(why)")
        }
    }

    /// Edge cases — empty and single-char.
    func testStrip_edgeCases() {
        // Empty → unchanged.
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(""), "")

        // Single ASCII char — rest is 0 bytes. Strip iff first char's
        // value is 0 (impossible since 0 isn't printable ASCII). So
        // single chars are always preserved. (Note: chars whose byte
        // value is 0 wouldn't be printable, so the guard would skip them
        // anyway.)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix("a"), "a",
                       "Single ASCII char preserved (rest is 0 bytes, doesn't match value).")

        // A char whose value happens to be 0 (NUL) can't appear in a
        // printable run, but for completeness:
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix("\u{00}"), "\u{00}",
                       "NUL byte preserved — outside printable-ASCII range.")
    }

    // MARK: - End-to-end through decode(_:) with synthetic blob

    /// Synthesize a blob that mimics the real-chat.db layout for a message
    /// of byte length 50 ('2' as the length prefix). After full decode the
    /// returned body must be clean (no leading '2').
    ///
    /// Layout (mirrors Tests/Fixtures/build_fixture_chat_db.sh):
    ///   04 0b           magic
    ///   "streamtyped"   ASCII run (11 chars, broken by next non-printable)
    ///   81 e8 03 84 01  framing
    ///   12              len=18 for "NSString"
    ///   "NSString"      class-name run (8 chars)
    ///   00 84 84 08     framing
    ///   32              len=50 for body
    ///   <50 byte body>  body
    ///   86 84 02 ...    trailing framing
    func testDecode_endToEndSyntheticBlob_digit() {
        let body = String(repeating: "x", count: 50)  // 50 'x' bytes
        XCTAssertEqual(body.utf8.count, 50)

        var blob = Data([0x04, 0x0b])
        blob.append("streamtyped".data(using: .ascii)!)
        blob.append(contentsOf: [0x81, 0xe8, 0x03, 0x84, 0x01])
        blob.append(0x40)  // '@' framing sigil
        blob.append(contentsOf: [0x84, 0x84, 0x84])
        blob.append(0x12)  // length 18 for NSString
        blob.append("NSString".data(using: .ascii)!)
        blob.append(contentsOf: [0x00, 0x84, 0x84, 0x08])
        blob.append(0x32)  // length 50 for body
        blob.append(body.data(using: .ascii)!)
        blob.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x86, 0x84, 0x00])

        let decoded = AttributedBodyDecoder.decode(blob)
        XCTAssertEqual(decoded, body,
                       "End-to-end decode of digit-prefixed blob must return the body, not '2' + body. Got: \(decoded)")
    }

    /// Same as the digit case but with a letter prefix ('A' = 65, 65-byte body).
    /// Locks in the broadened behavior at the decode() entry point.
    func testDecode_endToEndSyntheticBlob_letter() {
        let body = String(repeating: "y", count: 65)
        XCTAssertEqual(body.utf8.count, 65)

        var blob = Data([0x04, 0x0b])
        blob.append("streamtyped".data(using: .ascii)!)
        blob.append(contentsOf: [0x81, 0xe8, 0x03, 0x84, 0x01])
        blob.append(0x40)
        blob.append(contentsOf: [0x84, 0x84, 0x84])
        blob.append(0x12)
        blob.append("NSString".data(using: .ascii)!)
        blob.append(contentsOf: [0x00, 0x84, 0x84, 0x08])
        blob.append(0x41)  // 'A' = 65 length prefix
        blob.append(body.data(using: .ascii)!)
        blob.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x86, 0x84, 0x00])

        let decoded = AttributedBodyDecoder.decode(blob)
        XCTAssertEqual(decoded, body,
                       "End-to-end decode of letter-prefixed blob must return the body, not 'A' + body. Got: \(decoded)")
    }

    // MARK: - End-to-end via fixture chat.db (integration)

    /// Opens the bundled fixture chat.db, fetches the rows we added that
    /// exhibit the length-prefix bug (digit + letter prefixes), and
    /// asserts the decoded body comes out clean.
    func testStrip_realFixtureRow() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources. Re-run Tests/Fixtures/build_fixture_chat_db.sh and rebuild.")
        }
        let db = try ChatDatabase(url: url)

        // Row 200 (digit-prefix): body byte len = 50, prefix byte = '2'.
        // Row 201 (letter-prefix): body byte len = 65, prefix byte = 'A'.
        // See Tests/Fixtures/build_fixture_chat_db.sh.

        let row200Blob: Data? = try db.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT attributedBody FROM message WHERE ROWID = 200")
        }
        guard let blob200 = row200Blob else {
            return XCTFail("Fixture row 200 missing or attributedBody is NULL. Re-run Tests/Fixtures/build_fixture_chat_db.sh.")
        }
        let decoded200 = AttributedBodyDecoder.decode(blob200)
        XCTAssertFalse(decoded200.hasPrefix("2"),
                       "Digit-prefix fixture (row 200) must decode without a leading '2'. Got: \(decoded200)")
        XCTAssertEqual(decoded200.utf8.count, 50,
                       "Digit-prefix fixture body must be exactly 50 bytes. Got: \(decoded200.utf8.count) bytes; body=\(decoded200)")

        let row201Blob: Data? = try db.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT attributedBody FROM message WHERE ROWID = 201")
        }
        guard let blob201 = row201Blob else {
            return XCTFail("Fixture row 201 missing or attributedBody is NULL. Re-run Tests/Fixtures/build_fixture_chat_db.sh.")
        }
        let decoded201 = AttributedBodyDecoder.decode(blob201)
        XCTAssertFalse(decoded201.hasPrefix("A"),
                       "Letter-prefix fixture (row 201) must decode without a leading 'A'. Got: \(decoded201)")
        XCTAssertEqual(decoded201.utf8.count, 65,
                       "Letter-prefix fixture body must be exactly 65 bytes. Got: \(decoded201.utf8.count) bytes; body=\(decoded201)")
    }
}
