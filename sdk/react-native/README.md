# `@onlo/react-native`

This directory contains the React Native prototype moved from the Onlo server repository. It is source material for the native-bridge implementation; it is **not yet a publishable SDK**.

Do not use its old pure-TypeScript API or its AsyncStorage fallback as a production integration. The approved public API, identity model, supported media, native security requirements, and configuration behavior are defined in this repository:

- [Mobile integration guide](../../docs/integration-guide.md)
- [v1 API contract](../../docs/api-contract.md)
- [Client delivery plan](../../docs/delivery-plan.md)

The release package name is `@onlo/react-native`. The finished package will be a thin facade over native iOS and Android SDK cores, rather than a separate JavaScript session/outbox implementation.
