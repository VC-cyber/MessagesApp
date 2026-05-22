#!/usr/bin/env bash
# Build a small synthetic chat.db fixture for tests.
#
# Exercises every gotcha listed in plans.md → "Critical Technical Knowledge — chat.db":
#   - NULL text + decodable attributedBody (typedstream-ish hex blob)
#   - Sent message (is_from_me=1) with NULL handle_id
#   - Received message with a real handle_id
#   - 1:1 chat (style=45) AND group chat (style=43)
#   - associated_message_type != 0 (a tapback) — filterable
#   - One date in NANOSECONDS (post-10.13) and one in SECONDS (legacy)
#   - Two handles for the same contact (phone + email) for contact-merge tests
#
# Output: Tests/Fixtures/chat.db
# Idempotent: drops and recreates every run.
#
# Run from anywhere; we cd to script's dir first.

set -euo pipefail

cd "$(dirname "$0")"

DB="chat.db"
rm -f "$DB"

# Notes on the synthetic typedstream blob for attributedBody:
#   Real chat.db `attributedBody` is an NSKeyedArchiver/typedstream-encoded
#   NSAttributedString. We don't reproduce the full encoding here — we just
#   need (a) the test exercises the "text IS NULL, decode attributedBody"
#   path and (b) a lossy UTF-8 decode + longest-printable-run extraction
#   surfaces a known string. The blob below is structured so the LONGEST
#   contiguous printable-ASCII run is the message body
#   "hello cactus how are you today" (30 chars).
#
#   Layout (hex):
#     04 0b                 typedstream version magic
#     73 74 72 65 61 6d     "stream"  ← 6-char printable run (broken by next non-printable)
#     74 79 70 65 64        "typed"
#     81 e8 03 84 01        non-printable framing
#     40                    '@' (would be a 1-char run on its own)
#     84 84 84 12           non-printable framing
#     12 4e 53 53 74 72 69 6e 67   length(0x12)+"NSString" → run "NSString" (8)
#     00 84 84 08           breaks the run
#     1e                    length byte (30) for the upcoming string
#     "hello cactus how are you today"  ← the message: 30-char run
#     86 84 02 69 86 84     trailing framing (mostly non-printable)
#
#   Note "streamtyped" appears in the original spec as one 11-char run
#   ("stream" + "typed" with no break between). That's fine — 11 < 30.

ATTRIB_HEX="040b73747265616d747970656481e80384014084848412124e53537472696e670084840808"
ATTRIB_HEX+="1e68656c6c6f2063616374757320686f772061726520796f7520746f64617986840269868400"

# ---------------------------------------------------------------------------
# Time values (Mac absolute time; epoch = 2001-01-01 00:00:00 UTC)
# ---------------------------------------------------------------------------
# Modern (nanoseconds): 2024-06-15 12:00:00 UTC
#   unix     = 1718452800
#   mac s    = 1718452800 - 978307200 = 740_145_600
#   mac ns   = 740_145_600 * 1e9     = 740_145_600_000_000_000
NS_DATE=740145600000000000

# Legacy (seconds): 2010-06-15 12:00:00 UTC
#   unix     = 1276603200
#   mac s    = 1276603200 - 978307200 = 298_296_000
SEC_DATE=298296000

# A second modern message a minute later (for ordering / multi-row scans):
NS_DATE_2=740145660000000000

# A tapback message — also nanoseconds, modern.
NS_DATE_TAPBACK=740145720000000000

# Bursts of tapbacks for the reactions tests — staggered by 30s each so the
# ascending-by-date load order is deterministic.
NS_DATE_TAPBACK_2=740145750000000000
NS_DATE_TAPBACK_3=740145780000000000
NS_DATE_TAPBACK_4=740145810000000000
NS_DATE_TAPBACK_5=740145840000000000
NS_DATE_TAPBACK_6=740145870000000000
NS_DATE_TAPBACK_7=740145900000000000
NS_DATE_TAPBACK_8=740145930000000000
NS_DATE_TAPBACK_9=740145960000000000
NS_DATE_TAPBACK_10=740145990000000000
NS_DATE_TAPBACK_11=740146020000000000

# A "reactable" message (row 5) with a known GUID we can target from
# tapback rows. This is the message we'll surface in the reaction-loader
# test as having multiple reactions.
NS_DATE_REACTABLE=740146050000000000

sqlite3 "$DB" <<SQL
PRAGMA foreign_keys = OFF;

-- ----- schema (minimal-but-realistic subset of real chat.db) -----

CREATE TABLE handle (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL,                 -- "+15551234567" or "friend@example.com"
    country TEXT,
    service TEXT,                     -- "iMessage" or "SMS"
    uncanonicalized_id TEXT
);

CREATE TABLE chat (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    guid TEXT NOT NULL,
    style INTEGER,                    -- 45 = 1:1, 43 = group
    state INTEGER,
    account_id TEXT,
    chat_identifier TEXT,
    service_name TEXT,
    room_name TEXT,
    display_name TEXT
);

CREATE TABLE chat_handle_join (
    chat_id INTEGER,
    handle_id INTEGER,
    UNIQUE (chat_id, handle_id)
);

CREATE TABLE message (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    guid TEXT,
    text TEXT,
    handle_id INTEGER,                -- NULL when is_from_me=1
    is_from_me INTEGER NOT NULL DEFAULT 0,
    date INTEGER,                     -- Mac absolute time (ns post-10.13, s legacy)
    date_read INTEGER,
    date_delivered INTEGER,
    is_read INTEGER DEFAULT 0,
    is_sent INTEGER DEFAULT 0,
    service TEXT,                     -- "iMessage" / "SMS"
    account TEXT,
    associated_message_guid TEXT,
    associated_message_type INTEGER DEFAULT 0,  -- 0 = real msg, nonzero = tapback
    associated_message_emoji TEXT,    -- non-NULL for custom-emoji reactions (type=2006)
    attributedBody BLOB
);

CREATE TABLE chat_message_join (
    chat_id INTEGER,
    message_id INTEGER,
    message_date INTEGER,
    UNIQUE (chat_id, message_id)
);

-- ----- handles -----
-- Same contact, two handles (phone + email): handles 1 and 2.
INSERT INTO handle (ROWID, id, country, service) VALUES (1, '+15551234567', 'us', 'iMessage');
INSERT INTO handle (ROWID, id, country, service) VALUES (2, 'friend@example.com', 'us', 'iMessage');

-- A second contact, for the group chat:
INSERT INTO handle (ROWID, id, country, service) VALUES (3, '+15557654321', 'us', 'iMessage');

-- ----- chats -----
-- 1:1 chat (style=45) with the multi-handle contact.
INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
VALUES (1, 'iMessage;-;+15551234567', 45, '+15551234567', 'iMessage', NULL);

-- Group chat (style=43).
INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
VALUES (2, 'iMessage;+;chat0000001', 43, 'chat0000001', 'iMessage', 'Test Group');

-- ----- chat_handle_join -----
-- 1:1 chat has both phone and email handles for the same contact.
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1);
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 2);

-- Group has handles 1 and 3.
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 1);
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 3);

-- ----- messages -----
-- 1) Sent message: is_from_me=1, handle_id NULL, MODERN (ns) date,
--    text NULL, attributedBody populated. Exercises the most common
--    modern-chat-db row shape.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (1, 'msg-0001', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_HEX');

-- 2) Received message: is_from_me=0, handle_id=1 (phone), plain text,
--    legacy SECONDS date — exercises the seconds branch and the
--    "handle_id is real" branch.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (2, 'msg-0002', 'legacy reply with text column populated', 1, 0, $SEC_DATE, 'iMessage',
   0, NULL);

-- 3) Received message in group from a different handle (3), modern ns,
--    plain text — exercises group-chat membership lookup.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (3, 'msg-0003', 'group hello from contact 3', 3, 0, $NS_DATE_2, 'iMessage',
   0, NULL);

-- 4) Tapback message: associated_message_type != 0. Must be filterable
--    by predicate associated_message_type = 0.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (4, 'msg-0004-tap', NULL, 1, 0, $NS_DATE_TAPBACK, 'iMessage',
   'bp:msg-0003', 2000, NULL);

-- 5) Highly-reacted target message: a regular message in the 1:1 chat
--    that we'll attach 6 reactions to (2 loves, 1 like, 1 laugh,
--    1 custom-emoji, 1 sticker). Used by ReactionLoaderTests.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (5, 'msg-0005-reactable', 'check this out, big news', NULL, 1, $NS_DATE_REACTABLE,
   'iMessage', 0, NULL);

-- ----- reaction rows (associated_message_type in 2000-2999) -----
-- All target msg-0005-reactable. Mix of senders and types so the tests can
-- assert grouping, kind decoding, the per-sender "latest wins" rule, and
-- the prefix-stripping behavior on associated_message_guid.

-- 6) Love from contact handle 1 (phone). Prefix: p:0/
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (6, 'rxn-0001', NULL, 1, 0, $NS_DATE_TAPBACK_2, 'iMessage',
   'p:0/msg-0005-reactable', 2000, NULL);

-- 7) Love from contact handle 3 (phone). Prefix: p:0/
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (7, 'rxn-0002', NULL, 3, 0, $NS_DATE_TAPBACK_3, 'iMessage',
   'p:0/msg-0005-reactable', 2000, NULL);

-- 8) Laugh from handle 3. Prefix: bp:  (older format)
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (8, 'rxn-0003', NULL, 3, 0, $NS_DATE_TAPBACK_4, 'iMessage',
   'bp:msg-0005-reactable', 2003, NULL);

-- 9) Like from "me" (handle_id NULL, is_from_me=1).
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (9, 'rxn-0004', NULL, NULL, 1, $NS_DATE_TAPBACK_5, 'iMessage',
   'p:0/msg-0005-reactable', 2001, NULL);

-- 10) Custom emoji from handle 1. associated_message_emoji is "🤓".
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, associated_message_emoji,
   attributedBody)
VALUES
  (10, 'rxn-0005', NULL, 1, 0, $NS_DATE_TAPBACK_6, 'iMessage',
   'p:0/msg-0005-reactable', 2006, '🤓', NULL);

-- 11) Sticker reaction (type 2007). No emoji. From handle 3.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (11, 'rxn-0006', NULL, 3, 0, $NS_DATE_TAPBACK_7, 'iMessage',
   'p:0/msg-0005-reactable', 2007, NULL);

-- 12) REMOVED reaction (type 3000). Loader MUST drop this — it's historical.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (12, 'rxn-0007', NULL, 1, 0, $NS_DATE_TAPBACK_8, 'iMessage',
   'p:0/msg-0005-reactable', 3000, NULL);

-- 13) handle 1 switches from custom-emoji to dislike (later date wins).
--     "Latest wins" per-sender rule means rxn-0005 should DROP and this
--     dislike is the active reaction from handle 1.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (13, 'rxn-0008', NULL, 1, 0, $NS_DATE_TAPBACK_9, 'iMessage',
   'p:0/msg-0005-reactable', 2002, NULL);

-- ----- chat_message_join -----
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 1, $NS_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 2, $SEC_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (2, 3, $NS_DATE_2);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (2, 4, $NS_DATE_TAPBACK);
-- The reactable message lives in chat 1 (1:1 with the multi-handle contact).
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 5, $NS_DATE_REACTABLE);
-- Reaction rows are joined to the same chat so chat-scoped tests still work.
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 6, $NS_DATE_TAPBACK_2);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 7, $NS_DATE_TAPBACK_3);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 8, $NS_DATE_TAPBACK_4);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 9, $NS_DATE_TAPBACK_5);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 10, $NS_DATE_TAPBACK_6);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 11, $NS_DATE_TAPBACK_7);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 12, $NS_DATE_TAPBACK_8);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 13, $NS_DATE_TAPBACK_9);

-- ----- indexes (mirror real chat.db enough to keep query plans honest) -----
CREATE INDEX message_idx_date ON message(date);
CREATE INDEX message_idx_handle_id ON message(handle_id);
CREATE INDEX chat_message_join_idx ON chat_message_join(message_id);
SQL

echo "Built: $(pwd)/$DB"
sqlite3 "$DB" "SELECT 'messages: ' || COUNT(*) FROM message;"
sqlite3 "$DB" "SELECT 'chats: ' || COUNT(*) FROM chat;"
sqlite3 "$DB" "SELECT 'handles: ' || COUNT(*) FROM handle;"
