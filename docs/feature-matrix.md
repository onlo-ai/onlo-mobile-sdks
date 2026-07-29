# Mobile SDK canonical feature matrix

This is the single release-status matrix for the four client surfaces. The
[API contract](api-contract.md) owns wire behavior; native Core owns protected
state and transport; React Native and Flutter delegate to native Core and UI.

## Status legend

| Mark | Meaning |
| --- | --- |
| ✅ | Implemented at the named layer with automated evidence |
| 🟡 | Implemented or partially evidenced, but release/device evidence is incomplete |
| ⛔ | Blocked by an explicit contract or product dependency |
| — | Intentionally not owned or exposed at this layer |

## Feature matrix

| Feature | Server contract | iOS Core | Android Core | iOS UI | Android UI | React Native bridge | Flutter bridge | Automated evidence | Real-device evidence | Blocker |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| initialize/bootstrap | Declared: discovery and session bootstrap/resume | ✅ protected restore, rotation, lifecycle | ✅ protected restore, rotation, lifecycle | — | — | ✅ typed delegation; fixed `react-native` family | ✅ typed delegation; fixed `flutter` family | NATIVE, BRIDGE | None | Production target configuration |
| anonymous identity | Declared: bootstrap creates/replays anonymous installation generation | ✅ | ✅ | ✅ native messenger available | ✅ native messenger available | ✅ delegates `loginUnidentifiedUser` | ✅ delegates `loginUnidentifiedUser` | NATIVE, BRIDGE | IOS-SIM | Physical iOS plus Android and wrapper device journeys |
| identified identity | Declared: host JWT exchange only | ✅ JWT memory-only, server-verified transition | ✅ JWT memory-only, server-verified transition | ✅ history shown only after Core authority | ✅ history shown only after Core authority | ✅ typed JWT forwarding only | ✅ typed JWT forwarding only | NATIVE, BRIDGE, PROTOCOL | IOS-SIM | Physical iOS plus two-device/four-surface identified journey |
| logout/account switch | Declared: logout transition; owner retirement is a client invariant | ✅ old scope blocked/purged before replacement | ✅ old scope blocked/purged before replacement | ✅ immediate redaction/dismissal | ✅ presentation hidden and old target cleared | ✅ delegates and observes native state | ✅ delegates and observes native state | NATIVE, BRIDGE | None | Physical A→B isolation on all native hosts |
| conversation list | Declared: full bearer-authorised list with aggregate unread | ✅ authority and request-generation fenced cache | ✅ authority and request-generation fenced cache | ✅ list, ordering, row badge | ✅ list, ordering, row badge | ✅ native presentation only; no JS list store | ✅ native presentation only; no Dart list store | NATIVE | IOS-SIM | Physical iOS plus Android/RN/Flutter host execution |
| transcript | Declared: bounded cursor page and latest refetch | ✅ owner-scoped encrypted cache; serial writer | ✅ owner-scoped encrypted cache; serial writer | ✅ transcript and back-to-list flow | ✅ transcript and back-to-list flow | ✅ native presentation only | ✅ native presentation only | NATIVE, PROTOCOL | IOS-SIM | Physical history and lifecycle pass |
| composer/send | Declared: canonical chat request and SSE events | ✅ native durable send | ✅ native durable text send | ✅ composer and streaming projection | ✅ composer and streaming projection | ✅ native UI only; no JS composer | ✅ native UI only; no Dart composer | NATIVE, PROTOCOL | IOS-SIM | Physical iOS plus Android and wrapper native-host journeys |
| durable offline queue | Client invariant; server supplies stable idempotency boundary | ✅ SQLite outbox | ✅ SQLite outbox | ✅ queued/offline status | ✅ queued/offline status | ✅ inherited; no JS persistence | ✅ inherited; no Dart persistence | NATIVE | None | Restart/reconnect on physical iOS and Android |
| acceptance/reconciliation | Declared: `accepted` is durable; duplicate requires transcript sync | ✅ `ACCEPTED` → `RECONCILED`, never resent | ✅ `ACCEPTED` → `RECONCILED`, never resent | ✅ converges through transcript | ✅ converges through transcript | ✅ inherited | ✅ inherited | NATIVE, PROTOCOL | IOS-SIM | Physical interruption/restart journey |
| SSE | Declared: ready/config/inbox hints only; no resume cursor | ✅ current-authority refetch and reconnect | ✅ current-authority refetch and reconnect | ✅ observes native convergence | ✅ observes native convergence | ✅ native lifecycle/event forwarding only | ✅ native lifecycle/event forwarding only | NATIVE, PROTOCOL | IOS-SIM | Physical background/foreground and network switch |
| unread/read acknowledgement | Declared: installation-authorized rendered-through PUT; identified aggregate/row unread only | ✅ generation-fenced refetch; anonymous counts scrubbed | ✅ generation-fenced refetch; anonymous counts scrubbed | ✅ render-then-acknowledge | ✅ render-then-acknowledge | ✅ aggregate event forwarding | ✅ aggregate state forwarding | NATIVE, PROTOCOL | IOS-SIM partial | Two-device authoritative badge pass |
| configuration/theme | Declared: schema 1, ETag/304, LKG, appearance/content | ✅ protected LKG and authority-fenced refresh | ✅ protected LKG and authority-fenced refresh | ✅ light/dark/system tokens and branded content | ✅ projected tokens and branded content | ✅ native UI/config only | ✅ native UI/config only | NATIVE, PROTOCOL | IOS-SIM partial | Manual light/dark, accessibility, offline LKG |
| FAQ | Declared: answered FAQ renders directly without chat | ✅ validated config projection | ✅ validated config projection | ✅ question selection and local answer | ✅ direct local answer rendering | ✅ native UI only | ✅ native UI only | NATIVE, PROTOCOL | IOS-SIM partial | Manual no-chat verification on both platforms |
| Help Center | Declared: catalog/article bearer routes; direct rendering | ✅ typed catalog/article transport | ✅ typed catalog/article transport | ✅ topics, articles, related content | ✅ topics and articles | ✅ native UI only | ✅ native UI only | NATIVE, PROTOCOL | None | Manual content/empty-state verification |
| images | Declared: Widget upload grant plus owner-authorised current/historical session routing | ✅ encrypted staged bytes, durable grant refresh, stable ID | ✅ encrypted staged bytes, durable grant refresh, stable ID | ✅ policy-gated library/camera picker and first-message send | ✅ policy-gated library/camera picker and first-message send | ✅ inherits native UI/Core; no JS attachment state | ✅ inherits native UI/Core; no Dart attachment state | NATIVE, PROTOCOL | None | Physical picker/camera, expiry, offline retry, and policy-toggle pass |
| push | Declared: APNs/FCM register/unregister and hint payload | ✅ APNs protected intent and authority fencing | ✅ FCM protected intent and authority fencing | ✅ authorised tap routing | ✅ authorised open routing | ✅ delegates by native runtime | ✅ delegates by native runtime | NATIVE, BRIDGE, PROTOCOL | ANDROID-FCM | Physical APNs; React Native and Flutter provider-host journeys; logout isolation on each runtime |
| deep links | Declared capability; authorization uses conversation transcript | ✅ `openConversation` authority check and capability | ✅ `openConversation` authority check and capability | ✅ host-selected presentation | ✅ host-selected presentation | ✅ host route forwarding | ✅ host route forwarding | NATIVE, BRIDGE | None | Cold-start physical-device pass |
| voice | Config declares enablement; no separate voice transport exists | ✅ local speech recognition/synthesis around normal composer | ✅ local speech recognition/synthesis around normal composer | 🟡 implemented; permissions/device pass missing | 🟡 implemented; permissions/device pass missing | ✅ inherits platform-native availability | ✅ inherits platform-native availability | NATIVE partial | None | iOS/Android permission denial, interruption, and playback evidence |
| attestation | Optional opaque session field and capability only; proof shape is not declared | — | — | — | — | — | — | PROTOCOL shape validation only | None | ⛔ Server proof shape and enforcement policy decision |
| diagnostics/logging | Client rule: structured and content/credential-free | ✅ safe logger; default `off` | ✅ safe logger; default `OFF` | — | — | ✅ native level forwarding and safe error conversion | ✅ native level forwarding and safe error conversion | NATIVE, BRIDGE, HYGIENE | IOS-SIM partial | Merchant release-host setting and full journey log-redaction review |

## Evidence catalog

| ID | Evidence |
| --- | --- |
| NATIVE | Core-freeze commit `f402ddd`; attachment seam validation: Android `testDebugUnitTest` 112/112 and iOS `swift test` 108/108 on 2026-07-24 |
| PROTOCOL | Canonical TypeScript mirror and language-neutral fixtures under [`packages/protocol`](../packages/protocol) |
| BRIDGE | Typed facade and native-adapter source tests under [`packages/react-native/test`](../packages/react-native/test) and [`packages/flutter/test`](../packages/flutter/test) |
| HYGIENE | Repository hygiene checks defined in the root [`package.json`](../package.json) |
| IOS-UNIT | iOS unit coverage included in NATIVE; no equivalent Android behavior is claimed |
| IOS-SIM | Synthetic anonymous and identified-customer iPhone 17 Pro / iOS 26.4 evidence dated 2026-07-24 in the [0.1.0 conformance report](release-conformance-0.1.0.md#ios-simulator-e2e-evidence) |
| ANDROID-FCM | Native Android FCM registration and notification delivery were verified end to end by the project owner. Provider credentials, token values, and device-specific artifacts remain outside the repository. |

## Release rule

A row is release-complete only when its blocker is empty and its applicable
native, wrapper, automated, and physical-device cells have evidence. A wrapper
never compensates for an incomplete native row.
