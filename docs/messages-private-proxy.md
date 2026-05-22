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

(see `scripts/probes/proxy-shortcuts-cli.sh`,
`scripts/probes/proxy-build-shortcut.m`,
`scripts/probes/proxy-list-workflow-actions.m`)

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

Empirically catalogued from the user's installed shortcuts:
  - `is.workflow.actions.getlastphoto`
  - `is.workflow.actions.sendmessage` (with `IntentAppIdentifier =
    "com.apple.MobileSMS"`)
  - `is.workflow.actions.runworkflow`
  - `is.workflow.actions.notification`
  - …

WorkflowKit has a class `WFAppIntentExecutionAction` (subclass of `WFAction`,
also `WFLinkAction` which subclasses it). These represent App-Intent-backed
actions. They expose `metadata: LNActionMetadata`,
`fullyQualifiedLinkActionIdentifier: LNFullyQualifiedActionIdentifier`,
and `mangledTypeName: NSString` — matching the `LNAction` we built in the
prior LNConnection probe.

### A.3 — Crafted Shortcut signing fails for hand-built plist

Attempted to use `WFShortcutPackageFile initWithShortcutData:shortcutName:` +
`extractShortcutFileRepresentationWithSigningMethod:error:` to build a
`.shortcut` container in-process. Five candidate `WFWorkflowActionIdentifier`
values tested:

```
[com.apple.WorkflowKit.RunAppIntent]                  FAIL: file doesn't exist
[com.apple.MobileSMS.OpenMessageIntent]               FAIL: file doesn't exist
[OpenMessageIntent]                                   FAIL: file doesn't exist
[com.apple.shortcuts.action.appintent]                FAIL: file doesn't exist
[com.apple.WorkflowKit.AppIntentExecutionAction]      FAIL: file doesn't exist
```

The "file doesn't exist" error is from
`extractShortcutFileRepresentationWithSigningMethod:` — the underlying flow
expects a directory structure on disk (`generateDirectoryStructureInDirectory:`)
and we'd need to mimic Shortcuts.app's full export pipeline. Not impossible
but extensive — and the resulting `.shortcut` would still need to be installed
into Shortcuts.app and have the user run it.

### A.4 — But: does Shortcuts.app even have the entitlement?

Direct check of `/System/Applications/Shortcuts.app` and
`/usr/libexec/siriactionsd` (the daemon that actually runs shortcuts):

```
$ codesign -d --entitlements - /System/Applications/Shortcuts.app | grep foreign-bundle
(no match)
$ codesign -d --entitlements - /usr/libexec/siriactionsd | grep foreign-bundle
(no match)
$ codesign -d --entitlements - /System/Library/PrivateFrameworks/WorkflowKit.framework/XPCServices/BackgroundShortcutRunner.xpc | grep foreign-bundle
(no match)
```

**Neither Shortcuts.app nor siriactionsd nor BackgroundShortcutRunner has
`com.apple.private.appintents.exception.allow-foreign-bundle-identifiers`**.
This entitlement is what's required to invoke an AppIntent of a foreign
bundle (per the LNConnection error in the prior research). Without it,
Shortcuts.app cannot dispatch an `OpenMessageIntent` to Messages.app any
better than we can.

Who DOES have it? Empirical scan of `/usr/libexec`, system XPCServices, and
private frameworks:
  - `/usr/libexec/linkd` (the AppIntents/LinkServices daemon)
  - `/System/Library/PrivateFrameworks/MediaRemote.framework/Support/mediaremoted`

linkd is the broker. Its mach services include:
  - `com.apple.intents.intents-helper`
  - `com.apple.linkd.registry`
  - `com.apple.linkd.transcript.privileged`
  - `com.apple.linkd.transcript.observing`
  - `com.apple.appIntents.relevantIntentProvided`
  - `com.apple.CascadeSets.DonateNow`
  - …

`launchctl print gui/501` only shows three published delegate endpoints:
`com.apple.private.appintents.delegate.com.apple.homed`,
`.intelligenceplatformd`, `.appstorecomponentsd`. There is **no
`delegate.com.apple.MobileSMS`** — even linkd can't dispatch to Messages
because Messages.app does not register an AppIntent delegate endpoint
(consistent with the prior research's `launchctl print` finding).

### A.5 — Probing linkd XPC services from our (unentitled) process

```
[com.apple.intents.intents-helper]               Connection invalid
[com.apple.linkd.registry]                       Connection interrupted
[com.apple.linkd.transcript.privileged]          Connection invalid
[com.apple.linkd.transcript.observing]           Connection invalid
[com.apple.linkd.synchronizeMetadataStore]       Connection invalid
[com.apple.linkd.update-registry]                Connection invalid
[com.apple.linkd.prune-transcript]               Connection invalid
[com.apple.link.XPCEventDispatcher]              Connection invalid
[com.apple.appIntents.relevantIntentProvided]    Connection invalid
[com.apple.CascadeSets.DonateNow]                Connection invalid
```

"Connection interrupted" on `linkd.registry` is the closest we get — it
accepts the connection then drops it. The others reject our entitlements
outright. So the LinkD/Intents-helper APIs are not reachable from us.

### A.6 — Verdict: Hypothesis A negative

  1. We could in principle build a `.shortcut` file with the right
     `WFAppIntentExecutionAction` for `ChatKit.OpenMessageIntent`, but…
  2. Shortcuts.app, siriactionsd, and BackgroundShortcutRunner all **lack**
     the foreign-bundle entitlement, so even if we got them to try to run
     the action, they would hit the same XPC dispatcher block.
  3. The only daemon that has the entitlement (`linkd`) cannot publish to
     `com.apple.MobileSMS` because Messages.app does not register an
     AppIntent delegate endpoint.

So Hypothesis A is a **negative result**: routing through Shortcuts changes
*who* the caller is, but the dispatch failure isn't actually about the
caller's identity — it's about Messages.app not advertising a public AppIntent
delegate endpoint at all. The `OpenMessageIntent` is `isDiscoverable: false`
and the bundle doesn't publish its delegate to non-Apple-internal clients.

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
