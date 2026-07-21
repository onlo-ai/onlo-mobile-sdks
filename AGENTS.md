# Agent instructions

Workspace overview: [README.md](README.md). Product/integration details: [docs/](docs/).

## Guardrails

- Never commit, push, merge, tag, publish, deploy, release, alter GitHub settings, or change remotes without explicit user approval.
- Never commit/read/print secrets, `.env*`, JWTs, chat/push tokens, real customer PII, message text, or attachment URLs.
- Do not modify the Onlo server, database, migrations, or server contracts from this repository.
- Do not invent protocol fields. If server behavior and [API contract](docs/api-contract.md) differ, stop and resolve the contract first.
- No AsyncStorage/plain files/JS-Dart state/logs for credentials or identified data. Native protected storage only.
- Keep User A’s state inaccessible before User B can use the SDK after logout/account switch.

## Key decisions

- Mobile reuses the WebChat AI pipeline. Refer [architecture](docs/architecture.md).
- SDK key = public Operator integration key; it is not customer identity or a signing secret.
- Operator backend mints short-lived JWT; SDK calls `loginIdentifiedUser({ userJwt })`. No mobile OTP or second login.
- iOS/Android own session, outbox, storage, lifecycle, push, permissions, UI. React Native/Flutter are thin bridges.
- One stable `clientMessageId` survives every retry. Image-only v1: JPEG/PNG/WebP, 8 MiB each, max 3/message.
- The moved React Native code is a prototype, not publishable. Refer [delivery plan](docs/delivery-plan.md).

## Engineering rules

- Read relevant code and contracts before editing. Make the smallest complete change.
- Prefer simple direct code; no speculative abstractions, duplicate implementations, silent fallbacks, or fake/stubbed features.
- Use strict types; validate all untrusted input at boundaries; keep public APIs consistent across platforms.
- Update canonical docs/contracts with public API or wire-shape changes.
- Keep logs structured and PII-free: safe error code, request ID, SDK/runtime version, duration.
- Preserve unrelated changes. Fix root causes; do not patch symptoms.

## Commands

```bash
git status --short --branch
npm install
npm run typecheck
npm run test:protocol-fixtures
npm run test:conformance
npm run test:hygiene
npm run check:hygiene
```

Run focused checks after changes, including package-specific commands once that package is present; report commands and results. Do not publish or deploy.

## Git

- `main`: release branch. `dev`: integration branch. Feature branches start from `dev`.
- Keep `node_modules`, build outputs, IDE state, and local configuration ignored.
