# SDK-team local merchant-backend simulator

This local-only HTTPS service is SDK-team test infrastructure. It has one fixed non-PII local test subject and accepts a local test login code, then creates the short-lived HS256 user JWT that a local Onlo service validates. It is not a merchant integration surface, part of the SDK, the Onlo server, or a production backend.

Merchant iOS developers use only the [iOS merchant integration](../ios/README.md): public SDK key, authenticated-backend callback, and host-controlled presentation.

| `NODE_ENVIRONMENT` | Behaviour |
| --- | --- |
| `development` | Starts the fixed-user local backend and HTTPS proxy. |
| `production` | Refused. This harness must never impersonate a production merchant backend. |

## Prerequisites

- [ ] Node.js 20 or later.
- [ ] A local Onlo service configured to accept the public SDK key, the iOS bundle ID, and the same local mobile-identity signing secret.
- [ ] A private `.env.local` containing the local Onlo connection values. It is ignored and is never read by repository tooling.

## Flow

| Step | Caller | Local-only result |
| --- | --- | --- |
| 1 | iOS E2E host | Sends the manually entered local login code to `POST /v1/test-login`. |
| 2 | Merchant simulator | Verifies the code, selects its fixed local test subject, and returns a five-minute in-memory merchant session, public SDK configuration, and a 180-second user JWT. |
| 3 | iOS SDK | Exchanges the proof with the explicit local Onlo HTTPS origin, then discards the JWT. |

The simulator never logs the login code, merchant session, signing secret, JWT, or customer data. The iOS host keeps the merchant session and user JWT in memory only.

## Start locally

1. Create the private local configuration once.

   ```bash
   cp local-env.example .env.local
   ```

   Keep `NODE_ENVIRONMENT=development`, then replace the four placeholder values in `.env.local` with the matching local Onlo values. `ONLO_DEVELOPMENT_ORIGIN` may be your existing HTTP local server origin; `npm start` wraps it in a local HTTPS proxy for the SDK. Do not commit, paste, or share that file.

   Expected result: values remain in the ignored local file; no shell exports are required.

2. Start the simulator from this directory, or run `npm start` from the repository root.

   ```bash
   npm start
   ```

   Expected result: the launcher generates an ignored seven-day localhost TLS certificate when missing, then starts the merchant backend on `https://127.0.0.1:8444` and an HTTPS proxy to local Onlo on `https://127.0.0.1:8443`.

   The console prints the ignored safe diagnostics file:
   `.local/merchant-backend.log`. It contains only operation names, route
   categories, and HTTP/error codes; it never contains request bodies, login
   input, secrets, JWTs, headers, or customer data.

3. Open the [installable iOS E2E host](../ios-local-e2e/README.md) and run it. Its Debug build adds the generated certificate to the selected simulator automatically.

   Expected result: the host gets its public SDK configuration and short-lived proof only after local merchant login; neither is embedded in the app source.

## Test command

```bash
npm test
```

Expected result: the isolated signing test validates the fixed HS256 algorithm, audience, opaque synthetic subject, and 180-second lifetime. It does not start a server or read local configuration.

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| iOS refuses either local endpoint | The endpoint is not HTTPS or its certificate is not trusted by the simulator. | Use the exact HTTPS origin and trust only the local development certificate in the simulator. |
| Onlo rejects identification | The local Onlo service has a different signing secret, SDK key, bundle ID, or JWT policy. | Compare those four server-side local settings without exposing values in the app or repository. |
| Backend returns `401` | The one-time local login code is wrong or the temporary merchant session expired. | Enter the local code again and retry; do not make the SDK retry an identity proof automatically. |
| A real customer value appears | Unsafe test setup. | Stop the run, remove the datum through the approved process, and use the fixed synthetic test subject. |

Next: run the iOS local full-stack checklist in the development and go-live guide.
