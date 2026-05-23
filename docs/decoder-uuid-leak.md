# Empirical Note — bare-UUID leak in decoded message bodies

Investigation behind the `AttributedBodyDecoder.looksLikeMetadata` UUID filter
(features-agent, 2026-05-22).

## Symptom

In the user's UI screenshot, searching `type:video in:"Hao did this chat start"`
returned video messages. Most rows correctly showed "Video" with the camera SF
Symbol (type-placeholder fix), but two rows displayed the raw text:

```
6063E5D5-08EF-4993-BF5E-DA7C7DC723F7
```

A bare canonical UUID — strongly suggestive of an `attachment.guid` leaking
through.

## Where the UUID actually lives in chat.db

Verified against `~/Library/Messages/chat.db`:

- `message.guid` lookup for `6063E5D5-08EF-4993-BF5E-DA7C7DC723F7` → **no match**.
- `attachment.guid` lookup → **match**:
  - `ROWID = 35768`
  - `filename = ~/Library/Messages/Attachments/1e/14/6063E5D5-…/IMG_7970.MOV`
  - `mime_type = video/quicktime`
  - `transfer_name = IMG_7970.MOV`
- Joined via `message_attachment_join` → message `ROWID = 577192` is an
  attachment-only video post (text NULL, attributedBody 314 bytes).

So the leaked text is the **attachment GUID**, embedded inside the
`attributedBody` blob as a typedstream NSString.

## Why the existing decoder lets it through

The blob for that message contains exactly one runtime NSString carrying the
attachment GUID, prefixed in the typedstream by the IMCore attribute key
`__kIMFileTransferGUIDAttributeName`. Lossy UTF-8 decode of the raw blob
(first 500 chars):

```
\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString
\x00\x84\x84\x08NSObject\x00\x85\x84\x84\x84\x08NSString\x01\x95\x84\x01+
\x03\xef\xbf\xbc\x86\x84\x02iI\x01\x01\x86\x84\x84\x84\x0cNSDictionary
\x00\x84\x84\x01i\x03\x95\x84\x84\x84"__kIMFileTransferGUIDAttributeName
\x86\x84\x84\x84$6063E5D5-08EF-4993-BF5E-DA7C7DC723F7
\x86\x84\x84\x84&__kIMBaseWritingDirectionAttributeName…
```

The printable runs (split on non-printable + U+FFFD) come out as:

| # | run                                       | len |
|---|-------------------------------------------|-----|
| 0 | `streamtyped`                             | 11  |
| 1 | `NSAttributedString`                      | 18  |
| 2 | `NSObject`                                | 8   |
| 3 | `NSString`                                | 8   |
| 4 | `iI`                                      | 2   |
| 5 | `NSDictionary`                            | 12  |
| 6 | `"__kIMFileTransferGUIDAttributeName`     | 35  |
| 7 | `$6063E5D5-08EF-4993-BF5E-DA7C7DC723F7`   | 37  |
| 8 | `&__kIMBaseWritingDirectionAttributeName` | 39  |
| 9 | `NSNumber`                                | 8   |
| 10| `NSValue`                                 | 7   |
| 11| `__kIMMessagePartAttributeName`           | 29  |

After `strippedFraming`:

- Runs 0–5, 9–10: filtered by `looksLikeMetadata` (Foundation exactMatches).
- Run 6: leading `"` (0x22 = 34). Rest `__kIMFileTransferGUIDAttributeName`
  is 34 bytes. `stripLengthPrefix` removes the `"` → result `__kIM…` →
  caught by the `hasPrefix("__kIM")` rule.
- Run 8: leading `&` (in the framing-edge charset) trimmed → result
  `__kIMBaseWritingDirectionAttributeName` → caught by `__kIM`.
- Run 11: caught directly by `__kIM`.
- **Run 7**: leading `$` is in the framing-edge charset → trimmed to
  `6063E5D5-08EF-4993-BF5E-DA7C7DC723F7` (36 chars). Then `stripLengthPrefix`
  sees first scalar `6` (0x36 = 54); rest is 35 bytes; 54 ≠ 35 — no strip.
  Doesn't match Foundation exactMatches, no `__kIM` / `NS.` / bplist marker
  / `at_<n>_` prefix — **passes all filters and becomes the longest survivor**.

The 36-character canonical UUID slips past every existing filter.

## How prevalent is this?

Sampled 50,000 messages with non-NULL `attributedBody`:

- 5 rows (0.01%) decoded to a bare canonical UUID.

Across the full DB (574,491 rows): 18,087 messages contain a
`__kIMFileTransferGUID` attribute (i.e. carry at least one attachment), so the
shape exists in many rows; only a handful actually surface a bare UUID
because most attachment-bearing messages also embed the
`at_<n>_<UUID>` placeholder (already filtered) OR have non-empty text content.

Low prevalence in aggregate — but extremely visible when it does hit,
because the displayed body is a 36-char hex blob.

## The fix

Extend `looksLikeMetadata` to drop any run that is **exactly** a canonical
UUID — 36 chars, 8-4-4-4-12 hex-with-hyphens, case-insensitive. A bare UUID
is never legitimate user content; real bodies with a UUID in them ("the
GUID is 6063E5D5-…") never decode as the EXACT 36-char form because the
surrounding text makes the run longer.

The check is intentionally narrow: equality match against the canonical
shape only. No fuzzy variants, no "starts with UUID" matching — a single
character of surrounding text and the rule is a no-op.

## Net effect after the fix

The video-attachment row decodes to an empty body. `SpotlightResultRow`'s
type-placeholder kicks in and renders "Video" with the camera icon, matching
the other 30-odd video results in the same search.
