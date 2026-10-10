# SDK 0.3.3 verification — 2026-10-10

NO-SHIP. Local fix `fc1c893` reconciled with published source `17d802645968e6fda2a8c3b8e5571599ca63a18f`; both histories retained. Fresh checks below cover the reconciled source. No corrected package published.

## Root causes + changes

- Original defect: targeted native opens omitted inbox-style 401 recovery. Resume same protected owner, retry once; non-401 remains terminal. Incident cause plausible, not proven for every report.
- P1: actor reentrancy let late refresh overwrite logout. Epoch fences reject stale success/failure; logout revokes memory before suspension, persists pending logout, preserves exact transition replay even on network failure.
- P2: concurrent resumes created competing rotations; stale failure restored old generation/reauth state. Same-credential callers now share one flight; protected writes serialize.
- Logs: safe HTTP/network/state/host codes; `resume_joined` verbose. No tokens/customer content. Public bridge payloads, API, wire/storage contracts unchanged.

## Regression evidence

Eight deterministic tests: late success/failure after logout success/failure and account switch; overlapping 401 coalescence; one retry per open. Failed logout survives recreation. Existing valid recovery/non-401 tests retained.
Negative control: same exact two reproductions against reviewed pre-fix implementation fail (14 assertions); fixed suite passes. Native lifecycle test now injects in-memory stores instead of real Simulator Keychain.

| SDK | Reconciled source evidence |
| --- | --- |
| iOS | 138 tests on macOS + 138 on iOS Simulator; Swift Release + pod lint pass |
| Android | 135 tests, forced rerun; release AAR + native example pass |
| Flutter | 9 tests; analyze clean; Android + iOS example builds pass |
| React Native | 18 tests; package/example typechecks; Android + iOS example builds pass |

Root typecheck, protocol (8), conformance (3), hygiene (4 + checker), version check and graph update pass. Wrapper unit tests mock channels; real native bridges compile in both-platform example builds. These are not four-platform runtime E2E claims.

## Commands/evidence

- iOS: `swift test --package-path packages/ios --scratch-path /tmp/onlo-reconciled-ios`; Simulator `xcodebuild -scheme OnloSDK ... test` (full arguments below).
- Android: `ANDROID_HOME=/opt/homebrew/share/android-commandlinetools packages/android/gradlew -p packages/android testDebugUnitTest assembleRelease --rerun-tasks --max-workers=2`.
- Flutter package: `flutter analyze`; `flutter test --no-pub`.
- RN package: `npm run typecheck`; `npm test`.
- Exact build/Simulator commands, cwd, exit codes: `/tmp/onlo-reconciled-gates.json`. Logs: `/tmp/onlo-reconciled-gate-*.log`; negative control: `/tmp/onlo-033-race-negative-exact.log`.
- Durable safe evidence: `/Users/shivam/.codex/visualizations/2026/10/10/01a1247b-f32f-7942-83b8-6642f369c089/sdk-033-race-fix/` (logs, screenshots, source hashes).

## Live test / remaining gates

Native example 0.3.3 (1), `ai.onlo.sdk033live`, iPhone 17 / iOS 26.4 Simulator, Xcode 26.4. Production test workspace only; existing merchant backend issues synthetic identified-user proof. Identified send/receive visible; DB identity confirmed. No reinstall for identity transition. After 15 minutes, targeted presentation returned `widget_401_error`, one session refresh, `bearer_refreshed`, then `present=ok` and transcript success; no reinstall. The deep-link core open succeeded just before expiry; the presenter’s second targeted authorization hit expiry and recovered. Exact expiry of the first `openConversation` call is covered deterministically, not independently established by this live trace.

No affected Hey Foods device/build available. Publishing/artifact verification, Hey Foods integration, affected-device expiry retest remain separate gates. Simulator cannot close customer incident. Live help-center `invalid_response` observed separately; not claimed fixed. No direct server/DB mutation, publication or acceptance performed.

Flutter live-example blocker: `/v1/onlo-user-jwt` is called without the merchant bearer; URL configuration alone cannot authenticate against the bundled backend. Native iOS example performs test-login correctly. Wrapper runtime E2E remains unverified.

Post-expiry: human dashboard reply displayed live; subsequent identified outbound accepted/completed while human takeover remained enabled. Evidence: `identified-post-expiry-roundtrip.png`, `identified-live-diagnostics.log`, `identified-post-expiry-db.json` in the evidence directory. Both reported concurrency defects and four-SDK local gates are green. Customer-device incident closure remains separate from SDK publication; Flutter example wiring is outside the package deliverable.

## Final published-artifact audit

- Registry downloads (2026-10-10): Maven AAR + sources 0.3.3, CocoaPods 0.3.3 spec → tag commit `17d802645968e6fda2a8c3b8e5571599ca63a18f`, pub.dev 0.3.3 archive (SHA-256 matches registry). npm 0.3.3 returns 404; latest 0.3.2.
- Published native 0.3.3 already contains basic targeted 401 recovery; iOS also has simple in-flight resume coalescing. Neither version labels nor absence of our symbol names prove absence of those behaviors.
- Exact published iOS source + P1 regression: 1 test, 6 failed assertions; late success restores `identifiedReady` after failed logout. Test-only fixtures added; published production source untouched.
- Reconciliation preserves published shared iOS core, rejected-credential/transcript recovery and wrapper corrections. Replacement/bootstrap inside refresh now inherits epoch fences; configuration refresh runs outside the shared flight. Published baseline regression tests retained.
- Artifact checks: candidate Maven publication bundle and RN package pass; Flutter dry-run reports only dirty-Git warning. Flutter host example is outside the published plugin and is not a release blocker.
- NO-SHIP: release workflow, npm authorization diagnosis, approved unused patch version and registry content verification remain gates. Existing 0.3.3 stays immutable. Local commit/reconciliation only; no push, tag movement or publication.
- Evidence: `published-artifact-audit/` in the durable evidence directory above. Customer/developer READMEs now state verified availability, merchant-auth requirements and known issue.

## 0.3.4 release controls

Candidate 0.3.4: all four registry version endpoints returned 404 on 2026-10-10. Existing 0.3.3 untouched. Publication remains NO-SHIP until remote gates pass.

- CI: PR + main; five independent jobs, aggregate `SDK CI required`, Simulator race tests; no publishing credentials.
- Guarded tag worker: tag SHA must belong to protected main with successful exact-SHA main CI. Draft + prepared manifest precede `sdk-release` approval by `betavirus777`.
- Android: approved AAR/POM/source/Javadoc/module bytes; sign/upload those files without rebuilding. npm + Flutter: publish prepared archives, compare downloaded SHA-256. iOS: canonical CocoaPods spec plus downloaded SwiftPM archive file-content SHA-256 (paths/executable bits retained; archive timestamps ignored).
- Match → skip. Mismatch/partial/unverifiable → stop. Draft stays unpublished until all four independently verify. Unknown upload outcome requires registry/deployment diagnosis before retry; prepared assets are never overwritten.
- npm diagnosis: dispatch `release-qualification.yml` on main with `npm_diagnostics=true`; read-only, environment-approved, no upload. Identity/access success alone does not prove granular token scope or resolve the old E404. Set environment variable `NPM_E404_RESOLVED=true` only after cause/correction evidence exists.
- Local workflow validation: actionlint 1.7.12; 22 release regression tests. Real 0.3.3 CocoaPods/SwiftPM, Maven AAR and pub.dev content comparisons passed. New pipeline has not yet run remotely; Central upload/new npm authorization remain unverified.

Fresh 0.3.4 local gates: iOS 138 macOS + 138 Simulator, Android 135, Flutter 9, React Native 18; all native/wrapper release builds and pod lint pass. RN iOS first failed on stale installed Pods; `pod install` then `npm run build:ios:release` passed. Exact commands/logs: `/tmp/onlo-034-gates.json`, `/tmp/onlo-034-rn-pod-install.log`, `/tmp/onlo-034-rn-ios-retry.log`.

Packaging rehearsal: nine prepared files cover all four channels; local manifest hashes pass. Dart `--dry-run --to-archive` produced no file despite exit 0; fixed to separate validation and `--to-archive` commands, then verified the actual archive.

Remote PR CI exposed a third iOS race: delayed session-success push work cleared a newer `after_token_refresh` gate. Added bearer/token/gate-generation fences; repeated token registration preserves prerequisites. Controlled regression fails on pre-fix source and passes with genuine fresh-bearer recovery; iOS suite now 139. Simulator fixture now disables unrelated UIKit events and routes concurrent config/push requests separately. Remote CI and final Simulator rerun remain required.
