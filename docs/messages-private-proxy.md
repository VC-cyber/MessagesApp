# Messages.app GUID-reveal via privileged proxies

Continuation of `docs/messages-private-ipc.md`. The prior investigation
concluded that `ChatKit.OpenMessageIntent` is the right intent and that we can
construct an `LNAction` end-to-end from our process, but the XPC dispatcher
silently drops the call because we lack
`com.apple.private.appintents.exception.allow-foreign-bundle-identifiers`.

**Hypothesis for this round**: the entitlement is checked on the *caller*.
Apple's own daemons (Shortcuts.app, coreservicesd, the Spotlight handler) DO
have the entitlement and can invoke ChatKit's hidden intent. Can we induce one
of them to call it on our behalf?

macOS 26.5 (Tahoe), Messages.app `1450.500.221.1.7`, Shortcuts.app `7.0`.
Testing date 2026-05-22.

## Five hypotheses

| # | Path | Result |
|---|------|--------|
| A | `/usr/bin/shortcuts` CLI — install/run a `.shortcut` that calls `OpenMessageIntent` | TBD |
| B | `shortcuts://run-shortcut?name=…&input=…` URL scheme dispatch | TBD |
| C | Direct XPC to Shortcuts.app's mach services (LNAction via Shortcuts) | TBD |
| D | `CSSearchableItem` publish + `NSWorkspace.open` of `x-apple-appintents://…` URL through Spotlight | TBD |
| E | `NSUserActivity` + LaunchAgent / utility plug-in (privileged donate) | TBD |

Status filled in below as each is tested.

---

## Hypothesis A — Shortcuts CLI

(see `scripts/probes/proxy-shortcuts-cli.sh`)

### A.1 — Basic `shortcuts run` works

Verified that the CLI is functional:
```
$ shortcuts list
Show me where Kaus Meridionalis is.
New Shortcut
Hey Google
...
```

### A.2 — The Shortcut binary plist format

User's existing shortcuts live in `~/Library/Shortcuts/Shortcuts.sqlite` →
`ZSHORTCUTACTIONS.ZDATA`. The format is a binary plist of `WFWorkflowAction`
dicts, each with `WFWorkflowActionIdentifier` (e.g. `is.workflow.actions.sendmessage`)
and `WFWorkflowActionParameters`.

The signed `.shortcut` file (importable / shareable) is a separate signed
container. Format: signed by Apple via `shortcuts sign --mode anyone`, locally
signed via `--mode people-who-know-me`.

### A.3 — Goal: build a Shortcut that calls `ChatKit.OpenMessageIntent`

The shortcut needs a `WFWorkflowAction` that invokes the hidden intent. Two
candidate workflow actions for "run an arbitrary AppIntent":

  - **`com.apple.WorkflowKit.RunAppIntent`** — generic, parameterized by intent
    identifier + parameters
  - **`is.workflow.actions.runextensionintent`** — older legacy path
  - **`is.workflow.actions.runappintent`** (or similar) — newer iOS 17+ format

Tested empirically in `proxy-shortcuts-cli.sh`. Findings below.

---

## Hypothesis B — `shortcuts://` URL scheme

(see `scripts/probes/proxy-shortcuts-url.sh`)

Documented at https://support.apple.com/guide/shortcuts-mac/url-scheme-apdf22b0444c/mac

  - `shortcuts://run-shortcut?name=<name>&input=<input>`
  - `shortcuts://open-shortcut?name=<name>` — edit, not run

Result: TBD.

---

## Hypothesis C — Shortcuts.app's XPC

(see `scripts/probes/proxy-shortcuts-xpc.sh`)

Inspect Shortcuts.app XPC services:
  - `com.apple.shortcuts.runtime` (siriactionsd) — main runtime
  - `com.apple.WorkflowKit.BackgroundShortcutRunner` (XPC service)

`launchctl print` to see endpoint connectivity; `strings` to find selector.

Result: TBD.

---

## Hypothesis D — CSSearchableItem + Spotlight continuation

(see `scripts/probes/proxy-spotlight-continuation.swift`)

Publish a CSSearchableItem with `uniqueIdentifier` = `x-apple-appintents://com.apple.MobileSMS/MessageEntity/<GUID>`.

Two pathways to test:

  1. **Index-then-tap** — user must tap the result in Spotlight (manual).
  2. **NSUserActivity continuation** — programmatically synthesize an activity
     with `activityType = CSSearchableItemActionType` and `userInfo[CSSearchableItemActivityIdentifier] = <url>`
     then `becomeCurrent()`. The activity is meant to be delivered via
     Handoff/Spotlight tap — we can't fake the cross-app delivery.

Result: TBD.

---

## Hypothesis E — LaunchAgent helper

Out-of-process helper (a `LaunchAgent` plist) runs as a separate process. May
be granted sandbox-relaxed treatment for our own bundle. Investigate whether a
helper bundle, signed with the same Team ID, inherits the necessary AppIntents
entitlement — almost certainly no, but worth confirming.

Result: TBD.

---

## Final verdict

(Filled in once all hypotheses are tested.)
