# Legacy React Native prototype — do not integrate

This directory is an archived migration reference from the former pure-TypeScript implementation. It is not the Onlo React Native SDK and must not be linked, copied, or used as a runtime fallback.

To integrate React Native:

1. Open the supported [`@onlo-ai/react-native` guide](../../packages/react-native/README.md).

   Expected result: you install the public package that delegates session, secure storage, offline work, push, and UI to native iOS/Android cores.

2. Follow its **install → initialize → login → present → logout** sequence.

   Expected result: JavaScript remains a typed facade and contains no credential, transcript, or outbox source of truth.

3. Use the [React Native example](../../examples/react-native/README.md) for a local host build.

   Expected result: the app links exactly one supported native core on each platform.

The canonical behavior is defined by the [mobile integration guide](../../docs/integration-guide.md) and [v1 API contract](../../docs/api-contract.md).
