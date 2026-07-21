---
name: onlo-mobile-sdk-development
description: Build, review, or extend the Onlo iOS, Android, React Native, Flutter, protocol, conformance, and example workspaces. Use when changing mobile SDK behavior, the v1 wire contract, native bridge APIs, secure session/outbox handling, or mobile integration documentation in this repository.
---

# Onlo Mobile SDK Development

Build one mobile product through two native cores. Keep React Native and Flutter as typed, thin bridges.

## Required reads

1. Read `AGENTS.md`, `docs/api-contract.md`, `docs/architecture.md`, and the relevant delivery-plan section before editing.
2. Read `packages/protocol` and matching `contracts/v1` fixtures before changing transport or public APIs.
3. Read the affected native package, bridge, example, and conformance scenario before extending them.

## Contract gate

- Treat `docs/api-contract.md` and `packages/protocol` as the client/server source of truth.
- Do not modify the server, its database, migrations, endpoints, or server contract from this repository.
- Do not invent wire fields or silently adapt a legacy prototype. Stop and request the exact server-approved shape when the contract is incomplete or inconsistent.
- Add canonical protocol types, language-neutral fixtures, and conformance scenarios before implementing a newly confirmed flow.

## Security and ownership

- Keep the public SDK key distinct from customer identity and all signing secrets.
- Accept a short-lived `userJwt` only for exchange; never sign or persist it.
- Keep rotating credentials only in Keychain or Keystore-backed native storage. Do not store credentials or identified data in AsyncStorage, plain files, JavaScript/Dart state, or logs.
- Use one durable `clientMessageId` for every retry. Partition transcript, outbox, read state, and push state by anonymous generation or verified identity; revoke and hide User A before User B can use the SDK.
- Keep logs structured and PII-free: safe error code, request ID, SDK/runtime version, and duration only.

## Delivery sequence

1. Complete contract coverage and conformance vectors first.
2. Implement iOS and Android native cores against the same vectors.
3. Add React Native and Flutter as typed bridge-only facades over those cores; do not retain the moved pure-TypeScript prototype as a fallback.
4. Add host-app examples with no embedded signing secret and run cross-platform conformance before release work.

Parallelize platform work only after the shared base is exact and each task has disjoint files. Keep all platform public APIs and state transitions equivalent.

## Execution and verification

- Prefer small, complete changes; preserve unrelated work; never commit, push, publish, deploy, or alter GitHub configuration without explicit approval.
- Use Terra with low effort for mechanical changes, medium effort for ordinary implementation, and high or extra-high effort for complex state, security, or cross-platform work. Use Sol for review only when the user selects it.
- Run focused checks after edits: `npm run typecheck`, React Native typecheck/tests when relevant, and platform/conformance checks when their toolchains exist.
