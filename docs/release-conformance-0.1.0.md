# Mobile SDK v0.1.0 conformance report

Status: **not approved for release**

This report records the automated evidence for the v0.1.0 candidate. It does
not convert simulator, source-adapter, or unit-test evidence into physical
device evidence. The canonical capability status remains the
[feature matrix](feature-matrix.md), and the one shared journey definition is
[`release-scenarios-v1.json`](../conformance/release-scenarios-v1.json).

## Candidate identity

| Item | Value |
| --- | --- |
| Candidate version | `0.1.0` |
| Core freeze | `f402ddd` |
| Server protocol | v1, unchanged |
| Public client APIs | Unchanged by Core freeze; image option retained but disabled |
| Persistence schema | Unchanged |
| Release decision | Blocked pending the dependencies and approvals below |

## Automated conformance

| Scenario | iOS native | Android native | React Native | Flutter | Physical device |
| --- | --- | --- | --- | --- | --- |
| Anonymous chat | Core/unit pass | Core/unit pass | Native delegation pass; host journey pending | Native delegation pass; host journey pending | Pending |
| Identified history | Core/unit pass | Core/unit pass | Native delegation pass; host journey pending | Native delegation pass; host journey pending | Pending |
| A logout then B isolation | Deterministic Core pass | Deterministic Core pass | Native delegation pass; host journey pending | Native delegation pass; host journey pending | Pending |
| Offline enqueue/restart/reconnect | Deterministic Core pass | Deterministic Core pass | Inherits native; host journey pending | Inherits native; host journey pending | Pending |
| Stable-ID duplicate suppression | Deterministic Core pass | Deterministic Core pass | Inherits native; host journey pending | Inherits native; host journey pending | Pending |
| ACCEPTED interruption/reconciliation | Deterministic Core pass | Deterministic Core pass | Inherits native; host journey pending | Inherits native; host journey pending | Pending |
| SSE disconnect/refetch | Deterministic Core pass | Deterministic Core pass | Lifecycle forwarding pass; host journey pending | Lifecycle forwarding pass; host journey pending | Pending |
| Unread/read ordering | Deterministic Core pass | Deterministic Core pass | Aggregate mapping pass; host journey pending | Aggregate mapping pass; host journey pending | Pending |
| Config refresh/LKG | Core/unit pass | Core/unit pass | Inherits native; host journey pending | Inherits native; host journey pending | Pending |
| FAQ/Help rendering | Native logic/build pass; interaction pending | Native logic/build pass; interaction pending | Native presentation only | Native presentation only | Pending |
| Image boundaries | Send path safely disabled | Send path safely disabled | Inherits disabled native path | Inherits disabled native path | Contract-blocked |
| Push registration/open/logout isolation | Deterministic Core pass | Deterministic Core pass | Typed forwarding pass; provider journey pending | Typed forwarding pass; provider journey pending | Pending |
| Deep-link authorization | Core/unit pass | Core/unit pass | Identifier forwarding pass; host journey pending | Identifier forwarding pass; host journey pending | Pending |
| Permission denial | Build pass; interaction pending | Build pass; interaction pending | Native UI only | Native UI only | Pending |
| Log redaction | Native unit pass | Native unit pass | Safe conversion/source pass | Safe conversion/source pass | Pending review |

An adapter row marked “pass” proves mapping and absence of wrapper-owned
business state. It is not evidence that a React Native or Flutter host executed
the native journey.

## Test results

| Boundary | Command | Result |
| --- | --- | --- |
| Android phase boundary | `packages/android/gradlew -p packages/android testDebugUnitTest` | 110 passed, 0 failed |
| iOS phase boundary | `swift test --package-path packages/ios` | 107 passed, 0 failed |
| React Native bridge | `npm --prefix packages/react-native test` | 17 passed, 0 failed |
| Flutter bridge | `(cd packages/flutter && flutter test)` | 8 passed, 0 failed |
| Shared release scenarios | `npm run test:conformance` | 3 passed, 0 failed |
| Protocol fixtures | `npm run test:protocol-fixtures` | 8 passed, 0 failed |
| TypeScript | `npm run typecheck` | Passed |
| Hygiene | `npm run test:hygiene && npm run check:hygiene` | 4 passed, 0 failed; repository scan passed |

## Physical-device matrix

| Surface | iOS | Android | Required evidence |
| --- | --- | --- | --- |
| Native | Pending | Pending | All shared scenarios, APNs/FCM, background recovery, permissions, accessibility |
| React Native | Pending | Pending | Release-mode host using exactly one linked native Core |
| Flutter | Pending | Pending | Release-mode host using exactly one linked native Core |

Existing iPhone simulator evidence is useful development evidence, but it does
not satisfy any physical-device cell.

## Artifact status

| Artifact | Candidate version | Status |
| --- | --- | --- |
| iOS native | `0.1.0` | Source package only; signed distribution artifact pending |
| Android native | `0.1.0` candidate | Local release AAR built; Maven coordinates, publication signing, and repository are pending |
| React Native | `0.1.0` | Private local tarball built; publication and native host builds pending |
| Flutter | `0.1.0` | `publish_to: none`; publication and native host builds pending |

Do not place unpublished local paths in dashboard installation snippets.
Canonical install commands can only be finalized after repository coordinates
and package names are approved:

```text
iOS: add the approved tagged Swift Package URL and exact 0.1.0 version
Android: implementation("approved.group:onlo-android:0.1.0")
React Native: npm install @onlo/react-native@0.1.0
Flutter: flutter pub add onlo_flutter:^0.1.0
```

The Android coordinate is deliberately a placeholder description, not an
invented install command.

Local, unpublished candidate outputs:

| File | SHA-256 |
| --- | --- |
| `/tmp/onlo-release-0.1.0/onlo-android-0.1.0.aar` | `9c6bc06c023cb414ff75ff1c5f48cb15081952fc392c006492594c5aabee369c` |
| `/tmp/onlo-release-0.1.0/onlo-react-native-0.1.0.tgz` | `a1dd496a1c59db7850d654e149cd8349639741abc6b6cf06083dd3d13380148e` |

These files are unsigned local candidates, not approved distribution
artifacts. No iOS or Flutter release archive was manufactured because the
required signed distribution configuration is absent.

## Remaining blockers by dependency

1. **Server/product contract:** define attachment-to-conversation binding before
   enabling images; define attestation proof shape and enforcement policy.
2. **Release engineering:** approve package coordinates, public repositories,
   signing identities, signing custody, and version/tag ownership.
3. **Host builds:** compile release-mode native, React Native, and Flutter hosts
   on both platforms with one native Core per app.
4. **Physical devices:** execute every shared scenario, including APNs/FCM,
   permissions, background recovery, accessibility, and log inspection.
5. **Controlled service access:** approve a pilot target, public/review release
   state, synthetic accounts, and rollback owner.
6. **Publication:** sign, publish, verify clean-host install commands, then copy
   those exact verified commands into the dashboard.

## Approval and deployment actions

No deployment action is authorized by this report. Release requires all of:

1. Server owner approves the image and attestation contract decisions.
2. Security/release engineering approves Apple and Android signing identities,
   package repositories, and credential custody.
3. SDK owner approves the final version, tag, checksums, and clean-host install
   verification.
4. QA approves the completed six-cell physical-device matrix.
5. Product/server operations approve the pilot target and rollback operator.
6. Package owners approve publication to Swift Package distribution, Maven,
   npm, and pub.dev.
7. Dashboard owner replaces draft snippets only with the four verified
   published install commands.

## Pilot and rollback controls

Enable one synthetic pilot target only after publication and device approval.
Keep the server mobile release state disabled for every other target. During
the pilot, monitor only redacted request/error metadata. On any account-boundary
or accepted-message invariant failure, disable the pilot target, hide native
messenger entry points through the approved server release control, preserve
durable data for diagnosis, and roll clients back to the last approved package
versions. Never fall back to the legacy prototype or a wrapper-owned transport.
