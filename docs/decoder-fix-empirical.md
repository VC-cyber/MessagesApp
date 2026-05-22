# Empirical Baseline — typedstream length-prefix leak

Snapshot of the data behind the broadened `AttributedBodyDecoder.stripLengthPrefix`
fix (features-agent, 2026-05-22). Run script: `scripts/probes/diagnose_length_prefix.py`.

## Setup

- Source: user's real `~/Library/Messages/chat.db` (read-only).
- Sample: 5000 random rows with non-NULL `attributedBody`.
- Pipeline: replicates the Swift `AttributedBodyDecoder` (lossy UTF-8 decode →
  printable-run split (incl. U+FFFD as separator) → edge-framing trim →
  metadata filter → longest survivor). Length-prefix removal is the only
  step intentionally skipped — we measure the leak.

## Headline numbers

| Metric                                                  | Count  |
|---------------------------------------------------------|--------|
| Bodies successfully decoded                             | 4919   |
| Bodies with leading-char artifact (broad rule)          | 764    |
| **Artifact rate**                                       | **15.5%** |

The narrow (digits-only) fix already in place catches **216 of those 764
(28%)**. The broadened rule catches the rest:

| Category                                | Caught by narrow fix | Caught by broad fix only |
|-----------------------------------------|----------------------|--------------------------|
| ASCII digits 0-9 (0x30–0x39)            | 216                  | 0                        |
| ASCII letters A-Z / a-z (0x41–0x5A, 0x61–0x7A) | 0             | 265                      |
| Other printable ASCII (space, punctuation, symbols) | 0       | 283                      |

In other words: **548 of 764 (72%) leaks fall outside the narrow rule**, and
the bug reported by the user (`rSatyajit…`, `?So none…`, `DSatyajit…`) is
literally three of those 548.

## Histogram (top 30)

Each leaked byte value `v` corresponds to a message whose body is exactly
`v` bytes long (after the length prefix). Spread looks like the distribution
of short-to-medium iMessages, with quoted-text glyphs (`"`, `'`), dashes
(`-`), and commas (`,`) at the head of the list because of natural
sentence/quote starts in the typedstream encoding (and because most
"Liked/Loved/Emphasized…" tapback-quoting messages have very predictable
byte lengths).

```
v= 34 '"' (other ): 46 messages, msg-byte-len=34
v= 45 '-' (other ): 44 messages, msg-byte-len=45
v= 39 ''' (other ): 36 messages, msg-byte-len=39
v= 44 ',' (other ): 34 messages, msg-byte-len=44
v= 49 '1' (digit ): 32 messages, msg-byte-len=49
v= 65 'A' (letter): 30 messages, msg-byte-len=65
v= 47 '/' (other ): 29 messages, msg-byte-len=47
v= 50 '2' (digit ): 28 messages, msg-byte-len=50
v= 46 '.' (other ): 28 messages, msg-byte-len=46
v= 48 '0' (digit ): 23 messages, msg-byte-len=48
v= 54 '6' (digit ): 23 messages, msg-byte-len=54
v= 51 '3' (digit ): 22 messages, msg-byte-len=51
v= 56 '8' (digit ): 20 messages, msg-byte-len=56
v= 55 '7' (digit ): 20 messages, msg-byte-len=55
v= 58 ':' (other ): 20 messages, msg-byte-len=58
v= 57 '9' (digit ): 18 messages, msg-byte-len=57
v= 61 '=' (other ): 17 messages, msg-byte-len=61
v= 67 'C' (letter): 17 messages, msg-byte-len=67
v= 70 'F' (letter): 16 messages, msg-byte-len=70
v= 79 'O' (letter): 15 messages, msg-byte-len=79
v= 52 '4' (digit ): 15 messages, msg-byte-len=52
v= 53 '5' (digit ): 15 messages, msg-byte-len=53
v= 66 'B' (letter): 14 messages, msg-byte-len=66
v= 63 '?' (other ): 13 messages, msg-byte-len=63  ← user-reported "?So none…"
v= 77 'M' (letter): 11 messages, msg-byte-len=77
v= 74 'J' (letter): 9 messages, msg-byte-len=74
v= 71 'G' (letter): 9 messages, msg-byte-len=71
v= 75 'K' (letter): 9 messages, msg-byte-len=75
v= 76 'L' (letter): 8 messages, msg-byte-len=76
v= 85 'U' (letter): 8 messages, msg-byte-len=85
```

The user's specific screenshot artifacts were directly located and confirmed
by lookup against the full DB (not just the 5000-sample):

- `ROWID=534149 (D=68)` → "DSatyajit Kanna, how does Turboquant release by Google affect Cactus?" — rest is exactly 68 bytes.
- `ROWID=548986 (?=63)` → "?So none of our chats are private. Should we use cactus instead?" — rest is exactly 63 bytes.
- `ROWID=554092 (r=114)` → "rSatyajit Kanna, you're getting paid $4,254 (post tax) every quarter from Cactus while you study! Pr…" — rest is exactly 114 bytes.

All three would be cleaned by the broadened rule.

## Spot-check (30 random)

Reproducing 30 random artifacts; every one is unambiguously a length-prefix
leak (the leading char doesn't fit the sentence, the rest reads
coherently).

```
ROWID=    9480 leadByte= 67 ('C'): 'CLoved "I'm posting that video on my story again for clout…"'
ROWID=  370006 leadByte= 39 ('\''): "'But I think the name might have changed"
ROWID=  141275 leadByte= 89 ('Y'): 'YI'm at the southeast end of the building and the line runs across to the southwest side'
ROWID=   98874 leadByte= 89 ('Y'): 'YThanks a lot appa I personally vouch for him he's not some random senior just so u know'
ROWID=   36946 leadByte= 51 ('3'): '3His problem solving skills are good but not amazing'
ROWID=  116938 leadByte= 47 ('/'): '/Nah bro I'm the rollercoaster mason riding me'
ROWID=  467111 leadByte= 45 ('-'): '-He doesn't think much he'll prob be there'
ROWID=  168404 leadByte= 57 ('9'): '9Bc he was trying to stash changes he made in wrong branch'
ROWID=  209899 leadByte= 76 ('L'): 'LShe said "this is my fault and you have been amazing through everything"'
ROWID=  161038 leadByte= 48 ('0'): '0I mayyyy be but ofc I'll give u ur antibiotics'
ROWID=  301923 leadByte= 34 ('"'): '"And then missed the date by a week'
ROWID=   86380 leadByte= 47 ('/'): '/Remember if we help them close —> we get paid'
ROWID=  102443 leadByte= 61 ('='): '=Like don't spend too much time on theory get the basic idea'
ROWID=  453536 leadByte= 61 ('='): '=Is calm imma try my best on the second one should be more fun'
ROWID=   73593 leadByte= 52 ('4'): '4I was thinking it might be safer to make pitch today'
ROWID=  389918 leadByte= 34 ('"'): '"well lemme tell u some facts first'
ROWID=  238880 leadByte= 61 ('='): '=Loved "Yeah exactly I think u should ask khush or Claire"'
ROWID=  396918 leadByte= 63 ('?'): '?bc so far, turning 18 has been the only thing keeping me at bay'
ROWID=  516284 leadByte= 68 ('D'): 'DStaying in bed til 1:20 is lowkey not gonna make you feel any better'
ROWID=  309986 leadByte= 67 ('C'): 'CWow my rnb playlist at 800 songs thx for putting me onto Brent chat'
ROWID=  355806 leadByte= 83 ('S'): 'SIt's acc tragic we don't live closer together I wish we went to the same school'
ROWID=  518792 leadByte= 46 ('.'): '.Loved "Yo i got a selfie with shamakinusa"'
ROWID=   16060 leadByte= 90 ('Z'): 'ZYea thank u idt I could handle this as well as the quant meeting and everything else lmfao'
ROWID=  240715 leadByte= 45 ('-'): '-I mean yall never even had a chance in fall q'
ROWID=  261689 leadByte= 74 ('J'): 'JI feel like diffusion is almost like a more native way to capture thoughts'
ROWID=  159145 leadByte= 56 ('8'): '8I got the idea from another pose forecasting paper lmfao'
ROWID=  497723 leadByte= 51 ('3'): '3Loved "Hello we will be calling about sponsors"'
ROWID=   20836 leadByte= 82 ('R'): 'RI have stuff to present but if there is no one to present to it's not my problem'
ROWID=  510310 leadByte= 61 ('='): '=wait didn't you say the team is down for the 3 week sprint?'
ROWID=  253630 leadByte= 34 ('"'): '"Mhm definitely know what those are'
```

## False-positive analysis

The script's narrow false-positive heuristic flagged 262 cases where the
artifact LOOKS like it could plausibly be legit content (leading letter
followed by another letter or punctuation — i.e. a single capital letter
that could start a real sentence/word/name).

**Reviewing all 262 by eye**: every single one read as a length-prefix
leak, not content. Pattern examples:

- `'MIm telling you shreya…'` — clearly `Im telling you…` with M=78 prefix
- `'FShit it might be…'` — clearly `Shit it might be…` with F=70 prefix
- `'jLoved "Hey Sat…"'` — clearly a tapback quote with j=107 prefix
- `'Mat_CA3AF36D-…-FB17E4452ADC'` — attachment GUID, `at_…` is the real payload, M=78 prefix
- `'AOut of curiosity, Do we have any say…'` — clearly `Out of curiosity` with A=66 prefix

There is exactly one theoretically-ambiguous case in the 262:

- `'AA man who's been starving can't be blamed for eating a little'` (ROWID
  554921, rest byte-len 65 = 'A' = 65). The fix would interpret this as
  prefix-A + body "A man who's been starving…" — which is the natural reading.
  If 'A' were legitimately part of the content, the original would have
  been "AA man who's…" which is much less plausible. Either way the displayed
  result reads sensibly; the fix is at worst neutral here.

True positives outnumber the only ambiguous candidate by ~764:1 in this
sample. Real-world incidence of false positives is therefore well below 1
per 1000 messages, while the bug currently affects ~15% of messages.
Broadening the rule is unambiguously the right call.

## Conclusion

Broaden `stripLengthPrefix` from "ASCII digits only" to "any printable
ASCII byte (0x20-0x7E)". Keep the strict length match: `rest.utf8.count == v`.

False-positive risk is bounded by the joint probability of:
1. Message content legitimately starting with byte `c` whose value is in
   the printable-ASCII range, AND
2. The rest of the body being EXACTLY `c` bytes long.

That conjunction is rare in absolute terms (≤1 per 1000 messages in our
sample), and even in the rare hit, the displayed result is almost always
the intended one (the prefix would only have been doubled-up otherwise).

The proper long-term fix is byte-level typedstream parsing (defer to
Round-3). For now, this heuristic eliminates the visible bug class.

## Post-fix verification

Reran the diagnostic against a fresh 5000-message sample, simulating both
the original (broken) decoder and the new broadened-strip decoder.
Script: `scripts/probes/diagnose_length_prefix_after.py`.

| State                                | Artifacts | Rate    |
|--------------------------------------|----------:|---------|
| Before broad fix (digit-only strip)  |      807  | 16.36%  |
| After broad fix                      |        6  |  0.12%  |
| Reduction                            |    **801** | **134x** |

The 6 residual hits are all "double-prefix" leaks — the typedstream blob
has two nested length-prefix bytes, and stripping the outer one exposes
the inner. Example: ROWID 44891 originally `"JI have literally nothing..."`,
after one strip `"I have literally nothing..."` (the displayed result is
correct user content). The detector still flags these as residual because
'I' (=73) happens to equal the rest's byte length post-strip — that's a
counting artifact, not a real bug. We deliberately do NOT loop the strip
in production because real legit content starting with single-byte
length-aligned chars would then chain-strip until the body is empty.

The three user-reported strings from the original screenshot were
verified directly against `chat.db` post-fix:
- `ROWID 534149` → `"Satyajit Kanna, how does Turboquant..."` (D=68 prefix stripped)
- `ROWID 548986` → `"So none of our chats are private..."`  (?=63 prefix stripped)
- `ROWID 554092` → `"Satyajit Kanna, you're getting paid..."` (r=114 prefix stripped)

All three now decode cleanly.
