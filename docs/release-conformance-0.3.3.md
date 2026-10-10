# SDK 0.3.3 verification — 2026-10-10

NO-SHIP. Pre-reconciliation evidence below applies to the local patch only; a preserved-history reconciliation and fresh qualification are required. Nothing from this patch is published.
Baseline: `dev` at `aa8c200590bc619eaffebceaf5c74e55b4c7f218`.

## Root causes + changes

- Original defect: targeted native opens omitted inbox-style 401 recovery. Resume same protected owner, retry once; non-401 remains terminal. Incident cause plausible, not proven for every report.
- P1: actor reentrancy let late refresh overwrite logout. Epoch fences reject stale success/failure; logout revokes memory before suspension, persists pending logout, preserves exact transition replay even on network failure.
- P2: concurrent resumes created competing rotations; stale failure restored old generation/reauth state. Same-credential callers now share one flight; protected writes serialize.
- Logs: safe HTTP/network/state/host codes; `resume_joined` verbose. No tokens/customer content. Public bridge payloads, API, wire/storage contracts unchanged.

## Regression evidence

Eight deterministic tests: late success/failure after logout success/failure and account switch; overlapping 401 coalescence; one retry per open. Failed logout survives recreation. Existing valid recovery/non-401 tests retained.
Negative control: same exact two reproductions against reviewed pre-fix implementation fail (14 assertions); fixed suite passes. Native lifecycle test now injects in-memory stores instead of real Simulator Keychain.

| SDK | Pre-reconciliation evidence |
| --- | --- |
| iOS | 133 tests on macOS + 133 on iOS Simulator; Swift Release + pod lint pass |
| Android | 129 tests, forced rerun; release AAR + native example pass |
| Flutter | 9 tests; analyze clean; Android + iOS example builds pass |
| React Native | 18 tests; package/example typechecks; Android + iOS example builds pass |

Root typecheck, protocol (8), conformance (3), hygiene (4 + checker), version check and graph update pass. Wrapper unit tests mock channels; real native bridges compile in both-platform example builds. These are not four-platform runtime E2E claims.

## Commands/evidence

- iOS: `swift test --package-path packages/ios --scratch-path /tmp/onlo-033-race-fix-macos`; Simulator `xcodebuild -scheme OnloSDK ... test` (full arguments below).
- Android: `ANDROID_HOME=/opt/homebrew/share/android-commandlinetools packages/android/gradlew -p packages/android testDebugUnitTest assembleRelease --rerun-tasks --max-workers=2`.
- Flutter package: `flutter analyze`; `flutter test --no-pub`.
- RN package: `npm run typecheck`; `npm test`.
- Exact build/Simulator commands, cwd, exit codes: `/tmp/onlo-033-gates.json`. Logs: `/tmp/onlo-033-gate-*.log`; negative control: `/tmp/onlo-033-race-negative-exact.log`.
- Durable safe evidence: `/Users/shivam/.codex/visualizations/2026/10/10/01a1247b-f32f-7942-83b8-6642f369c089/sdk-033-race-fix/` (logs, screenshots, source hashes).

## Live test / remaining gates

Native example 0.3.3 (1), `ai.onlo.sdk033live`, iPhone 17 / iOS 26.4 Simulator, Xcode 26.4. Production test workspace only; existing merchant backend issues synthetic identified-user proof. Identified send/receive visible; DB identity confirmed. No reinstall for identity transition. After 15 minutes, targeted presentation returned `widget_401_error`, one session refresh, `bearer_refreshed`, then `present=ok` and transcript success; no reinstall. The deep-link core open succeeded just before expiry; the presenter’s second targeted authorization hit expiry and recovered. Exact expiry of the first `openConversation` call is covered deterministically, not independently established by this live trace.

No affected Hey Foods device/build available. Publishing/artifact verification, Hey Foods integration, affected-device expiry retest remain separate gates. Simulator cannot close customer incident. Live help-center `invalid_response` observed separately; not claimed fixed. No server/DB mutation, commit, publish or acceptance performed.

Flutter live-example blocker: `/v1/onlo-user-jwt` is called without the merchant bearer; URL configuration alone cannot authenticate against the bundled backend. Native iOS example performs test-login correctly. Wrapper runtime E2E remains unverified.

Post-expiry: human dashboard reply displayed live; subsequent identified outbound accepted/completed while human takeover remained enabled. Evidence: `identified-post-expiry-roundtrip.png`, `identified-live-diagnostics.log`, `identified-post-expiry-db.json` in the evidence directory. Release recommendation: NO-SHIP for acceptance until integration/runtime gates above are closed; both reported concurrency defects and four-SDK local gates are green.

## Final published-artifact audit

- Registry downloads (2026-10-10): Maven AAR + sources 0.3.3, CocoaPods 0.3.3 spec → tag commit `17d802645968e6fda2a8c3b8e5571599ca63a18f`, pub.dev 0.3.3 archive (SHA-256 matches registry). npm 0.3.3 returns 404; latest 0.3.2.
- Published native 0.3.3 already contains basic targeted 401 recovery; iOS also has simple in-flight resume coalescing. Neither version labels nor absence of our symbol names prove absence of those behaviors.
- Exact published iOS source + P1 regression: 1 test, 6 failed assertions; late success restores `identifiedReady` after failed logout. Test-only fixtures added; published production source untouched.
- Candidate diverges from published baseline: shared iOS core and rejected-credential/transcript recovery would be removed. Preserve/reconcile these before release; existing local green checks do not prove upgrade safety.
- Artifact checks: candidate Maven publication bundle and RN package pass; Flutter dry-run reports only dirty-Git warning. Flutter host example is outside the published plugin and is not a release blocker.
- NO-SHIP: reconcile published baseline, qualify a new patch version, then publish. Existing 0.3.3 cannot be replaced. No commit, tag movement or publication performed. Prior generic “unpublished” statements refer only to this local patch.
- Evidence: `published-artifact-audit/` in the durable evidence directory above. Customer/developer READMEs now state verified availability, merchant-auth requirements and known issue.
