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

-- ----- chat_message_join -----
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 1, $NS_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 2, $SEC_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (2, 3, $NS_DATE_2);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (2, 4, $NS_DATE_TAPBACK);

-- ----- indexes (mirror real chat.db enough to keep query plans honest) -----
CREATE INDEX message_idx_date ON message(date);
CREATE INDEX message_idx_handle_id ON message(handle_id);
CREATE INDEX chat_message_join_idx ON chat_message_join(message_id);
SQL

echo "Built: $(pwd)/$DB"
sqlite3 "$DB" "SELECT 'messages: ' || COUNT(*) FROM message;"
sqlite3 "$DB" "SELECT 'chats: ' || COUNT(*) FROM chat;"
sqlite3 "$DB" "SELECT 'handles: ' || COUNT(*) FROM handle;"
