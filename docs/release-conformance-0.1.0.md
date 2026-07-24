# Mobile SDK 0.1.0 release manifest

Version-controlled engineering and automated qualification are complete.
Physical devices, external signing, publication, QA deployment, and customer
pilot approval remain pending.

## Candidate identity

| Field | Recorded value |
| --- | --- |
| Server baseline | `50725e7` |
| Mobile baseline | `6715381` |
| Release preparation | The commit containing this manifest |
| Protocol | Mobile SDK v1 |
| Package version | `0.1.0` |
| Example revision | The commit containing this manifest |
| Public API, protocol, persistence | Frozen; unchanged by release preparation |

## Readiness state

| Boundary | State | Evidence |
| --- | --- | --- |
| Engineering | Complete | Four existing examples are version-controlled release hosts; package metadata and CI qualification are present. |
| Automated validation | Complete | Full native suites, wrapper suites, package builds, package-content checks, and six release-mode example builds pass. |
| Physical validation | Pending | No physical iOS or Android device was available. |
| Signing | Pending | Local outputs are unsigned; no distribution identity is approved. |
| Publication | Pending | Repository URLs, Maven coordinates, npm ownership, and pub.dev publisher are unapproved. |
| QA deployment | Pending | An isolated mobile QA target is not provisioned. |
| Customer pilot | Blocked | Physical, signing, publication, and isolated-QA gates remain open. |

## iOS Simulator E2E evidence

This evidence is limited to an iPhone Simulator. It does not satisfy any
physical-device, signing, publication, production-release, or pilot gate.

| Field | Simulator evidence |
| --- | --- |
| Evidence date | 2026-07-24 |
| Device | iPhone 17 Pro Simulator |
| OS | iOS 26.4 |
| Server revision | `57a5acbbf161dbc263148a5852401d4e6d97b72c` |
| Mobile repository baseline | `e4ee858b48eea47a447b8cab86eb8af9e78bb9cb` |
| Environment | Local server with synthetic Operator/customer data and Simulator-trusted HTTPS |
| PII-free screenshot | `/private/tmp/onlo-merchant-test/screenshots/ios-04-fresh-17pro.png` |
| PII-free SDK log | Simulator app container: `Library/Caches/onlo-e2e-diagnostics.log` |
| PII-free proxy log | `examples/merchant-backend/.local/merchant-backend.log` |

| Simulator behavior | Result | Evidence |
| --- | --- | --- |
| Anonymous bootstrap | Pass | Session success `31c2d5ee-3eaf-4c07-b75f-470b0b8d596e`; later resume `a617a9a9-a04b-4cdb-b405-78b2cb4a1b57` |
| Installation/device continuity after reopen | Pass | Resume succeeded on the same Simulator installation; configuration returned not-modified |
| Server connectivity | Pass | Session, configuration, foreground stream, Help Center, inbox, and transcript operations succeeded |
| Customer message acceptance | Pass | Synthetic message appeared once in the authorised Operator inbox |
| AI response and streaming delivery | Pass | Simulator UI received the assistant response through the native chat stream |
| Transcript persistence | Pass | Authoritative transcript refetch `5f1b2dd4-4a54-4504-b44e-e8e9abd69e24` succeeded after reopen |
| Conversation-list persistence | Pass | Authoritative inbox refetch `0e803343-3a2b-4c2c-bb9a-3a06381f4b78` returned the existing conversation |
| Reopen existing conversation | Pass | Closing and reopening Support exposed the existing list row and transcript |
| No duplicate conversation creation | Pass | Reopen retained one conversation for the synthetic anonymous installation |
| Anonymous history isolation | Pass | No identified or unrelated-session history appeared in the anonymous list or transcript |

| Safe operation | Request ID |
| --- | --- |
| Initial anonymous session | `31c2d5ee-3eaf-4c07-b75f-470b0b8d596e` |
| Initial configuration | `908d1d9f-54ce-48e2-9e54-909ba59cad70` |
| Initial Help Center | `6159ab1a-709a-40cb-9a80-5c746fa2bf59` |
| Initial inbox | `c0be56cb-bac2-41dc-94f5-ee3b6f7fa0b0` |
| Reopen/resume session | `a617a9a9-a04b-4cdb-b405-78b2cb4a1b57` |
| Reopen Help Center | `b80f68c9-b02f-4790-ada4-31964fbcff9f` |
| Reopen inbox | `0e803343-3a2b-4c2c-bb9a-3a06381f4b78` |
| Reopened transcript | `5f1b2dd4-4a54-4504-b44e-e8e9abd69e24` |

### Identified-customer IDV Simulator evidence

This is identity-verification evidence from the same iPhone Simulator and
synthetic environment described above. It verifies the merchant-backend JWT
boundary and the identified SDK journey; it is not physical-device or
production-identity-provider evidence.

| Simulator behavior | Result | Evidence |
| --- | --- | --- |
| Merchant identity boundary | Pass | The merchant backend recorded `merchant_login requested` then `issued_jwt`; no signing secret or JWT was written to the client diagnostics |
| Anonymous-to-identified transition | Pass | Anonymous Support closed before login; SDK initialization and identify completed under the replacement authority |
| Server identity resolution | Pass | Identified session exchange `41cdb6df-5fea-482d-bdc0-9e5df514cd28` succeeded before Support became ready |
| Configuration under identified authority | Pass | Configuration returned not-modified after the identified session exchange |
| Authorized identified history | Pass | Inbox `f3c32a5f-a393-4cd1-b062-bd8736a4a39c` and transcript `ddc3a272-346c-461b-b3ba-873b4e180785` succeeded |
| Read acknowledgement | Pass | Four identified read acknowledgements succeeded, including the post-message acknowledgement |
| Identified message acceptance | Pass | One queued send produced `accepted_received` and `accepted` under request `f363d08c-4130-4e26-adf8-866079cd7fe2` |
| AI streaming and completion | Pass | The same request completed after the foreground stream connected |
| Durable reconciliation | Pass | Read-only SQLite evidence contains one identified outbox row in `reconciled`, with one attempt and no retry deadline |
| Reopen continuity | Pass | Closing and reopening Support presented the identified messenger and reused its owner-scoped inbox |
| Owner isolation | Pass | Persistence metadata contains only the current unblocked identified owner scope; the earlier anonymous scope is not exposed after binding |

| Safe operation | Request ID |
| --- | --- |
| Identified session exchange | `41cdb6df-5fea-482d-bdc0-9e5df514cd28` |
| Identified Help Center | `db4372ef-c390-4f5c-b5a3-2cb14f8395d4` |
| Identified inbox | `f3c32a5f-a393-4cd1-b062-bd8736a4a39c` |
| Initial identified transcript | `ddc3a272-346c-461b-b3ba-873b4e180785` |
| Initial identified read acknowledgement | `69a8aac3-0207-47c7-946d-6738fa277c3a` |
| Transcript refresh | `8eb3118a-7954-4efa-a8f1-d0f4a42c4f06` |
| Second read acknowledgement | `28efdfb3-520b-4d6f-b4b3-eebae663f86f` |
| Final pre-send transcript refresh | `0f9730d2-ea90-4131-ab50-03c90cf8be9e` |
| Final pre-send read acknowledgement | `ba93a343-40f7-4345-9186-ea97f221d67b` |
| Identified chat acceptance/completion | `f363d08c-4130-4e26-adf8-866079cd7fe2` |
| Post-message read acknowledgement | `d0273ba2-140c-4dfa-ac23-2f865d2fdc1b` |

## Example hosts

| Host | Version-controlled path | Demonstrated boundary | Release build |
| --- | --- | --- | --- |
| Native iOS | `examples/ios-local-e2e` | Anonymous/identified identity, native messenger/media, APNs/notification/deep-link forwarding, logout, native lifecycle | Pass, unsigned |
| Native Android | `examples/android` | Anonymous/identified identity, native messenger/media, FCM/notification/deep-link forwarding, logout, native lifecycle | Pass, unsigned |
| React Native | `examples/react-native` | Host-only configuration/token exchange plus typed forwarding to one native Core on iOS and Android | Pass on both, unsigned |
| Flutter | `examples/flutter` | Host-only configuration/token exchange plus typed forwarding to one native Core on iOS and Android | Pass on both, unsigned |

The wrappers contain no Onlo credential store, transport, transcript, outbox,
retry scheduler, or independent chat UI.

## Package qualification

| Package | Qualification result | Publication restriction |
| --- | --- | --- |
| SwiftPM `OnloSDK` | Manifest description/resolution, release build, full tests, and native host build pass from isolated scratch state. | Approved repository URL and `0.1.0` tag owner pending. |
| Android Core | Release AAR, sources JAR, POM, isolated Maven publication, and clean Maven-only consumer pass. | `ai.onlo.unpublished` is qualification-only; public group/artifact/repository pending. |
| `@onlo/react-native` | Tests, exports, peer metadata, 14-file `npm pack`, and clean tarball consumers on iOS/Android pass. | `private: true`; npm owner and native publication coordinates pending. |
| `onlo_flutter` | Analysis, tests, package dry-run, and clean packaged-source consumers on iOS/Android pass. | `publish_to: none`; pub.dev publisher approval pending. |

## Release size, shrinker, and warning qualification

Matched temporary hosts were built from mobile revision `c9dd5fb` on
2026-07-24. Outputs are unsigned local evidence; they do not predict App Store
or Play download size after signing, compression, or thinning.

| Platform | Baseline | Onlo host | Increment | Result |
| --- | ---: | ---: | ---: | --- |
| Android optimized Release APK | 741,259 bytes | 1,096,734 bytes | 355,475 bytes (347.1 KiB) | Accepted for RC `0.1.0` |
| iOS arm64 Release executable | 87,312 bytes | 3,841,040 bytes | 3,753,728 bytes (3.58 MiB) | Accepted for RC `0.1.0` |

| Check | Result | Evidence |
| --- | --- | --- |
| Android R8 | Pass | `minifyReleaseWithR8` completed with an empty host rules file and the SDK's shipped `consumer-rules.pro`. |
| Public Android API retention | Pass | R8 seeds and APK analysis retain `ai.onlo.sdk.Onlo` and `ai.onlo.sdk.OnloClient`. |
| Android dependency/class conflicts | Pass | `releaseRuntimeClasspath`, duplicate-class checking, lint-vital, and optimized packaging completed. |
| iOS package/link conflict | Pass | Matched generic-device Release builds completed with and without the local Swift package. |
| Android warnings | Reviewed | Nine existing deprecated platform-Fragment API warnings; no dependency, R8, linkage, or duplicate-class failure. |
| iOS warnings | Reviewed | One SDK-host unused-result warning; two orientation/launch-screen host warnings also occurred in the baseline. |

| Local evidence | SHA-256 |
| --- | --- |
| Android baseline APK | `f1effb939ee833b9974da96a9607daf9d3ababbe8c2bb014cf9645e574e87670` |
| Android Onlo APK | `3a0a0a4b60dc8805abffe094ab2c06d65f66b6aec92f10e955301f56e6403f65` |
| iOS baseline executable | `689bf9eb2532aec57aee978cadf3d947f81eb0d5cf7909d20e1fbb71830b81aa` |
| iOS Onlo executable | `21d0eabc48b64bd4ee6954e6127e655c45a51c7a687aabd6140692a766e5f480` |

The temporary qualification tree is
`/private/tmp/onlo-release-qualification`. No generated build output is
version-controlled.

## Local qualification artifacts

These files are local evidence only. APKs and iOS executables are unsigned;
none is distributable.

| File | SHA-256 |
| --- | --- |
| `onlo-android-sdk-0.1.0.aar` | `b4b0607e440c69d9656ba5a001f328c9583c06f2e7ebeae617e8a107537d8e87` |
| `onlo-react-native-0.1.0.tgz` | `20638060fdb76f673253596c416c7a148baf2553cdf17b4179db2dacb1894e4a` |
| `onlo-native-ios-example-0.1.0-unsigned` | `affa4334d53232e2a62221dc7f5d116841486878c331b414d71be687b14c8353` |
| `onlo-native-android-example-0.1.0-unsigned.apk` | `bc4907952b73a3135bb6bcea8d917a63ab8df95bb85bec0425ee8e86cf914cbb` |
| `onlo-rn-ios-example-0.1.0-unsigned` | `792b9a609bfe6c6a09e6b8f4b2fad0632b17f5feab4d77345650fb7ee95a023d` |
| `onlo-rn-android-example-0.1.0-unsigned.apk` | `6aa6e0ff54ff406985cc3ecca880edc7ed042d39a9759a4887e80d0191e0b91a` |
| `onlo-flutter-ios-example-0.1.0-unsigned` | `533ed1245aa9f6b04db64c77c8b8c249424343fd59c4de3833f41bf65992c15c` |
| `onlo-flutter-android-example-0.1.0-unsigned.apk` | `d512d621f7b89012252db9a3afbf91757410bfb476bcbbaa8c6dd3f34495ed6c` |

## Clean-consumer commands

| Boundary | Exact command |
| --- | --- |
| SwiftPM | `swift package --package-path packages/ios --scratch-path /tmp/onlo-swift-clean resolve && swift build --package-path packages/ios -c release --scratch-path /tmp/onlo-swift-clean` |
| Android publication | `packages/android/gradlew -p packages/android publishReleasePublicationToQualificationRepository -Ponlo.maven.repository=/tmp/onlo-maven` |
| Android consumer | `ANDROID_HOME=<ANDROID_SDK> packages/android/gradlew -p /tmp/onlo-android-consumer :consumer:assembleRelease` |
| React Native tarball | `npm_config_cache=/tmp/onlo-npm-cache npm pack --pack-destination /tmp/onlo-packages packages/react-native` |
| React Native host | `npm install /tmp/onlo-packages/onlo-react-native-0.1.0.tgz --save-exact`, followed by the checked-in host iOS/Android build commands |
| Flutter dry-run | `(cd packages/flutter && dart pub publish --dry-run)` |
| Flutter source consumer | Point the checked-in host dependency at the copied package source, then run `flutter build apk --release` and `flutter build ios --release --no-codesign`. |

Temporary consumers resolve native Core from only the isolated Maven
repository on Android and one local `OnloSDK` pod on iOS. Those qualification
locations are not customer installation coordinates.

## Required external inputs

| Input | Owner/approval still required |
| --- | --- |
| Apple signing | Development/distribution team, certificate, provisioning profile, bundle entitlement approval |
| Android signing | QA/release keystore, alias, custody, and signing procedure |
| SwiftPM | Approved repository URL, tag owner, and permission to push `0.1.0` |
| Maven | Final group/artifact/repository, publisher identity, credentials, and signing |
| npm | Approved scope/package owner, access token, provenance policy, and removal of `private` |
| pub.dev | Approved publisher, account ownership, and removal of `publish_to: none` |
| Push providers | QA APNs/FCM credentials and provider dashboards |
| QA service | Isolated mobile target, synthetic SDK key/accounts, release state, and rollback operator |

## Physical-device gate

The canonical scenarios remain
[`release-scenarios-v1.json`](../conformance/release-scenarios-v1.json).
Native iOS, native Android, RN iOS/Android, and Flutter iOS/Android physical
cells are pending. Simulator or unsigned build evidence does not satisfy this
gate.

| Remaining gate | State |
| --- | --- |
| Physical camera, media picker, and denial/allow permission journeys | Pending |
| Physical microphone, speech, interruption, and denial journeys | Pending |
| Physical APNs/FCM delivery, open, and logout isolation | Pending |
| Physical background/foreground execution and process-lifecycle recovery | Pending |
| External iOS/Android signing approvals and signed artifacts | Pending |
| SwiftPM, Maven, npm, and pub.dev publication approvals | Pending |
| Customer pilot approval and target enablement | Blocked |

## Push and publication boundary

Push only the existing server `feature/mobile-sdk` branch and mobile `dev`
branch after review. Create no tag until the repository URL/tag owner is
approved. Do not publish, deploy, enable a target, or copy installation
coordinates into customer-facing surfaces from this manifest.

Next: run the isolated QA and physical-device qualification after external
inputs are approved.
