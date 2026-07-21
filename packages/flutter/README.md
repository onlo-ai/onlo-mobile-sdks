# `onlo_flutter`

`onlo_flutter` is a typed Flutter facade over the iOS and Android Onlo cores. It owns no session, credential, outbox, transcript, push registry, or messenger UI state.

The public surface is `Onlo.initialize`, anonymous or identified login, `present`, `dismiss`, `logout`, push-token forwarding, and state observation. A native implementation must register the bridge; the facade fails with a typed bridge-unavailable error rather than falling back to Dart storage or transport.

Its wire behavior is defined by [`@onlo/protocol`](../protocol/src/index.ts).
