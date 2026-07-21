# iOS example

The native host-app sample is intentionally deferred until the messenger presentation adapters land. It must obtain a short-lived user JWT from its own authenticated backend and pass it only to `loginIdentifiedUser(userJwt:)`; it must not contain an Onlo signing secret or persist the JWT.

For the current Swift Package foundation, the SDK owns its Keychain credential boundary and transactional encrypted SQLite store. The host supplies only the public SDK key and short-lived user JWT; it does not override the API endpoint, app identifier, access-token storage, or persistence implementation. Production uses `https://onlo.ai`; a staging build requires an explicit release-configured HTTPS origin. Do not use the package’s in-memory test stores in an app target.
