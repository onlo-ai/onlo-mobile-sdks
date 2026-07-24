# iOS final E2E go-live checklist

Run the final local Swift package in `examples/ios-local-e2e` before publishing. Use synthetic test customers only; never paste SDK keys, JWTs, tokens, PII, message text, or attachment URLs into evidence.

Status: `[ ] Not tested` · `[x] Passed` · `[!] Failed or blocked`

## Prerequisites

- [x] **iPhone 17 simulator:** Open `examples/ios-local-e2e/OnloLocalE2EApp.xcodeproj`, select **OnloLocalE2EApp → iPhone 17**, and build the Debug target with the local merchant backend and Onlo service running.
  - Evidence: 2026-07-23 — Debug build installed/launched on iPhone 17 simulator `BEE08700…`; login-screen screenshot inspected; merchant connectivity `405` (expected for GET), Onlo discovery `200`; one Xcode destination warning.
  - Fix-build evidence: 2026-07-23 — post-remediation Debug build compiled the UIKit messenger and local host for iPhone 17 successfully and was installed on the same simulator. Manual runtime retest remains.
- [x] **Core local test environment:** Prepare a synthetic merchant/customer, an agent account, dashboard access, the merchant backend, database access, the local Onlo service, the local iOS SDK, and the iPhone simulator app.
  - Evidence: 2026-07-23 — synthetic merchant/customer A, local agent/dashboard, merchant backend, database, Onlo service, local iOS SDK, and installed iPhone 17 app were exercised end to end. Account identifiers are intentionally omitted.
- [ ] **Remaining test fixtures:** Prepare synthetic merchant/customer B, network conditioning, and one large non-sensitive source image.
  - Evidence: environment name and synthetic fixture labels: ___
- [ ] **Physical device only:** Prepare a signed build with APNs capability plus camera, microphone, speech-recognition, and notification usage descriptions.
  - Evidence: simulator coverage does not validate APNs delivery, camera hardware, provisioning, background notification delivery/tap, or a signed Release build; device/OS, build number, provisioning profile label: ___

Success means every applicable item passes, every physical-device item is completed before release, and both final sections contain no unresolved blocker.

## Optimized execution order

| Journey | One run covers |
| --- | --- |
| 1. Identified happy path | Setup, merchant/Support independence, JWT exchange, history, all messenger surfaces, streaming, titles, initial config, and timing/log evidence |
| 2. Dashboard + agent loop | Config revision/ETag/LKG, FAQ direct render, Help Center direct render, AI knowledge retrieval, unread/read acknowledgement, file-upload control |
| 3. Media + voice | Gallery limits/resizing/compression, dictation, spoken reply, denied permissions, interruption |
| 4. Offline recovery | Queued outbox, stable `clientMessageId`, exactly-once acceptance, session expiry, Support retry |
| 5. Account boundary | Logout cleanup, badge cleanup, customer A → B isolation, old push/deep-link rejection |
| 6. Physical release pass | Camera, APNs, background notification/tap, signed Release warnings, timing, and binary-size delta |

## 1. Setup — iPhone 17 simulator

- [ ] Initialize production with `try await Onlo.initialize(apiKey: sdkKey)` using the public iOS SDK key from the dashboard.
  - Evidence: Local Debug bootstrap recovered after adding the host Keychain entitlement; session request `81b1bc1b…` returned `200`/identified in 9,338 ms. Final production initializer remains untested.
- [ ] Confirm the app bundle ID exactly matches the dashboard iOS target.
  - Evidence: bundle ID and target label, without the SDK key: ___
- [!] Confirm session and config requests reach the intended Onlo environment; a release build must use `https://onlo.ai`.
  - Evidence: 2026-07-23 — Local Debug session requests reached the intended localhost Onlo service and returned `200`; no `/api/sdk/v1/config` request followed, and the production `https://onlo.ai` Release path remains untested.

## 2. Session and identity — iPhone 17 simulator

- [ ] Call `try await Onlo.loginUnidentifiedUser()` and confirm an anonymous session becomes ready.
  - Evidence: state and safe session status: ___
- [ ] Make Support initialization fail or retry and confirm the merchant remains logged in.
  - Evidence: screenshot and PII-free error code: ___
- [x] Fetch a fresh short-lived `userJwt` from the authenticated merchant backend, then call `try await Onlo.loginIdentifiedUser(userJwt: userJwt)`.
  - Evidence: 2026-07-23 — merchant log `issued_jwt`; identify session request IDs `3a1781bf…` and `d5410bd7…` returned `200`, ending identified; JWT was not logged.
- [ ] Disable server identity for the target and confirm identified login falls back to an anonymous-ready Support session without breaking merchant-app login.
  - Fix evidence: 2026-07-23 — iOS now treats `identity_disabled` as a definitive anonymous fallback, clears the pending identify transition, and keeps the merchant host usable. Focused Swift test passed; localhost runtime retest remains.
- [x] Confirm the identified synthetic customer receives the existing contact and authorised conversation history.
  - Evidence: 2026-07-23 — configured synthetic username/email rendered in Inbox; authorised inbox `200`/`sdk_inbox ok`; selected transcript `200`/`sdk_transcript ok` in 5,213 ms; encrypted client store has one owner scope and one transcript row.
- [ ] Call `try await Onlo.logout()` before merchant logout and confirm protected history, outbox access, and unread UI clear.
  - Evidence: resulting state and redacted screenshot: ___
- [ ] Log in as synthetic customer B after customer A and confirm no A conversation, draft, attachment, unread badge, or push route is accessible.
  - Evidence: A/B test labels and redacted screenshots: ___

## 3. Messenger — iPhone 17 simulator

- [ ] Call `try await Onlo.present(from: hostViewController)` and confirm Conversations, FAQ, and Help Center load.
  - Evidence: redacted screenshots: ___
- [!] Confirm FAQ and Help Center controls are hidden when they have no publishable content.
  - Evidence: 2026-07-23 — empty FAQ and Help Center segments remained visible; client code always creates all three segments even though answered FAQ rows are filtered. Structured server request `b0cf7e01…` returned `200` with `topicCount=0` and `articleCount=0`. The global dashboard row and live mobile config projection each contained one enabled, answered FAQ, but this iOS run made no `/api/sdk/v1/config` request and rendered no FAQ; the presenter silently converts a protected-config read failure to `nil`.
  - Fix evidence: 2026-07-23 — UIKit now creates only content-backed `Chats`, `FAQ`, and `Help` surfaces; the selector is hidden when Chat is the only surface. Presentation performs an ETag-backed config refresh plus Help Center catalog fetch, and corrupt config state resets before one fresh projection request. Focused cache-recovery test and iPhone 17 build passed; manual content/empty-state retest remains.
  - Runtime follow-up: 2026-07-23 — the iOS diagnostic stream emitted `sdk_config cache_reset` after every successful config response. The Help Center endpoint consistently returned `200` with `topicCount=0`; the FAQ projection could not survive the next protected-cache read, so the native presenter had no current config to render. Source review found two optional config fields decoded as required keys after local JSON re-encoding. Both decoders now use optional-key semantics; manual retest on a newly built app remains.
- [!] Open a predefined FAQ with an answer and confirm the configured answer renders unchanged without a chat request or new conversation.
  - Evidence: 2026-07-23 — the configured FAQ now appears, proving the current config projection is usable, but the native list rendered both the question and answer in one row. Source correlation shows FAQ selection was a no-op and did not call chat; server request `e7229f21…` was the coincident dispatch of an older queued four-character customer message, not the FAQ tap.
  - Fix evidence: 2026-07-23 — the UIKit FAQ surface now lists questions only; selecting one opens its configured answer locally with an **All questions** control and makes no SDK chat call. Source change is not built or manually retested.
- [ ] Open a Help Center article and confirm its published body renders directly without invoking chat.
  - Evidence: article label, request trace, screenshot: ___
- [ ] Send a normal synthetic question and confirm the AI path can retrieve configured FAQ/knowledge-base content.
  - Evidence: safe chat codes and redacted screenshot: ___
- [!] Confirm the AI response appears progressively before completion.
  - Evidence: 2026-07-23 — server request `88939875…` returned `200`, completed as `ai_reply`, and recorded `timeToFirstTokenMs=14181`; iOS recorded `sdk_chat code=invalid_response` after 18,194 ms, left the composer disabled, and did not render the streamed reply.
  - Fix evidence: 2026-07-23 — accepted `clientMessageId` correlation now compares UUID identity instead of case-sensitive UUID text, optimistic-row reconciliation uses the accepted server `messageId`, and the existing response-header request ID is attached to successful `accepted`, `first_token`, and `complete` client logs without changing the wire contract. The focused lowercase-acceptance/durable-dispatch/request-ID test and iPhone 17 build passed; real streaming retest remains.
  - Runtime follow-up: 2026-07-23 — a later customer message produced no `sdk_chat` event and no server `/api/widget/chat` request. Source correlation showed the earlier non-retryable `invalid_response` remained the durable FIFO head and silently blocked every later queued row. Terminal rows now remain stored for diagnostics but no longer block later dispatchable rows, and enqueue emits PII-safe `sdk_chat code=queued`. These source changes have not been built or tested.
  - Runtime correlation: 2026-07-23 — requests `e7229f21…`, `a818f48d…`, and `a05f3c40…` all completed server-side with HTTP `200` in conversation `4cd11e76…`; the first two ran the AI pipeline and the third completed as skipped/auto-resolved. Their exact client message IDs were durably stored by the server, while the corresponding encrypted iOS outbox rows became `failed_terminal` after `sdk_chat invalid_response`; one later row remained `queued`. The SDK now logs `accepted_received`, a specific safe decode code such as `invalid_accepted_event`, or `accepted_client_message_mismatch`, and immediately advances past a terminal row instead of waiting for another user send. Source changes are not built or manually retested.
  - Core transport follow-up: 2026-07-23 — dispatch no longer releases the owner FIFO at `accepted`; it holds one customer turn through `done`/stream completion, then automatically advances the next eligible row. This prevents queued customer messages from overlapping an active server response. Deterministic mock coverage is written but not run.
- [ ] Keep a transcript open while an agent replies and confirm the visible transcript and inbox update from the foreground stream without reopening Support.
  - Fix evidence: 2026-07-23 — the core previously refetched and persisted stream-hinted inbox/transcript data without notifying the open UIKit controller. The controller now observes authorised realtime snapshots, applies the updated visible transcript/inbox, and deduplicates read acknowledgements by rendered message position. Source changes are not built or manually retested.
  - Reconnect follow-up: 2026-07-23 — an ordinary foreground SSE close now schedules bounded reconnect instead of permanently stopping realtime delivery. Reconnect is bound to the captured bearer authority, session, and owner; logout/account rotation cancels it. Deterministic mock coverage is written but not run.
- [!] Reopen the inbox and transcript; confirm conversation titles, ordering, stored history, and one-conversation continuity render correctly.
  - Evidence: 2026-07-23 — the identified inbox contains three mobile conversations for the same verified customer. The current session's conversation `4cd11e76…` contains five messages, proving that N messages within one active session remain in one thread. The two older rows belong to prior session IDs.
  - Client contract boundary: the SDK sends the canonical chat body (`sessionId`, stable `clientMessageId`, content, and optional completed attachments) and never sends or invents a conversation-routing field. It treats server-issued `conversationId` and `messageId` values as opaque authoritative results. [VERIFY] One-conversation continuity still requires a manual localhost round trip after the serialized-turn fix.
- [!] Enter a conversation and return to the conversation list without dismissing Support.
  - Evidence: 2026-07-23 — the native controller replaced its inbox state with a transcript in place and exposed only the close control, so no back action existed.
  - Fix evidence: 2026-07-23 — UIKit now retains the latest authorised inbox snapshot, shows a **Back** control while a transcript is selected, renders the cached list immediately, and refreshes it through the existing cache-aware inbox API. Source change is not built or manually retested.

## 4. Configuration — iPhone 17 simulator

- [ ] Confirm dashboard theme, header avatar, greeting, light/dark appearance, FAQ, voice, and media controls match the active target.
  - Evidence: 2026-07-23 — the configured `Acme` bot name and published FAQ now render in the native UI, confirming the projection/cache decode fix. Avatar, greeting, both color modes, voice, and media controls remain to be checked.
- [ ] Change one safe dashboard setting, foreground the app, and confirm the revision/ETag refresh applies once.
  - Evidence: source now validates config on session establishment, app foreground, or `config_changed`, while reopening Support uses the protected projection. Help Center and Inbox use owner/authority-scoped memory caches and emit PII-safe `cache_hit`; read acknowledgements and stream hints still perform authoritative refetches. Manual old/new revision and request-count trace remains: ___
  - Runtime evidence: 2026-07-23 — reopening Support emitted `sdk_help_center cache_hit durationMs=0` and `sdk_inbox cache_hit durationMs=0`, confirming the simulator has functioning SDK storage/cache and does not refetch unchanged content on every presentation.
  - Transcript-cache follow-up: 2026-07-23 — online transcript reuse is now allowed only after the active in-memory bearer authority has authorised that owner-scoped encrypted transcript. Realtime, push, or the first network fetch refreshes the cache; a resumed/new authority must authorise it again. Deterministic mock coverage is written but not run.
- [ ] After one valid config is cached, force a refresh failure and confirm the last-known-good messenger remains usable.
  - Evidence: 2026-07-23 — focused test previously confirmed a corrupt protected config record is reset and followed by exactly one successful fresh projection request. The later runtime exposed a separate encode/decode round-trip bug: successful config responses were followed by `cache_reset`, causing repeated conditional requests and no usable last-known-good projection. The optional-key decode fix is applied in source; offline last-known-good UI runtime screenshot remains: ___

## 5. Unread state — iPhone 17 simulator

- [ ] Observe `Onlo.observeUnreadCount()`, send an agent reply, and confirm both the conversation badge and total identified-user count increase.
  - Evidence: before/after counts and safe event code: ___
- [!] Open and fully render that conversation; confirm it is acknowledged read and both counts clear after refetch.
  - Evidence: 2026-07-23 — inbox request `d13b23b1…` returned `200` with `totalUnreadCount=1`; transcript request `7f21fb65…` returned `200`; read acknowledgement `ff92c623…` returned `200` but still reported `unreadCount=1`. iOS recorded `sdk_read_acknowledgement code=invalid_response`, so its strict zero-unread guard stopped the post-read inbox refetch and the conversation badge remained `1`.
  - Fix evidence: 2026-07-23 — iOS now accepts any internally consistent nonnegative read snapshot and always refetches the authorised inbox. A focused test covered acknowledgement `unreadCount=1` followed by inbox `totalUnreadCount=0`; iPhone 17 manual badge retest remains.
  - Runtime follow-up: 2026-07-23 — the fixed client did perform the post-read inbox refetch. Read requests `cf2f3bd5…`, `f5b5df48…`, `b8589690…`, `a88eefe5…`, and `5978ca11…` each returned `200` with `unreadCount=1`; their following inbox refetches returned `200` with `totalUnreadCount=2`. The remaining badge is therefore the authoritative response currently returned to iOS, not a swallowed acknowledgement or missing client refetch. No database data was modified.
  - Runtime evidence: 2026-07-23 — the latest UI showed gray badge `1` on all three cached rows. Read-only correlation found the two historical conversations each had one customer-unread message, while the active conversation had two unread assistant replies at inspection time. The visible active-row `1` was stale, not authoritative. The controller now retains every realtime inbox snapshot and the new transcript **Back** path uses the core's post-read cached refetch; manual badge-clear verification remains.
- [ ] Confirm badge state clears immediately after `Onlo.logout()` and remains clear through account switching.
  - Evidence: state/count sequence: ___

## 6. Images

- [ ] **iPhone 17 simulator:** Choose images from the photo library and confirm one message accepts up to five images.
  - Evidence: selected/uploaded count and redacted screenshot: ___
- [ ] **Physical device only:** Take an image with Camera and confirm it uploads successfully after just-in-time permission.
  - Evidence: device/OS, permission result, safe upload status: ___
- [ ] **iPhone 17 simulator:** Upload a source image near the 25 MiB input limit and confirm it is resized without cropping, bounded to 4096 px/16 MP, and compressed to the configured limit no greater than 8 MiB.
  - Evidence: source/output dimensions and byte counts; no URL: ___
- [ ] **iPhone 17 simulator:** Disable dashboard file upload and confirm the attachment control disappears after config refresh.
  - Evidence: config revision and screenshot: ___

## 7. Voice — iPhone 17 simulator

- [ ] Enable voice in the dashboard, dictate a synthetic phrase, and confirm speech recognition fills the normal composer.
  - Evidence: permission state and screenshot without message text: ___
- [ ] Enable the speaker control, send a synthetic AI request, and confirm only the completed AI reply is spoken.
  - Evidence: safe chat codes and observed result: ___
- [ ] Deny microphone/speech permission, then interrupt an active session; confirm text chat remains usable and no crash or sensitive log appears.
  - Evidence: PII-free error code and screenshot: ___

## 8. Offline and recovery — iPhone 17 simulator

- [ ] Enable airplane mode/network conditioning, send messages, and confirm they remain visibly queued.
  - Evidence: queued count and screenshot without text: ___
- [ ] Reconnect and confirm each logical message is accepted once with its original `clientMessageId`.
  - Evidence: 2026-07-23 — focused durable-dispatch test confirmed a lowercase server echo of the original UUID is accepted once and persisted as accepted. Offline simulator trace with duplicate count remains: ___
  - Runtime blocker: 2026-07-23 — three exact outbox client message IDs were accepted and stored server-side once, but iOS classified their rows as `failed_terminal` after `invalid_response`; a fifth row stayed queued until another user action. The parser/acceptance stage is now distinguished in safe logs, and terminal-row dispatch advances automatically. Manual retest is required.
  - Contract-test follow-up: 2026-07-23 — raw canonical `accepted`, `text`, and `done` fixtures plus malformed-event safe-code coverage are written against the live decoder. Terminal-row auto-advance and serialized-turn queue coverage are also written. Tests were not run per instruction.
- [ ] Expire the Onlo session or force Support retry; confirm bounded recovery succeeds without logging the merchant out.
  - Evidence: 2026-07-23 — config request `cebb17f4…` expired with `401 session_expired`; session resume `2fab5ef7…` returned `200`, a new foreground stream connected, and Support later opened normally. An overlapping presentation recorded `present_messenger invalid_state` after 30,720 ms rather than a process crash. The presenter now rejects an overlapping presentation immediately and relaxes only the transient keyboard-bottom constraint; source changes are not built or manually retested.

## 9. Push and deep links

- [x] **iPhone 17 Pro Simulator / iOS 26.4:** Inject a contract-shaped
      `message_available` notification while the app is terminated.
  - Evidence: Simulator displayed the generic notification;
    `/private/tmp/onlo-merchant-test/screenshots/ios-push-terminated.png`.
    This validates Simulator notification reception, not APNs provider delivery.

- [ ] Forward the APNs token with `try await Onlo.setAPNsPushToken(deviceToken)` and confirm registration succeeds.
  - Evidence: device/OS, APNs environment, safe registration state: ___
- [ ] Background the app, send an agent reply, and confirm a notification arrives without protected message data in logs.
  - Evidence: notification screenshot and safe event code: ___
- [ ] On tap, call `try await Onlo.handleNotificationTap(userInfo, from: hostViewController)` and confirm only the authorised conversation opens.
  - Evidence: handled result and redacted screenshot: ___
- [ ] Log out, then replay an old notification; confirm the former identity receives or opens no protected content.
  - Evidence: handled/deferred result and screenshot: ___

## 10. Release quality

- [ ] **iPhone 17 simulator:** Exercise login, chat, media, voice, retry, and logout; confirm logs contain no SDK key, token, JWT, PII, message text, attachment URL, or raw push token.
  - Evidence: the local host writes PII-safe operation diagnostics to `Library/Caches/onlo-e2e-diagnostics.log` inside the simulator app container; current logs expose operation, code, request ID, status, and duration without message content. Full journey review remains: ___
- [ ] **iPhone 17 simulator:** Call `Onlo.setLogLevel(.off)` and confirm release SDK logging stops.
  - Evidence: before/after log timestamps: ___
- [ ] **iPhone 17 simulator:** Record first-open/presentation, send-to-`first_token`, and send-to-`complete` durations under named network conditions.
  - Evidence: device/runtime, network profile, durations in ms: ___
- [x] **Unsigned Release build:** Compare the arm64 host executable with a matched host built without `OnloSDK`.
  - Evidence: baseline 87,312 bytes; Onlo host 3,841,040 bytes; delta 3,753,728 bytes (3.58 MiB). The SDK host emitted one unused-result example warning; two host-project warnings also occurred in the baseline. This is build evidence, not a signed archive or App Store download-size claim.

## If a step fails

| Failure | Action |
| --- | --- |
| Contract/status mismatch | Stop; compare the safe request ID and status with `docs/api-contract.md`. Do not add fields or client fallbacks. |
| Identity or account-boundary failure | Disable Support for the next user and treat it as a release blocker. |
| Simulator-only limitation | Move the item to the named physical-device run; do not mark it passed. |
| Dashboard mismatch | Confirm SDK key target, bundle ID, publication state, and config revision before retrying. |

Rollback the test build by uninstalling the E2E app and removing only its synthetic test data through the approved environment process.

## Release blockers

- [ ] No unresolved failed/blocked item above.
  - Evidence: blocker ticket links or `None`: ___
- [ ] No contract, identity isolation, protected-storage, duplicate-send, or sensitive-logging discrepancy.
  - Evidence: reviewer and date: ___

## Real-device validation remaining

- [ ] Camera capture, APNs registration/delivery/tap routing, logout push isolation, permission interruption, signed Release build, warnings, and binary-size delta are complete on a physical iPhone.
  - Evidence: remaining items or `None`: ___
