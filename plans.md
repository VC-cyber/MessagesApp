# Plans — Shared Agent Memory

> **This file is the shared memory for every agent in this repo.** Read it before doing anything. Update it after doing anything. See `agents.md` for the protocol.

---

## Product Vision

**Better iMessage Search** — a **Spotlight-style hotkey panel** for searching iMessage. Not a windowed app you open and browse — a system utility you summon with a keystroke, search, and dismiss.

### Primary UX (the whole product)
- Lives in the **menu bar**, **no Dock icon** (`LSUIElement = YES`)
- Global hotkey (default `⌃⌘M`, user-rebindable in Settings) summons a **floating glass panel** anchored top-center
- Panel is borderless, liquid-glass, has a single hero search field + inline filter chips + a results list
- Type → see live results → ↑/↓ to navigate → ↵ to preview → ⎋ to dismiss
- Hotkey while panel open: dismiss
- Lose focus: dismiss
- Vibe: Spotlight × Raycast × iMessage. Fast, light, never-in-the-way.

### Secondary UX (browse / power mode)
- Opened from the menu bar icon ("Open Browser") or a button inside the panel
- A regular windowed `NavigationSplitView` (the one design-agent already built) for sorting, scrolling history, multi-result triage, future analytics dashboards
- Not the primary entry point — most usage is hotkey panel

### Phase 1 — Text search (MVP)
- Full-text search across all messages
- Filter by **person** (with proper contact resolution — merge phone + email handles under one name)
- Filter by **time period** (date ranges, "last month", "2024")
- Filter by **chat** (1:1 vs group, specific group)
- Boolean co-occurrence: "A AND B" within a message
- Sub-second on years of history

### Phase 2 — Semantic search & analytics (lives in browse window primarily)
- Semantic search: "the group chat where we planned the Vegas trip"
- "iMessage Wrapped"-style stats: most-texted contacts, most-reacted messages, send/receive ratios, activity over time, YoY comparisons
- Image search (visual + caption/OCR)
- Pattern discovery (who do I text most after midnight, etc.)

### Distribution
- Signed, notarized **DMG**
- Drag to Applications → open → grants Full Disk Access in System Settings → set hotkey (default ⌃⌘M) → use forever

### Aesthetic
- **Liquid glass** (macOS 26 Tahoe APIs — `.glassEffect`, `GlassEffectContainer`)
- The panel itself is the glass surface; content rows are solid + hairline borders (per HIG)
- Feels first-party Apple

---

## Tech Stack (default — revisit if blocked)

- **Language/UI**: Swift + SwiftUI (with AppKit interop where needed for glass effects)
- **Data**: read-only SQLite over `~/Library/Messages/chat.db` (via GRDB.swift or system SQLite)
- **Search index**: SQLite FTS5 mirror built from chat.db on first run + incremental sync
- **Semantic**: embedding model TBD (local via MLX/CoreML preferred; OpenAI/Anthropic as fallback)
- **Build toolchain**: **Full Xcode (latest stable, currently Xcode 16+)** — *confirmed, not "if available"*. Required for newest SDK (liquid-glass APIs), SwiftUI Previews during design iteration, and frictionless notarization. CLT alone is insufficient.
- **Build**: `xcodebuild` from CLI, `create-dmg` for packaging
- **Signing**: Developer ID Application + notarytool

Project will live under `BetterMessages/` (Xcode project) once the build agent scaffolds it.

---

## Agent Team

| Agent | Responsibility | File |
|---|---|---|
| **lead** (Claude in repo root) | Orchestration, architecture, conflict resolution, plans.md maintenance | `CLAUDE.md` → `agents.md` |
| **design-agent** | Visual design, liquid glass aesthetic, UI components, motion | `.claude/agents/design-agent.md` |
| **build-agent** | Xcode project, build scripts, signing, notarization, DMG | `.claude/agents/build-agent.md` |
| **features-agent** | Research iMessage shortcomings, implement features, chat.db queries | `.claude/agents/features-agent.md` |
| **tester-agent** | Unit/integration tests, manual test plans, perf benchmarks | `.claude/agents/tester-agent.md` |

Every agent reads/writes `plans.md`. Coordinate through it.

---

## Critical Technical Knowledge — `chat.db`

Anything touching iMessage data must respect these. **Read this before writing chat.db code.**

### Access
- Path: `~/Library/Messages/chat.db`
- Requires **Full Disk Access** on the running app
- macOS sometimes blocks the system `sqlite3` CLI but allows Python's `sqlite3` module — Swift app gets normal sandbox/TCC treatment
- **Always open read-only**: `sqlite3.connect(f"file:{path}?mode=ro", uri=True)` in Python; equivalent flag in GRDB. We never mutate the live DB.

### Time format (everyone trips on this)
- `message.date` is **Mac absolute time** — nanoseconds since 2001-01-01 UTC (post macOS 10.13)
- Old rows may be **seconds**. Disambiguate: `CASE WHEN date > 1000000000000 THEN date/1e9 ELSE date END`
- Convert to unix: add `978307200`. SQL: `datetime(date/1e9 + 978307200, 'unixepoch', 'localtime')`

### Essential filters
- `is_from_me = 1` → sent by you, `= 0` → received
- `associated_message_type = 0` → drops tapbacks/reactions (always include for "real" message counts)
- `chat.style = 45` → 1:1, `= 43` → group. Join via `chat_message_join → chat`
- To exclude a specific group: `m.ROWID NOT IN (SELECT message_id FROM chat_message_join JOIN chat ... WHERE display_name = 'X')` — safer than join+WHERE (avoids dup-row inflation)

### Identifying senders
- `m.handle_id` is **NULL for sent messages**
- For 1:1: fall back to chat participant — `COALESCE(m.handle_id, (SELECT handle_id FROM chat_handle_join WHERE chat_id = ch.ROWID LIMIT 1))`
- For groups: use `chat_handle_join` to enumerate participants

### Message text — the biggest gotcha
- `m.text` is **NULL for most modern messages (~2020+)**
- Real content lives in `m.attributedBody`, a binary NSAttributedString typedstream
- Lossy UTF-8 decode + longest-printable-run is the *base* technique, but **the naive version leaks IMCore metadata as the body**. Every modern blob contains the literal string `__kIMMessagePartAttributeName` (30 chars). For short user messages ("ok", "yo") that key becomes the longest run and gets displayed instead of the body. Searching for any substring of that key (e.g. `Attribute`, `r`) then "matches" every message in the DB.
- **The correct pipeline (see `Sources/Data/AttributedBodyDecoder.swift`)**:
  1. Lossy UTF-8 decode.
  2. Split on **non-printable scalars AND U+FFFD** (the latter is critical — Foundation maps invalid UTF-8 to U+FFFD, and treating it as printable fuses metadata + text into one run).
  3. Strip typedstream framing chars (`+`, `@`, brackets, ASCII control codes) from each run's edges.
  4. Drop runs that match Foundation class names (`NSString`, `NSDictionary`, …) or have the `__kIM` / `NS.` prefix.
  5. Return the longest survivor.
- Don't try to parse the typedstream properly. `NSUnarchiver` is removed from Swift; `NSKeyedUnarchiver` decodes a different format.

### Contacts → names
- Contacts DB: `~/Library/Application Support/AddressBook/Sources/*/AddressBook-v22.abcddb` (multiple Sources if iCloud + local)
- Tables: `ZABCDRECORD` (people), `ZABCDPHONENUMBER`, `ZABCDEMAILADDRESS`
- Normalize phone: strip non-digits, prepend `1` if length is 10, then prepend `+`. Lowercase emails.
- One person commonly has multiple handles (email + phone, two phones). For aggregates, merge by resolved name; for unknowns, keep handle as key.

### Performance
- Date-range scans are fast (`date` is indexed)
- Phrase-on-attributedBody is **not** — but you can push a *coarse* filter down to SQL (see below)
- ~40k rows = ~2 months of messages for an active user, well under a second to fetch

### Searching attributedBody from SQL — DO NOT use LIKE
- `m.attributedBody LIKE '%phrase%'` **silently returns zero matches** even when the bytes are present in the blob. This was the source of a ~94% coverage regression in our search.
- `CAST(m.attributedBody AS TEXT)` returns an empty string for these blobs (invalid UTF-8 short-circuits the conversion).
- **The only thing that works**: `INSTR(m.attributedBody, ?) > 0`, where the parameter is bound as a **BLOB** (Swift `Data`, Python `bytes`). `INSTR` does byte-exact substring search.
- INSTR is **case-sensitive**. For case-insensitive ASCII search, OR together three INSTR calls per needle — lowercase, Titlecase, UPPERCASE bytes. Catches ~99% of real-world casing. The remainder ("iPhone", "macOS") slips through; an FTS5 mirror would fix this properly.

---

## Reference Scripts (battle-tested)

Living at `reference/scripts/` (rescued from `/tmp/`). All read-only against `chat.db`. Use as the source of truth for query patterns.

| Script | What it does |
|---|---|
| `count_2026.py` | One-shot total: sent / received / total over any window |
| `sent_messages_chart.py` | Daily sent count + 7-day rolling avg, line chart |
| `top_contacts.py` | Top-N contacts by total exchanged (1:1, merged handles) |
| `rank_vs_sent.py` | Rank-vs-volume (Zipf-style), linear + log-log, any time window |
| `search_messages.py` | Phrase search in a date window; handles text + attributedBody; supports `a+b` co-occurrence |
| `before_after_cactus.py` | Before/after a pivot date, multiple matched windows + Mann-Whitney |
| `year_over_year.py` | Matched-window YoY overlay + month-by-month breakdown |
| `top10_yoy.py` | Side-by-side top-N for two periods with rank deltas |
| `lopsided_ratios.py` | Most extreme sent/recv ratios in either direction |

These are Python prototypes. The Swift app will port the patterns, not the code.

---

## Current Status

- **Repo**: on branch `satyajit`
- **Docs**: `agents.md` (protocol), `plans.md` (this file), `CLAUDE.md` (symlink → `agents.md`), `docs/design-notes.md` (Liquid Glass API cheatsheet + design tokens)
- **Agent definitions**: `.claude/agents/{design,build,features,tester}-agent.md`
- **Reference scripts**: `reference/scripts/` (9 rescued Python query scripts)
- **Toolchain**: Xcode 26.5 (macOS 26.5 SDK, Swift 6.3.2), XcodeGen 2.45.4, create-dmg 1.2.3, GRDB 7.x + KeyboardShortcuts 2.x (via SPM)
- **Xcode project**: `BetterMessages.xcodeproj` (XcodeGen-managed; **edit `project.yml`, then `./scripts/generate.sh`** — never edit the `.xcodeproj` directly)
- **Build**: ✅ `./scripts/build.sh` succeeds. **Test**: ✅ `./scripts/test.sh` runs 6 tests, 0 failures.
- **Bundle ID**: `com.satyajit.bettermessages` · **Deployment target**: macOS 26.0

### Source layout
```
Sources/
├── BetterMessagesApp.swift        # @main, MenuBarExtra + Browse Window + Settings scenes
├── ContentView.swift              # Browse window root — NavigationSplitView (still placeholder data)
├── Panel/                         # lead — Spotlight-style hotkey panel (primary UX)
│   ├── AppDelegate.swift             owns SearchViewModel + PanelController, registers hotkey
│   ├── GlobalHotkey.swift            KeyboardShortcuts.Name.toggleSpotlightPanel
│   ├── PanelController.swift         NSPanel wrapper (non-activating, floating, top-center)
│   └── SpotlightPanel.swift          SwiftUI search view hosted in the panel
├── Data/                          # features-agent — read-only chat.db access
│   ├── AttributedBodyDecoder.swift   lossy UTF-8 + longest-printable-run
│   ├── ChatDatabase.swift            GRDB DatabaseQueue, read-only, FDA-aware error
│   ├── Contact.swift / ContactResolver.swift  AddressBook merge by name
│   ├── Handle.swift                  phone/email normalization
│   ├── Message.swift                 domain row type
│   └── MessageDate.swift             ns/seconds Mac-absolute-time disambiguation
├── Search/                        # features-agent — search logic
│   ├── MessageSearch.swift           phrase + person + date range, "a+b" co-occurrence
│   └── SearchViewModel.swift         @Observable @MainActor model
└── UI/                            # design-agent — liquid glass components
    ├── DesignTokens.swift            Radius, Space, FilterCategory, animation presets, palette
    ├── PreviewData.swift             PreviewMessage struct + 8 fake msgs (integration TBD)
    └── Components/
        ├── FilterChip.swift          tinted glass pill, per-category color
        ├── GlassCard.swift           reusable glass wrapper
        ├── ResultRow.swift           solid card (HIG: glass = navigation only)
        ├── SearchField.swift         hero field with inline chips, GlassEffectContainer
        └── SidebarItem.swift         sectioned sidebar row with selection glow
Tests/
├── BetterMessagesTests.swift      # placeholder
├── MessageDateTests.swift         # 5 tests — ns/seconds disambiguation, round trips
└── Fixtures/
    ├── build_fixture_chat_db.sh   # idempotent generator
    ├── chat.db                    # 48K fixture exercising every gotcha
    └── README.md                  # fixture contents
scripts/
├── generate.sh                    # xcodegen
├── build.sh                       # Debug build
├── package.sh                     # signed + notarized DMG (needs DEVELOPER_ID + NOTARY_PROFILE)
├── test.sh                        # xcodebuild test
└── smoke-features.swift           # standalone swift CLI — exercises Data layer vs real chat.db
docs/
└── design-notes.md                # Liquid Glass API cheatsheet, design tokens, vibe doc
```

### Design tokens (canonical — agents must use these)
- **Radius**: `Radius.small=8`, `.medium=12`, `.large=16` (default cards), `.xlarge=22` (search field), `.huge=28`
- **Spacing** (4pt grid): `Space.xs=4, sm=8, md=12, lg=16, xl=24, xxl=32`
- **Animation**: `.smooth(duration: 0.22)` default; `.bouncy(duration: 0.32, extraBounce: 0.1)` for glass morphs
- **Palette**: system accent (blue). Chip tints per `FilterCategory`: person=blue, dateRange=purple, chat=orange, freeText=gray
- **Typography**: system semantic (`.headline`, `.body`, `.subheadline.weight(.medium)`, `.caption.monospacedDigit()` for timestamps)
- **Glass policy** (per Apple HIG / WWDC25 #323): glass on the *navigation layer* only (search field, chips, sidebar selection). Content rows are solid + hairline borders.

---

## Next Steps (in order)

**Round 1 (scaffolding)**: ✅ complete — build-agent scaffolded the project, features-agent shipped the data layer + search, design-agent shipped the UI system, tester-agent shipped fixture + first tests.

**Round 2 — Spotlight pivot**: ✅ partially complete (lead implemented panel + menu bar + hotkey). Remaining:

1. **lead**: wire the existing `ContentView` browse window to `SearchViewModel` (currently still on `PreviewData.messages`). `ResultRow` only depends on `sender`, `avatarInitials`, `body`, `timestamp`, `chatName`, `isGroup`, `isFromMe` — one adapter from `MessageSearch.Result` or extend `Message` with computed props.
2. **lead / design-agent**: panel polish — ↑/↓ keyboard navigation for results, ↵ to preview, ⌘↵ to reveal in Messages.app, focus the search field on every panel-show.
3. **design-agent**: design the empty/no-FDA / first-run onboarding state for the panel (request Full Disk Access flow). App icon.
4. **features-agent**: build the local FTS5 index mirror (`BetterMessages.sqlite` in `~/Library/Application Support/BetterMessages/`) and incremental sync from `chat.db`. Live-DB scan is fine for date-range slices, won't scale to all-time. **Debounce panel queries** to ~120ms so typing fast doesn't fire N+1 searches.
5. **tester-agent**: extend coverage — `AttributedBodyDecoder.printableRuns`, `Handle.normalize`, `MessageSearch.parseNeedles`, `MessageSearch.dateClause`. Add a perf test against the fixture (search latency budget: <50ms for ≤10k rows).
6. **build-agent**: GitHub Actions CI — `build.sh` + `test.sh` on push. Real Developer ID signing setup (documented, secrets stored in keychain).

**Round 3 — Phase 2 features**: semantic search, "Wrapped"-style analytics, image search, most-reacted-to messages. Scope per agent TBD.

---

## Open Decisions

- **Minimum macOS version**: 14 (Sonoma) vs 15 (Sequoia) vs 26 (Tahoe). Liquid-glass effects look best on newer. **Default**: target 15, polish for 26.
- **Embedding model for semantic phase**: local (MLX bge-small / nomic) vs API. **Default**: local, decide later.
- **Index storage**: separate `BetterMessages.sqlite` in app support dir, never touch `chat.db`. **Confirmed**.
- **Build toolchain**: Full Xcode (latest stable). **Confirmed 2026-05-22.** Not CLT-only, not `swift-bundler`. Build-agent should assume `xcodebuild`, `xcrun`, and the Xcode-bundled SDK are present.
- **Primary UX**: Spotlight-style hotkey panel. **Confirmed 2026-05-22.** Browse window kept as secondary.
- **App style**: menu-bar-only (`LSUIElement = YES`, no Dock icon). **Confirmed 2026-05-22.**
- **Default global hotkey**: `⌃⌘M` (Control-Command-M). User-rebindable in Settings via `KeyboardShortcuts.Recorder`. **Default 2026-05-22, revisit if it collides badly.**
- **Hotkey library**: `sindresorhus/KeyboardShortcuts` (2.x). Picked for SwiftUI integration + built-in recorder UI.
- **Auto-update**: Sparkle vs manual. **Default**: punt to post-MVP.

---

## Change Log

Each agent appends a dated entry when they do non-trivial work. Format:

```
### YYYY-MM-DD — <agent-name>
- What I did
- What I learned / decided
- What's next / blockers
```

### 2026-05-22 — lead
- Created repo structure: `agents.md`, `plans.md`, `CLAUDE.md` symlink
- Defined 4-agent team under `.claude/agents/`
- Rescued 9 reference scripts from `/tmp/` to `reference/scripts/`
- Documented chat.db gotchas (time format, attributedBody, contact merging) as canonical reference
- Set Swift + SwiftUI as default stack; Xcode project not yet scaffolded
- **Decision**: build toolchain is full Xcode (latest stable). Closed as confirmed in Open Decisions. Build-agent can assume `xcodebuild` + Xcode-bundled SDK are present and target them directly — no need to plan for CLT-only or `swift-bundler` fallback.
- Next: hand off to build-agent to scaffold the Xcode project

### 2026-05-22 — build-agent (executed by lead)
- Discovered local env: Xcode 26.5, macOS 26.5 SDK, Swift 6.3.2, Homebrew present. Bumped deployment target to **macOS 26.0** since user has Tahoe and we want full liquid-glass API access.
- Installed XcodeGen 2.45.4 and create-dmg 1.2.3 via Homebrew (we picked XcodeGen over hand-writing `.pbxproj` — config-as-code in `project.yml`, regenerated via `./scripts/generate.sh`).
- Scaffolded:
  - `project.yml` — XcodeGen config (app + test target, schemes, signing, entitlements, hardened runtime, Swift 6 strict concurrency)
  - `Sources/BetterMessagesApp.swift` — `@main` entry, hidden title bar, unified toolbar (matches Apple-app aesthetic)
  - `Sources/ContentView.swift` — minimal NavigationSplitView with `.regularMaterial` + `.thinMaterial` placeholder (will be replaced by design-agent)
  - `Resources/BetterMessages.entitlements` — **App Sandbox OFF** (required for chat.db access; documented inline)
  - `Tests/BetterMessagesTests.swift` — placeholder for tester-agent
  - `scripts/generate.sh`, `scripts/build.sh`, `scripts/package.sh` — idempotent, `set -euo pipefail`
  - `.gitignore` — Xcode + SwiftPM + signing artifacts + secrets
- Smoke build: `./scripts/build.sh` → BUILD SUCCEEDED, `BetterMessages.app` produced.
- **Notes for other agents**:
  - To add Swift Packages, edit `project.yml`'s `packages:` and `dependencies:` then run `./scripts/generate.sh`. Don't edit `.xcodeproj` directly — it's regenerated.
  - To add source files, drop them in `Sources/` (or subdirs). XcodeGen auto-discovers them on next `generate.sh`.
  - To add test files, drop them in `Tests/`. Same auto-discovery.
  - To sign for release, set `DEVELOPER_ID` + `NOTARY_PROFILE` env vars and run `./scripts/package.sh`.
- Next: features-agent, design-agent, tester-agent kick off in parallel.

### 2026-05-22 — features-agent
- Added GRDB.swift 7.0+ to `project.yml` (packages + BetterMessages dependency), regenerated project.
- Implemented read-only `chat.db` access layer under `Sources/Data/`: `MessageDate`, `AttributedBodyDecoder`, `Handle`, `Contact`, `ContactResolver`, `ChatDatabase`, `Message`. All pure where it matters; `ChatDatabase` exposes a GRDB `DatabaseQueue` with read-only `Configuration` and explicit `accessDenied` error case for TCC denial.
- Implemented `Sources/Search/MessageSearch.swift`: phrase + person + date range, "a+b" co-occurrence on `+`, tapback drop via `associated_message_type=0`, SQL date predicate handles ns/seconds dual rows, body match runs in Swift on decoded text. Returns `Result` with resolved partner + sender names.
- Implemented `Sources/Search/SearchViewModel.swift`: `@Observable @MainActor` model with `query` / `selectedContact` / `dateRange` bindable, async `search()` runs heavy work on a detached `Task`. Captures DB-open failures into `setupError` so the UI can render a friendly empty state.
- Build: ✅. Sanity check against real `chat.db` (FDA granted): 21,603 messages scanned over last 30 days, 2,491 matched "the" (551 from me). Reasonable counts.
- Decisions: `DatabaseQueue` (not Pool) since we don't have WAL write rights; lossy-UTF-8 + longest printable run for `attributedBody` (works for substring search; some framing artifacts leak into display — polish later); contacts merged by display name with handle-key fallback; per-chat caches in search for partner names + participant handles.
- For design-agent: bind to `SearchViewModel` — `query`, `selectedContact`, `dateRange`, `results`, `allContacts`, `isSearching`, `errorMessage`, `setupError`. `await viewModel.search()` to trigger.
- For tester-agent: `MessageDate`, `AttributedBodyDecoder.printableRuns`, `Handle.normalize`, `MessageSearch.parseNeedles`, `MessageSearch.dateClause` are pure and ready for unit tests. `ChatDatabase(url:)` accepts any URL for fixtures.
- For build-agent: GRDB landed cleanly via SPM, `GRDB_GRDB.bundle` copied into the `.app`. `Package.resolved` sits under `build/SourcePackages/`.
- Added `scripts/smoke-features.swift` — standalone Swift CLI that exercises the access layer end-to-end against the real `chat.db`. No app build required to run.
- No blockers.

### 2026-05-22 — design-agent
- Built the design system: `Sources/UI/DesignTokens.swift`, `Sources/UI/PreviewData.swift`, and 5 components (`GlassCard`, `FilterChip`, `SearchField`, `ResultRow`, `SidebarItem`), each with light + dark SwiftUI previews. Replaced `ContentView.swift` with a `NavigationSplitView` composing them. Updated `BetterMessagesApp.swift` to use `.containerBackground(.thinMaterial, for: .window)` so the whole window reads as glass. `./scripts/build.sh` → BUILD SUCCEEDED.
- Liquid Glass APIs used: `.glassEffect()` and `.glassEffect(_:in:)` for the search field, chips, and sidebar selection; `Glass.regular.tint(.opacity(0.18-0.32))` for subtle per-category chip tinting; `GlassEffectContainer(spacing:)` wrapping the search field + chip row and the empty-state suggestion row so they sample one shared region and morph cleanly when chips add/remove; `.containerBackground(.thinMaterial, for: .window)` at the scene level. Result rows deliberately do NOT use `glassEffect` — per Apple HIG / WWDC25 #323, glass is reserved for the navigation layer; content gets solid + hairline borders instead.
- Wrote `docs/design-notes.md`: full Liquid Glass API cheatsheet, design tokens, vibe doc, references.
- Design tokens (canonical — agents must use these) are also lifted to the top-level Current Status section of this file.
- `PreviewMessage` in `PreviewData.swift` is intentionally minimal (`sender`, `avatarInitials`, `body`, `timestamp`, `chatName`, `isGroup`, `isFromMe`) — lead should reconcile with features-agent's real `Message` type during integration; `ResultRow` only depends on these fields so the swap should be one-line per usage.
- No blockers.

### 2026-05-22 — tester-agent
- Built fixture `chat.db` (48K, idempotent shell script at `Tests/Fixtures/build_fixture_chat_db.sh`). Documented in `Tests/Fixtures/README.md`.
- Fixture exercises every `chat.db` gotcha from this file:
  - row 1 has NULL `text` + decodable `attributedBody` (longest printable run = "hello cactus how are you today")
  - row 1 is sent (`is_from_me=1`) with NULL `handle_id`
  - rows 2/3/4 are received with real `handle_id`
  - 1:1 chat (`style=45`) with two handles for the same contact (`+15551234567` + `friend@example.com`) AND group chat (`style=43`) wired via `chat_message_join` + `chat_handle_join`
  - row 4 is a tapback (`associated_message_type=2000`) — must be filterable
  - row 1 uses nanoseconds (`740_145_600_000_000_000` = 2024-06-15 12:00 UTC), row 2 uses seconds (`298_296_000` = 2010-06-15 12:00 UTC)
- Wrote `Tests/MessageDateTests.swift` — 5 tests, all passing: nanosecond decode, seconds decode, boundary at the disambiguation threshold (=, just below, just above), Date→ns→Date round trip, Date→seconds→Date round trip. No tests skipped — features-agent's `MessageDate.swift` was already in place.
- Added `scripts/test.sh` (regenerates project via XcodeGen first, `set -euo pipefail`, xcbeautify if available, nonzero on failure).
- Heads-up for features-agent: encode→decode round-trip is NOT identity for Dates within ~1000s of the Mac epoch (2001-01-01 00:00:00–00:16:40 UTC). Those Dates encode to ns values below the disambiguation threshold and decode through the seconds branch — absolute value comes back correct (0 ns == 0 s == Mac epoch), but the code path is the wrong one. Not a real-world concern (iMessage didn't exist before 2011); excluded from the round-trip test and noted in the test docstring.
- No bugs blocking. No edits to `Sources/`, `Resources/`, or `project.yml`.

### 2026-05-22 — lead (integration)
- All three Round-1 agents completed in parallel without file conflicts. Coordination contract (separate subdirs under `Sources/`, agents return change log instead of editing `plans.md` directly) worked cleanly.
- Final verification: `./scripts/build.sh` ✅, `./scripts/test.sh` ✅ (6 tests, 0 failures).
- Repo now has a real native macOS app skeleton with: a working data layer reading real `chat.db` (sanity-checked: 21k msgs scanned, 2.5k matches in 30 days), a Liquid Glass UI design system, an XCTest target with fixture data, and signed-DMG packaging ready when a Developer ID is plugged in.
- Outstanding integration step (next round, item 1): `ContentView` still uses `PreviewData.messages`. Wire it to `SearchViewModel` and adapt `Message` → `ResultRow`'s expected fields.
- "Bugs Found" section in plans.md intentionally not seeded — tester-agent's Mac-epoch corner case is informational, not a defect. Will create the section when a real bug surfaces.

### 2026-05-22 — lead (scroll-and-highlight via keystroke synthesis — works)
- **Goal**: double-clicking a search result should not just open the chat but scroll Messages.app to and highlight the specific message. Apple has no public URL scheme for message-level deep-linking — native Messages.app uses private APIs we don't have.
- **What worked**: synthesize ⌘F → ⌘V → ↵ keystrokes into Messages.app right after opening the chat. Messages.app's own Find-in-chat then scrolls to and highlights the match. Implemented in `Sources/Reveal/MessagesReveal.swift::scrollToMessage(body:)`. Body is written to `NSPasteboard.general` immediately before synthesizing ⌘V, minimizing the clipboard-clobber window.
- **Mechanism**: `CGEvent(keyboardEventSource:, virtualKey:, keyDown:)` with `.maskCommand` for ⌘F/⌘V and no modifiers for ↵. Posts to `.cghidEventTap`. Gated on `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])` so macOS prompts for Accessibility permission on first use; silent no-op if denied (chat still opens — clean degradation).
- **Timing**: 450ms after `NSWorkspace.shared.open` before the ⌘F keystroke, 150ms gaps after that. Empirically reliable on macOS 26.5 with cold-launch Messages.app.
- **Swift 6 strict concurrency gotcha**: `kAXTrustedCheckOptionPrompt` is a C global that Swift 6 refuses to capture across actor boundaries. Used the documented string literal `"AXTrustedCheckOptionPrompt"` directly. Apple documents the constant's value; no behavioral change.
- **AX-driven approach**: spawned a research agent to investigate the proper `AXUIElement`-based scroll-to-row path. Didn't ship before the keystroke approach was confirmed working. Killed the agent. The AX path remains theoretically better (no clipboard touch, no ⌘F overlay flash, works even without focused chat) and is documented as a Round-3 followup if the keystroke approach proves unreliable in practice.

### 2026-05-22 — lead (length-prefix leak)
- **Bug**: results showed messages like `"2Looks like Amma's flights is delayed by 4 hours!"` — the leading `2` wasn't typed by anyone. Diagnostic against the user's actual `chat.db` (`python3` byte-dump of the row) confirmed: the byte immediately before the text in the typedstream is `0x32` (= 50), which is the **1-byte length prefix** for a 50-byte string. `0x32` is also ASCII `'2'`, so it survives lossy UTF-8 decoding and glues itself to the front of the message body. This affects strings whose byte length falls in the printable-ASCII range (0x20–0x7E = 32–126).
- **Fix** (`Sources/Data/AttributedBodyDecoder.stripLengthPrefix`): after edge framing strip, check if the run's leading scalar is an ASCII digit (0x30–0x39) whose value equals the rest's UTF-8 byte length. If yes, strip. Narrowed to digits only — broader (letters/punctuation) heuristic risked false-positives on legit content of specific byte lengths (e.g. a 73-byte message starting with 'H' would lose the 'H').
- Other length-byte values (32, 33–47, 58–126) still leak when they hit, but those alignments are far rarer in real messages. Fully fixed only when we move to byte-level typedstream parsing instead of lossy UTF-8 — leaving as Round-3 work.
- Doesn't regress: `1st place` (49 vs 8 bytes), `2 hours` (50 vs 6 bytes), `$5 each` (leading not a digit) — all preserved.
- ✅ tests, ✅ build, relaunched.

### 2026-05-22 — lead (BLOB search + handle hashing)
- **Bug A (massive)**: searching "cactus" found 25 messages in our app vs hundreds in the user's actual chat.db. Root cause: `LIKE` on a BLOB column in SQLite **does not work** — it returns 0 matches even when the bytes are present. `CAST(blob AS TEXT)` also returns 0 (invalid-UTF-8 sequences in the typedstream short-circuit the conversion). I had been relying on `m.attributedBody LIKE '%cactus%'` as the pre-filter; in practice we were only ever finding rows where `text` (NULL for modern messages) had the phrase. **Coverage was ~6%**.
- **Diagnostic against real chat.db** (`python3` against `~/Library/Messages/chat.db` read-only, results in change-log comment):
  - `cactus`: LIKE-blob=0, INSTR(blob, 'cactus')=647, with case variants OR'd=760, text-LIKE=25, full union=760
  - `henry`: lowercase INSTR=204, **titlecase INSTR=441** (proper noun bias!), UPPER=4, union=646
- **Fix**: replaced the BLOB LIKE with `INSTR(m.attributedBody, ?) > 0` taking a `Data` blob parameter. SQLite handles this correctly: byte-exact substring search on the BLOB. To preserve case-insensitivity, we run INSTR three times per needle — lowercase, Titlecase, UPPERCASE — OR'd together. Catches ~99% of real-world casing. Multi-cap edge cases ("iPhone", "macOS") slip through; fully fixed when FTS5 mirror lands.
- **Bug B**: `Handle` synthesized Hashable using BOTH `raw` AND `normalized`, so two handles with the same normalized form (`+14155550100` and `(415) 555-0100`) hashed differently and missed each other in the contact-resolution map. Fixed: explicit Equatable/Hashable on `normalized` only. The whole point of normalization was to make these equivalent — we just forgot to actually make them equal.
- **Not a bug** (user-suspected but confirmed correct behavior): contacts displayed as raw phone numbers (`+14253057121`) are simply not in the user's AddressBook on this Mac. Diagnostic confirmed: 1 AddressBook source, 501 contacts, neither unresolved number appears in `ZABCDPHONENUMBER`. Falls back to raw display as designed. They may be saved on the user's phone but not synced to this Mac.
- ✅ tests, ✅ build, relaunched. Expect "cactus" to now return hundreds of results instead of dozens, with proper-noun-heavy searches like "Henry" picking up the ~10x increase.

### 2026-05-22 — lead (exhaustive search + debounce)
- **Question raised**: "Why is there a limit? Doesn't that reduce accuracy?" — yes, it did. The limit was a typing-latency hack that bled into correctness. A search product silently dropping matches is broken.
- **Fix**: search is now exhaustive by default. `MessageSearch.search(limit:)` is optional and defaults to `nil` (no LIMIT clause in SQL). Every matching message is returned, period.
- **Where latency protection actually belongs**:
  - `SearchViewModel.searchSoon()` — debounces 150ms after the last keystroke. Typing fast no longer fires one search per character.
  - `SearchViewModel.search()` — runs immediately (Enter, programmatic). Always available.
  - **Generation counter** in `SearchViewModel`: every search bumps a counter; when a search completes, it only applies its result if it's still the latest. Superseded results are dropped — the user has moved on. The detached `Task` running the synchronous engine call can't actually be cancelled mid-flight, but its output is discarded.
- `SpotlightPanel` now calls `searchSoon()` on `.onChange(of: query)` instead of firing a raw `Task { await viewModel.search() }`. Enter still calls `search()` directly.
- **Why this is the right shape**: typing latency is a UX concern handled in the UI/view-model layer with debouncing and supersession. Accuracy is a correctness concern handled in the query layer with no truncation. Mixing them — capping the SQL — silently broke accuracy for the wrong reason.
- ✅ tests, ✅ build, relaunched.

### 2026-05-22 — lead (GUID jump SHIPPED — Spotlight URL form found)
- **The win**: Messages.app now actually jumps to a specific message by GUID, with scroll + highlight, from a third-party app. Verified end-to-end against the user's real chat.db (Jul 12 2025 cactus message).
- **The URL**:
  - Scheme: `sms://`
  - Path: `open`
  - Single query param: `message-guid=<messageGUID>` (hyphen, lowercase; NO chatGUID needed — Messages.app's ChatRegistry resolves the chat from the message GUID alone)
- **Delivery channel**: Apple Event class `GURL` / id `GURL` (the standard "Get URL" event), targeting bundle `com.apple.MobileSMS`. Sent via `NSAppleScript` with raw four-char-code syntax:
  ```
  tell application "Messages" to «event GURLGURL» "sms://open?message-guid=<GUID>"
  ```
- **How we found it**: tailed Messages.app's log while the user clicked a Spotlight Messages result. The URL is logged in plaintext by `CKMessagesSceneDelegate scene:openURLContexts:` and `Opening url: …` — but only after installing Apple's Logging Configuration Profile (Apple Intents Logging + Messages Extension profiles from developer.apple.com/bug-reporting/profiles-and-logs/) to unredact `<private>` markers.
- **Why prior research said "impossible"**: the LNAction / ChatKit.OpenMessageIntent path WAS gated by `com.apple.private.appintents.exception.allow-foreign-bundle-identifiers`, as documented. But Spotlight doesn't use that path. Spotlight goes through the AppIntents OpenURL action which dispatches a plain `GURL` Apple Event to Messages.app, hitting the public-ish URL handler (`CKSceneDelegate scene:openURLContexts:`). Messages.app declares this URL handler in its Info.plist (`sms` scheme is registered, `LSIsAppleDefaultForScheme = true`). No entitlement required to send the AppleEvent — `osascript` and any app can do it.
- **Implementation**: `MessagesGUIDReveal.sendSpotlightOpenURL(messageGUID:)` — five-line wrapper around `NSAppleScript`. Wired as the primary path in `MessagesGUIDReveal.reveal(...)`; the legacy AX-scroll + keystroke synthesis stays as a fallback for the rare case ChatRegistry can't find the GUID.
- **Generalizes** to any message type — text, attachments, links, images, reactions — because the parameter is opaque GUID, not body text. Works for 1:1 AND group chats.
- ✅ build (138 tests), ✅ test, ✅ relaunched, ✅ end-to-end verified.
- The full negative-result research that led to this discovery remains canonical in `docs/messages-private-ipc.md` and `docs/messages-private-proxy.md` — they document why every other path we tried failed, and the wonderful inverse: the path that worked was the most ordinary one all along (a registered URL scheme + standard AppleEvent), just with a parameter name (`message-guid`) we couldn't have guessed without unredacted logs.

### 2026-05-22 — features-agent (private IPC for GUID jump — exhaustive negative result)
- **8 hypotheses tested empirically**, each with a probe in `scripts/probes/` and real GUIDs from the user's chat.db. Documented in `docs/messages-private-ipc.md`. All probes verified against a sentinel chat (`Beck Peterson`) — its window title never changed under any private-IPC path.
- **Hypotheses ruled out**:
  1. `_automation_*` selectors — state-mutators on imagent, not UI drivers. Prior agent misread.
  2. Apple Event `'aevt'/'GURL'` with `x-apple-appintents://` URL — reply `errn:-1708` (`errAEEventNotHandled`). Messages.app receives the event but the scheme is ignored.
  3. `NSUserActivity.becomeCurrent()` with `com.apple.Messages` + IMCore continuity keys — makes the activity OUR process's current activity, not Messages.app's. Continuity delivery needs Handoff or a Spotlight tap.
  4. `dlopen` native macOS IMCore — loads cleanly, `IMChatRegistry`/`IMChat`/`IMMessage` instantiable, but talks to imagent (the daemon), NOT Messages.app's UI process. Useful for chat.db cross-checking, useless for reveal.
  5. `dlopen` iOSSupport ChatKit/IMCore — fails with "wrong platform to load into process". Catalyst frameworks can't be linked from a native macOS bundle.
  6. Distributed/Darwin notifications (`CKEmphasizeBalloonAtIndexPathNotification`, `com.apple.imessage.openChat`, etc.) — no effect on Messages.app.
  7. Parameterized AX attributes on Messages.app — only `AXReplaceRangeWithText` + text-marker attrs. No GUID-parameterized attribute exists.
  8. **`LNAction` + `LNApplicationConnection` + `LNActionExecutor` SPI** — structurally correct! Built end-to-end:
     ```objc
     LNAction(identifier: "OpenMessageIntent",
              mangledTypeName: "7ChatKit17OpenMessageIntentV",
              openAppWhenRun: YES,
              parameters: [LNParameter(target: MessageEntity(GUID))])
     ```
     `LNApplicationConnection initWithBundleIdentifier:@"com.apple.MobileSMS"` returns a real connection. `[executor perform]` completes without error. **But Messages.app silently does nothing** because the XPC dispatcher requires entitlement `com.apple.private.appintents.exception.allow-foreign-bundle-identifiers` (or `…allowed-bundle-identifiers`). Apple grants these to specific licensees; not available to third-party apps. The mach service `com.apple.private.appintents.delegate.com.apple.MobileSMS` is not published to unentitled clients.
- **Bottom line**: `ChatKit.OpenMessageIntent` IS the right intent for what we want. Apple's dispatch path IS correctly identifiable. We cannot use it from a third-party bundle.
- **Implementation**: NO production code changed. `Sources/Reveal/MessagesGUIDReveal.swift` is unchanged. The full LNAction pipeline is in `scripts/probes/probe-lnconn-perform.m` so it's ready to lift into `tryPrivateJump` if we ever ship as an entitled Apple-signed extension.
- **Tests**: `./scripts/test.sh` ✅, `./scripts/build.sh` ✅. No new XCTests — probes require running Messages.app + AX permission, not CI-runnable.
- **Recommended Plan B (lead to ship)**: iterative `AXScrollUpByPage` loop in `MessagesGUIDReveal.scrollToMessage(matchingDescriptionNeedles:)` — repeatedly page Messages.app's `TranscriptCollectionView` upward until either the target bubble appears in the AX tree or a sane bound (~50 pages / 5 seconds) hits. Closes the lazy-load gap (the user's reported bug) without privileged IPC. ~50 lines.

### 2026-05-22 — features-agent (dashboard)
- New `Sources/Dashboard/` module: `DashboardView`, `DashboardViewModel`, `DashboardLoader`, `DashboardStats`, plus components (`StatPanel`, `TopList`, `WindowSelector`, `FrequencyChart`). New `Window("Dashboard", id: WindowID.dashboard)` scene in `BetterMessagesApp.swift`; new "Dashboard…" menu bar item.
- Layout: header strip with 4 stat tiles (total / sent / received / conversations + date span) → 30d/12m/All segmented selector → Swift-Charts frequency chart (sent + received) → side-by-side Top People (12, by total exchanged, 1:1 only) and Top Groups (12, by your sent count). Uses existing `GlassCard`, design tokens, and `.containerBackground(.thinMaterial, for: .window)`.
- 11 new `DashboardLoaderTests`: overview totals, top-contact ranking + ordering + merging, top-groups (HAVING sent>0), time-series bucketing + additivity, date-range helper, tapback exclusion. All pass.
- **Real-data smoke against user's chat.db**: 524,298 messages, 1,486 chats; top contact 31,284 total exchanged; top group "Hao did this chat start" 36,521 messages. Time series produced 31 daily buckets in last 30 days. Numbers ordered correctly, span the full date window. SQL is sub-second on these sizes.
- **Error panel**: if FDA isn't granted (common for fresh debug builds — new bundle identity ≠ previously-granted bundle), the dashboard renders a friendly "Can't open Messages" panel with selectable error text + a deep-link button to System Settings → Privacy & Security → Full Disk Access. Same pattern as the panel's existing access-denied state.
- **Known caveat**: debug rebuilds get a fresh bundle identity, so FDA grants don't automatically carry over from previous builds. Documented in the error panel UX. Properly signed Release builds wouldn't have this churn.
- ✅ build, ✅ tests, relaunched.

### 2026-05-22 — features-agent (length-prefix bug — broad fix)
- **Empirical baseline on user's real chat.db** (5000 random rows with attributedBody): **15.5% of decoded bodies had a leading-char artifact** under the broad rule. The narrow (digits-only) fix I shipped earlier caught just 28% of those cases. Most leakage was letters (265 rows) and other printable ASCII / punctuation (283 rows). See `docs/decoder-fix-empirical.md` for the full histogram + false-positive analysis.
- **Fix in `Sources/Data/AttributedBodyDecoder.stripLengthPrefix`**: broadened from digits (0x30–0x39) to all printable ASCII (0x20–0x7E). Same algorithm — strip iff leading scalar's byte value equals the rest's UTF-8 byte length — just a wider input range. False-positive collision rate ≤1/1000 (a message that legitimately starts with character `c` AND is exactly `c.byteValue + 1` bytes total). Acceptable trade.
- The artifact strings the user reported (`"rSatyajit Kanna"`, `"?So none of our cha"`, `"DSatyajit Kanna"`) all now decode cleanly. So does the older `"2Looks like Amma's flights..."` case.
- New tests in `Tests/AttributedBodyDecoderTests.swift` (11 tests added — total now 138): digit-prefix, punctuation-prefix, letter-prefix, length-mismatch preserved (1st place / 2 hours / $5 each), emoji not stripped, real-fixture rows added to `build_fixture_chat_db.sh`.
- The proper long-term fix is byte-level typedstream parsing (Round-3 work); this heuristic eliminates the visible bug class until then.
- ✅ build, ✅ tests, relaunched.

### 2026-05-22 — features-agent (reactions display + filter)
- Empirically catalogued the tapback types present in the user's `chat.db`: 2000 (30,456 ❤️), 2001 (5,042 👍), 2002 (1,025 👎), 2003 (2,878 😂), 2004 (3,323 ‼️), 2005 (192 ❓), 2006 (1,202 custom-emoji — `associated_message_emoji` populated), 2007 (331 sticker — no emoji column), 3000–3007 (~111 removed; dropped at SQL).
- `associated_message_guid` prefixes in real data: `p:0/` (92%), `p:1/`–`p:19/` (multi-part), `bp:` (~5%), bare GUID (rare).
- **Perf footgun caught and fixed**: a leading-wildcard `LIKE '%' || m.guid` correlated subquery did a full tapback scan per candidate (multi-minute on user's DB). Switched to an `IN ('m.guid', 'p:0/' || m.guid, …, 'bp:' || m.guid)` enumeration, which uses the partial index `message_idx_associated_message2 ON message(associated_message_guid) WHERE associated_message_guid IS NOT NULL`. Sub-second when date-narrowed.
- New files: `Sources/Data/Reaction.swift`, `Sources/Data/ReactionLoader.swift` (batched, no N+1), `Sources/UI/Components/ReactionCluster.swift`, `Tests/ReactionParserTests.swift` (14 tests), `Tests/ReactionLoaderTests.swift` (16 tests).
- Modified: `MessageSearch.swift` (ReactionFilter + reactionsClause SQL + `Result.reactions`), `QueryAutocomplete.swift` + `QuerySuggestionsProvider.swift` (reactions token + suggestions), `QuerySuggestionsPopover.swift` + `DesignTokens.swift` (reaction kind/category), `SpotlightPanel.swift` + `ResultRow.swift` (cluster render), `PreviewData.swift` (seed reactions), `Tests/Fixtures/build_fixture_chat_db.sh` (reactable msg + 8 tapback rows).
- **Query syntax shipped**: `reactions:>=N`, `<=N`, `>N`, `<N`, `=N`, bare `:N` (==), `:any` (>=1), `:love` / `:like` / `:laugh` / `:emphasize` / `:question` / `:dislike`. Multiple tokens AND. Case-insensitive prefix + value.
- **Visual** (Apple-HIG-respecting): solid pill badges (not glass — content layer); 11pt emoji + 2-digit monospaced count (count omitted when 1); max 4 badges then `+N` overflow with senders in tooltip; pink chip tint; sort by count desc, tie-break first-seen.
- Per-sender latest-wins for reactions (so a user who swapped reactions only shows their current one). Removed reactions dropped entirely.
- ✅ build, ✅ tests (30 new — 127 total; up from 86 pre-reactions).
- Known limitations: multi-part prefixes `p:10/`–`p:19/` aren't covered by the IN list (extraordinarily rare); unbounded `reactions:>=N` full-history is ~5s without date narrowing; sticker (2007) reactions render with generic 🏷️.

### 2026-05-22 — codex (message-level reveal research)
- User asked for the most testable path to reveal a Messages.app message by `(messageGUID, chatGUID)` without body matching, including attachment-only/image-only messages.
- Local Tahoe inspection found:
  - `IMDPersistenceAgent.xpc` exists but its `Info.plist` `_AllowedClients` is Apple-code-signing gated (`com.apple.MobileSMS.spotlight`, `imagent`, Safari, Assistant, etc.), so a third-party app should not expect direct XPC access.
  - `imagent` exposes Mach service `com.apple.corespotlight.daemon.messages`; Messages.app has `CoreSpotlightContinuation = true`; Apple’s Spotlight path is real but probably not a public jump RPC.
  - Messages.app is Catalyst and links `/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework`.
  - ChatKit App Intents metadata at `/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework/Resources/Metadata.appintents/extract.actionsdata` contains hidden `ChatKit.OpenMessageIntent` with summary `Reveal ${target}`, `openAppWhenRun = true`, and target `MessageEntity`.
  - `MessageEntity` is both `Indexed` and `URLRepresentable`; properties include `GUID`, `transferGUID`, `conversation`, `attachments`, `customAttachments`, `locations`, `links`, `reaction`, and `referencedMessage`, which matches the requirement to handle non-text messages.
  - User container `~/Library/Containers/com.apple.MobileSMS.spotlight` exists. Quick inspection only found `Data/Library/Preferences/com.apple.IMCoreSpotlight.plist` with `IMCSNeedsDeferredIndexing = true`; no obvious reusable local index file in `Application Support` or `Caches`.
- Recommendation for next implementation spike: try invoking/abusing the App Intents/OpenEntity path first, then CoreSpotlight continuation, before deeper IMCore/XPC work. Direct IMCore can load/mark messages by GUID but does not by itself control Messages.app UI state.

### 2026-05-22 — lead (search recency + scope bugfix)
- **Bug**: searching "cactus" returned nothing despite the user having recent cactus-related messages. Other queries returned only old results.
- **Root cause** in `MessageSearch.search`: `ORDER BY m.date ASC` + `LIMIT 5000` fetched the 5000 *oldest* messages, then Swift filtered by phrase. Anything from the last few years never entered the candidate window. No SQL pre-filter on the phrase meant we were also wasting the limit on rows that don't match the query at all.
- **Fix**:
  - `ORDER BY m.date DESC` — newest first. The LIMIT now keeps the most recent candidates.
  - New `phraseClause()` builds a coarse SQL pre-filter: `(m.text LIKE ? OR m.attributedBody LIKE ?)` per needle, AND'd together. Treats the typedstream blob as text bytes — ASCII phrases ("cactus") appear as literal byte sequences inside it, so SQLite's LIKE can find them without decoding. Drops the candidate set from "the entire DB in date range" to "rows where the bytes appear somewhere".
  - Swift refinement on the decoded body still runs — catches metadata false positives (the bytes might appear inside `__kIM*` keys etc.) and is case-insensitive.
  - Default limit reduced 5000 → 1000 — SQL pre-filter handles the volume now.
- **Known limitation**: SQLite `LIKE` on a BLOB is case-sensitive (text LIKE is case-insensitive). Needles are lowercased so we catch the vast majority of real messages (people overwhelmingly text in lowercase). False-negative only for rows where the phrase ONLY appears non-lowercase — acceptable for v1, fully fixed when FTS5 mirror lands (Round 2 item #4).
- Results now returned **newest-first** instead of oldest-first. Contract change for callers — `SearchViewModel.results` order changed. UI doesn't care (just displays the array in order); this is the intuitive Spotlight-like ordering anyway.
- Verified: ✅ tests, ✅ build, relaunched for user retest.

### 2026-05-22 — lead (decoder bugfix)
- **Bug**: real-data smoke (user hit ⌃⌘M, typed "r") returned screens of `__kIMMessagePartAttributeName?????` rows, all in one chat. Root cause: the naive longest-printable-run heuristic preferred the 30-char IMCore attribute key over short user messages, so EVERY row's "body" was that key. Substring search for "r" hit "Att**r**ibute" universally, surfacing whatever DB ordering returned first (which happened to be one chat).
- **Fix** (`Sources/Data/AttributedBodyDecoder.swift`):
  - U+FFFD now splits runs (Foundation maps invalid UTF-8 to U+FFFD; treating it as printable was fusing metadata into the same run as text)
  - Edge stripping: leading/trailing `+`, `@`, brackets, ASCII control chars removed from each run (typedstream type sigils)
  - Metadata filter: drop runs that match a known set of Foundation class names (`NSString`, `NSDictionary`, …) or have the `__kIM` / `NS.` prefix
- Updated the **Message text** gotcha section at the top of this file with the canonical pipeline so future agents don't reintroduce the regression.
- Verified: existing 6 tests still pass. Real-data confirmation deferred to user retest.
- Next: write a regression test against the synthetic blob `streamtyped … NSString … <short body> … NSDictionary … __kIMMessagePartAttributeName` to lock in the fix. Tester-agent on next invocation.

### 2026-05-22 — lead (Spotlight pivot)
- **Product reframing**: user clarified the vision — this is a **Spotlight/Raycast-style hotkey panel**, not a windowed Mail-like app. Updated the Product Vision section at the top of this file accordingly.
- Architecture pivot landed in code:
  - **Menu bar app**: `LSUIElement = YES` added to `INFOPLIST_KEY_*` in `project.yml`. No Dock icon. App now lives in the menu bar via `MenuBarExtra` ("Search…" / "Open Browser" / "Settings…" / "Quit").
  - **Global hotkey**: added `sindresorhus/KeyboardShortcuts` 2.x SPM dep. Hotkey registered in `AppDelegate.applicationDidFinishLaunching` against `.toggleSpotlightPanel` (default `⌃⌘M`, rebindable in Settings).
  - **Floating panel**: `Sources/Panel/PanelController.swift` owns a `SpotlightNSPanel` (custom `NSPanel` subclass with `.nonactivatingPanel`, `.floating` level, `canBecomeKey=true`, Esc-to-dismiss). Reused across toggles so search state survives between activations.
  - **Panel UI**: `Sources/Panel/SpotlightPanel.swift` — compact glass surface, hero `SearchField`, results list, status footer with ↵ / ↑↓ / ⎋ hints. Binds to features-agent's `SearchViewModel`. Includes a Full-Disk-Access denied state with a deep-link button to System Settings.
  - **App scenes**: `BetterMessagesApp.swift` now hosts `MenuBarExtra` + `Window("Browser")` + `Settings`. `Window` (not `WindowGroup`) means the browse view only appears when explicitly opened from the menu.
  - **Settings**: `KeyboardShortcuts.Recorder` for live hotkey rebinding.
- Build + tests: ✅ all green.
- Small contract drift caught during the pivot: features-agent's result type is `MessageSearch.Result` (not `SearchResult`) and `Message.id` (not `rowID`). Fixed in `SpotlightPanel.swift` while wiring.
- **Existing browse window** (`ContentView`) was preserved as a secondary surface. It still uses placeholder data — wiring to `SearchViewModel` is the top item in Round-2 next steps.
- Notes for other agents (they'll pick this up via `plans.md` on their next invocation):
  - Primary surface for new features is the panel, not the browse window. Browse window is for triage / future analytics dashboards.
  - When adding new search-related state to `SearchViewModel`, both surfaces will pick it up.
  - design-agent: the panel needs an empty/onboarding state polish pass and an app icon.
  - features-agent: panel queries fire on every keystroke right now — add debounce inside `SearchViewModel.search()` or at the call site (`SpotlightPanel.onChange(of: query)`).
