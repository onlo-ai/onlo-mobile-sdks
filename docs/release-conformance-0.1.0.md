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

## Push and publication boundary

Push only the existing server `feature/mobile-sdk` branch and mobile `dev`
branch after review. Create no tag until the repository URL/tag owner is
approved. Do not publish, deploy, enable a target, or copy installation
coordinates into customer-facing surfaces from this manifest.

Next: run the isolated QA and physical-device qualification after external
inputs are approved.
