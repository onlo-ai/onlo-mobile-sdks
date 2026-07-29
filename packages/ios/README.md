# Onlo iOS SDK

Add native Onlo support to an iOS 15+ app with one lifecycle:
**initialize → login → present → logout**.

## Prerequisites

- [ ] iOS 15 or newer and an app target that can add Swift packages or CocoaPods.
- [ ] A public Mobile SDK key from Onlo Dashboard.
- [ ] A host-owned Support button or route and the active `UIViewController` that will present it.
- [ ] For signed-in support, an authenticated backend endpoint that returns a fresh Onlo user JWT.

## Concepts

| Term | Meaning |
|---|---|
| SDK key | Public key that selects your Onlo organisation/app integration. It is safe to include in the app and is not customer identity. |
| User JWT | Short-lived identity proof created by your backend after the customer signs in to your app. The iOS app passes it directly to Onlo. |
| `Onlo` | Application-scoped native SDK that owns protected session state, offline sends, transcript, push, and configuration. |
| Presenter | Your currently visible `UIViewController`; your app decides where and when the messenger opens. |

Do not put the user-JWT signing secret in the iOS app, build settings, property lists, or source control.

## Integration at a glance

| Call | When to use it | Result |
|---|---|---|
| 1. `Onlo.initialize(apiKey:)` | Once when the app starts | Connects this app to its Onlo organisation and restores protected state |
| 2. `Onlo.loginUnidentifiedUser()` or `Onlo.loginIdentifiedUser(userJwt:)` | After deciding whether your customer is signed in | Opens the correct anonymous or identified Onlo session |
| 3. `Onlo.present(from:)` | When the customer taps your Support button | Presents the native messenger from your chosen screen |
| 4. `Onlo.logout()` | Before your app logs out or switches customers | Revokes the current session and makes its protected state inaccessible |

## Step 1: Install the SDK

### Option A: Public installation

In Xcode, select **Add Package Dependencies**, enter
`https://github.com/onlo-ai/onlo-mobile-sdks`, and choose exact version
`0.3.0`.

For a manifest-based host:

```swift
.package(
    url: "https://github.com/onlo-ai/onlo-mobile-sdks.git",
    exact: "0.3.0"
)
```

Add the `OnloSDK` product once.

For CocoaPods:

```ruby
pod 'OnloSDK', '0.3.0'
```

Run `pod install`, then open the generated workspace. Use SwiftPM or CocoaPods
for a target, never both.

Expected result: `import OnloSDK` builds in the app target with exactly one package manager supplying the SDK.

### Option B: Repository development

1. Open the merchant app in Xcode.
2. Select **File → Add Package Dependencies**.
3. Select **Add Local**.
4. Choose `onlo-mobile-sdks/packages/ios`.
5. Add `OnloSDK` to the app target.

Expected result: `import OnloSDK` builds against the local repository source.

## Steps 2–5: Add the customer lifecycle

```swift
import UIKit
import OnloSDK // 1. Import the package added to your app target.

final class SupportViewController: UIViewController {
    @IBOutlet private weak var supportButton: UIButton!

    func startOnloForSignedInCustomer() async {
        do {
            // 2. Copy this from:
            // Onlo Dashboard → WebChat → Install → Mobile SDK
            //
            // Generate a key there first if needed.
            // This public key identifies your organisation/app integration.
            // It is not a customer identity or signing secret.
            try await Onlo.initialize(
                apiKey: "<PASTE_YOUR_PUBLIC_MOBILE_SDK_KEY_HERE>"
            )

            // 3. Your backend already knows the customer because they signed
            // in to your app. It returns a short-lived Onlo user JWT containing
            // the stable customer ID and optional name/email/phone attributes.
            let userJwt = try await fetchOnloUserJWT()

            // Pass the JWT directly to Onlo. Never save or log it.
            try await Onlo.loginIdentifiedUser(userJwt: userJwt)

            // Onlo is ready. Enable your app's Support button here.
            supportButton.isEnabled = true
        } catch {
            // Onlo must not block login to the rest of your app.
            supportButton.isEnabled = false
        }
    }

    @IBAction func supportTapped(_ sender: UIButton) {
        Task {
            // 4. `from: self` means: present from this ViewController.
            // Your app controls exactly where and when Onlo opens.
            try await Onlo.present(from: self)
        }
    }

    func logoutCustomer() async throws {
        // 5. Await Onlo before another customer can use the app.
        try await Onlo.logout()

        // Now call your own authentication manager to complete logout.
    }
}
```

For a customer who has not signed in, replace the JWT lines with:

```swift
// Use an installation-scoped anonymous Onlo session.
try await Onlo.loginUnidentifiedUser()
```

That is the complete normal integration. The remaining sections are optional.

Expected result: initialization prepares Support in the background, the selected login mode becomes ready, the messenger opens only from the host button, and logout completes before another customer uses Onlo.

## Why `try await`?

| Keyword | Why it is required |
|---|---|
| `await` | Initialization, identity verification, secure storage, logout, and presentation can perform asynchronous native/network work without blocking the UI |
| `try` | Network, configuration, identity proof, or protected-storage work can fail and must not be silently ignored |

Use these calls inside an existing async function or a `Task`.

## Identified users

### Why the app cannot mint the JWT

The Mobile SDK key is public and can be extracted from an app binary. If the
mobile SDK accepted only an email/name, a modified app could impersonate another
customer by submitting their identifiers.

The approved flow is:

1. The customer signs in to the merchant app.
2. The merchant app calls its authenticated backend.
3. The backend derives the customer from that authenticated session.
4. The backend creates a JWT using the Operator signing secret.
5. The app immediately passes the short-lived JWT to Onlo.

The JWT may contain:

- Stable opaque customer ID in `sub`
- `name`
- `email`
- `phone`
- `locale`
- Bounded custom attributes

Example merchant API request:

```swift
private struct OnloIdentityResponse: Decodable {
    let userJwt: String
}

func fetchOnloUserJWT() async throws -> String {
    var request = URLRequest(
        url: URL(string: "\(yourAPI)/api/onlo-identity")!
    )
    request.httpMethod = "POST"

    // This is your merchant-app access token—not an Onlo credential.
    // The backend uses it to determine which customer is signed in.
    request.setValue(
        "Bearer \(merchantAccessToken)",
        forHTTPHeaderField: "Authorization"
    )

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let http = response as? HTTPURLResponse,
          http.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }

    // Decode the backend response, not the JWT itself.
    // Return it directly; never persist or log it.
    return try JSONDecoder()
        .decode(OnloIdentityResponse.self, from: data)
        .userJwt
}
```

Then exchange it:

```swift
let userJwt = try await fetchOnloUserJWT()
try await Onlo.loginIdentifiedUser(userJwt: userJwt)
```

The backend—not this function—adds the stable customer ID, name, email, and
other approved claims before signing the JWT.

## Anonymous visitors

`Onlo.initialize(apiKey:)` creates or restores an anonymous session by default.
The app may also select that mode explicitly:

```swift
try await Onlo.loginUnidentifiedUser()
```

- The SDK generates an installation UUID automatically.
- Its rotating credential is stored in protected native storage.
- Anonymous conversations remain linked to that installation generation.
- No email, phone number, or other customer identifier is required.

When the customer later signs in, fetch a backend JWT and call
`loginIdentifiedUser(userJwt:)`. The server verifies the contact and transitions
the installation to an identified session.

The v1 contract does **not** currently guarantee that every historical anonymous
conversation will be merged into the contact record. Do not promise automatic
history merging until the server contract explicitly defines and tests it.

## Logout and user switching

Always start the Onlo account boundary when a customer signs out:

```swift
supportButton.isEnabled = false

do {
    // Makes the old Onlo owner inaccessible, unregisters its APNs association,
    // revokes/unlinks the session, and returns the installation to anonymous.
    try await Onlo.logout()

    // It is now safe to activate the next customer in Onlo.
    YourAuthManager.signOut()
} catch {
    // Keep Support disabled. The SDK retains a protected `logoutPending`
    // transition and must complete it before another Onlo customer can log in.
    scheduleOnloLogoutRetry()

    // Follow your app's own sign-out policy, but do not enable Onlo for the
    // next customer until `Onlo.logout()` completes.
}
```

Logout behavior:

1. Dismisses/redacts the previous messenger immediately.
2. Blocks the previous transcript and outbox before network work.
3. Durably unregisters the previous APNs association when one exists.
4. Revokes/unlinks the previous Onlo session.
5. Purges the previous owner partition after server confirmation.
6. Prevents a different customer from using Onlo while logout is pending.

> Skipping the account boundary can leave Support attached to the previous
> merchant customer. Always disable Support and call `Onlo.logout()` during
> logout or account switching.

## Presenting chat

Normal Support button:

```swift
try await Onlo.present(from: self)
```

`from` is required because iPad/multi-window apps may have several scenes. The
SDK must not guess which ViewController should present Support.

Open a known conversation after an authorised push/deep link:

```swift
try await Onlo.openConversation(
    conversationId,
    from: self
)
```

`conversationId` is optional for normal chat and required only when routing to
one existing conversation.

Normal presentation opens on Home, matching Onlo WebChat: greeting, up to three
recent conversations, up to three quick questions, composer, and Powered by
Onlo footer. Sending or selecting a conversation enters its thread; Back
returns Home instead of silently reopening the previous thread.

The composer follows the WebChat control order and dashboard gates: multiline
message input, optional voice, attachment, code and link controls, then the
send action. It stays pinned above the footer while the contained sheet adapts
to safe areas, keyboard changes, rotation, and multitasking size. Full-screen
presentation remains an explicit host option.
Every Home row is loaded from the authorised SDK inbox/configuration; the
shipping messenger contains no sample conversation or FAQ data.

An accepted identified JWT can personalize the greeting for the current SDK
runtime. The first name is memory-only, is cleared before logout/account
switch, and falls back to `Hi there 👋` after process restoration.

## Customization

Dashboard configuration controls the default colors, bot name, subtitle,
greeting, dark mode, FAQ quick actions, voice, and whether image upload is
available.

Restrict those defaults before presenting the messenger:

```swift
Onlo.configureMessenger(
    OnloMessengerOptions(
        colorMode: .system,              // Or `.light` / `.dark`
        allowsImageAttachments: false,   // App-level restriction
        presentationMode: .contained     // Or `.fullScreen`
    )
)
```

Call `configureMessenger` before opening Support. It restricts presentation
behavior but does not change the organisation's dashboard configuration.

### FAQ and Help Center

Dashboard **WebChat → Behaviour → FAQ quick actions** remains authoritative.
Home presents the first three questions. When published Help Center articles
exist, Browse all opens Help Center just like WebChat.
Answered FAQs render the Operator-authored answer directly without sending a
message, creating a conversation, or invoking AI.

Selecting an unanswered quick question sends it through the normal durable
composer and AI pipeline, matching WebChat.

Published Help Center content loads through the authenticated widget article
routes and renders directly. Disabling FAQs in the dashboard removes the FAQ
content after the next configuration refresh.

### Voice

Dashboard **WebChat → Behaviour → Voice input** controls both native voice
controls:

| Control | Native implementation | Server behavior |
|---|---|---|
| Microphone | Apple Speech recognition fills the normal message composer | The resulting text uses the existing chat request and durable outbox |
| Speaker | Apple speech synthesis reads AI replies after the customer opts in | No audio or voice session is sent to Onlo |

Voice is deliberately not a separate WebRTC mode. It is a native input/output
layer around the same text chat pipeline used by WebChat.

Add both usage descriptions to the merchant app's `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Use your microphone to dictate a support message.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>Convert your spoken support message into text.</string>
```

The SDK requests both permissions only after the customer taps the microphone.
The speaker is off by default, applies only to AI replies from the current send
cycle, and resets when the messenger is dismissed.

### Images

- Dashboard **File upload** is the shared source for WebChat and every Mobile
  SDK; per-target media controls are not used.
- The projected `features.fileUpload` and `mediaPolicy.enabled` must both be
  enabled.
- JPEG, PNG, and WebP contract types are supported.
- Dashboard controls `mediaPolicy.maximumImagesPerMessage` from 0 through 5.
- Dashboard controls `mediaPolicy.maximumImageBytes` from 1 byte through
  8 MiB.
- A customer may select a source image up to 25 MiB. The SDK preserves aspect
  ratio, never crops, and reduces it to a 4096-pixel edge, 16 megapixels, and
  the configured byte limit before upload.
- The SDK applies the configured value or its built-in safety ceiling,
  whichever is lower. The server independently enforces the same policy.
- Media policy does not change AI-credit budgets or request-rate limits.
- Photos use the system picker.
- Camera permission is requested only after the customer taps **Camera**.

Add this to the merchant app's `Info.plist` for camera capture:

```xml
<key>NSCameraUsageDescription</key>
<string>Take a photo to share with support.</string>
```

### Push notifications

Push setup has two separate sides:

1. In Xcode, add the **Push Notifications** capability to the merchant app.
2. Configure the merchant app's APNs provider credentials in Onlo Dashboard:
   - **Channels → WebChat → Install → Mobile SDK**: select the SDK, add the
     Bundle ID and Team ID under **App identity**, then turn on APNs under
     **Mobile Features & App Controls**.
   - Enter the Key ID and Apple `.p8` private key there. The environment must
     match the signed build: Sandbox for development, Production for TestFlight
     and App Store builds.
   - The `.p8` file belongs on the server and must never be embedded in the app
     or SDK.
3. Ask for notification permission from a clear customer action, such as
   **Enable support notifications**. Do not prompt during SDK initialization.
4. Pass the returned APNs device token to Onlo.

**Validate and save APNs** verifies the key structure and locally signs a
provider JWT. It does not contact APNs or send a test notification, so complete
delivery verification still requires a physical device.

Request permission and register:

```swift
import UserNotifications

UNUserNotificationCenter.current().requestAuthorization(
    options: [.alert, .badge, .sound]
) { granted, _ in
    guard granted else { return }
    DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
```

Pass the APNs token:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Task {
        // Pass the token whenever APNs supplies it. The native SDK registers
        // it for the current anonymous or identified installation and
        // re-registers after an account switch.
        try await Onlo.setAPNsPushToken(deviceToken)
    }
}
```

Call `registerForRemoteNotifications()` again on later launches when permission
is already authorized. APNs then supplies the current token, covering process
restarts as well as token rotation. Pass every token APNs supplies; never save
or compare it in app code.

Observe the exact identified-customer application badge:

```swift
Task {
    for await count in await Onlo.observeUnreadCount() {
        // nil means anonymous/logout/account switch: clear the badge.
        application.applicationIconBadgeNumber = count ?? 0
    }
}
```

#### Open the conversation after the customer taps

The server sends `notificationType: "message_available"` with a real
`conversationId` and `messageId`. This one contract shape covers any
customer-visible conversation message, including:

- an agent reply;
- a ticket update represented as a conversation message;
- a proactive message represented as a conversation message.

There is no separate `proactive_message` notification type in protocol v1.
A ticket status change with no customer-visible message also has no v1 push
shape; the server must create a conversation message or the protocol must be
extended before clients can route it.

Forward the notification only from the user-tap callback:

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
) {
    Task { @MainActor in
        defer { completionHandler() }

        do {
            let handledByOnlo = try await Onlo.handleNotificationTap(
                response.notification.request.content.userInfo,
                from: hostViewController
            )

            if !handledByOnlo {
                // Route the merchant app's own notification.
            }
        } catch {
            // Keep the host app usable. Log only a safe error code.
        }
    }
}
```

`hostViewController` is the currently active merchant screen. Requiring it
keeps navigation under the host app's control and supports multi-window apps.

The SDK does **not** open chat merely because a push arrived. After a customer
taps, it validates the payload, refreshes authorization/transcript state, and
opens the referenced conversation. If the app is still restoring, version
0.3.0 retains one native tap and retries it when either the anonymous or
identified session is ready. Logout clears that pending tap. Invalid tokens,
registration failures, and APNs errors affect push only; they never interrupt
Messenger, transcript synchronization, or normal support.

Test APNs delivery on a physical device before release.

## Account and profile changes

| Merchant event | Required Onlo action |
|---|---|
| Anonymous app session | `loginUnidentifiedUser()` |
| Customer signs in | Fetch a fresh backend JWT, then `loginIdentifiedUser(userJwt:)` |
| Name/email/phone changes | Fetch a fresh JWT containing the same stable `sub` and updated attributes |
| Customer logs out or switches account | Await `Onlo.logout()` before activating the next customer |
| Support is not allowed for this customer | Hide the host-owned Support button; Onlo never inserts one |

## Advanced configuration

### Environment keys

```swift
#if DEBUG
let onloSDKKey = "<STAGING_PUBLIC_MOBILE_SDK_KEY>"
#else
let onloSDKKey = "<PRODUCTION_PUBLIC_MOBILE_SDK_KEY>"
#endif

try await Onlo.initialize(apiKey: onloSDKKey)
```

The public key selects an Operator integration, not the service hostname.
Production is fixed to `https://onlo.ai`; staging origins are SDK
release-configured. Never place a signing secret or user JWT in build settings.

### Safe diagnostics

```swift
#if DEBUG
Onlo.setLogLevel(.verbose)
#else
Onlo.setLogLevel(.off)
#endif
```

| Level | Output |
|---|---|
| `.off` | No SDK diagnostics; the default |
| `.error` | Safe failures requiring retry, recovery, or host action |
| `.info` | Errors plus request/lifecycle completion summaries |
| `.verbose` | Info plus timing milestones such as first token and cache validation |

Output is restricted to operation, safe code, request ID, SDK/runtime version,
and duration. Every level excludes SDK keys, identity data, JWTs, session/push
tokens, customer fields, message text, and attachment URLs. The level can
change before or after initialization without recreating the session.

### Custom customer attributes

The merchant backend places bounded `customAttributes` in the short-lived
signed user JWT. The app passes the compact JWT unchanged:

```swift
let userJwt = try await fetchOnloUserJWT()
try await Onlo.loginIdentifiedUser(userJwt: userJwt)
```

The app must not construct, edit, sign, persist, or log this JWT.

### Open a known conversation

```swift
try await Onlo.openConversation(
    conversationId,
    from: hostViewController
)
```

The SDK re-authorises and refreshes the conversation before presentation.

## Success criteria

- The merchant app login works even if Onlo is unavailable.
- Support enables only after the selected Onlo login flow is ready.
- The messenger opens only after the merchant app requests it from the active screen.
- The app never signs, stores, decodes, or logs the user JWT.
- Logout completes before another customer becomes active, or Support stays disabled while recovery is pending.

## Troubleshooting

| Symptom | Check |
|---|---|
| `import OnloSDK` fails | Confirm the local `packages/ios` package was added to the app target |
| Support button stays disabled | Log only `OnloError.safeCode`; verify initialization and login completed |
| Identified login fails | Confirm the backend JWT is HS256, has `aud: onlo-messenger`, stable `sub`, and a lifetime of at most 5 minutes |
| Chat opens from the wrong screen | Call `Onlo.present(from:)` with the currently visible ViewController |
| Camera does not open | Add `NSCameraUsageDescription` and test on a camera-capable device |
| Microphone does not start | Enable **Voice input**, add both microphone and speech-recognition usage descriptions, and grant both permissions after tapping the microphone |
| Push does not arrive | Verify app capabilities, APNs environment, token registration, and physical-device delivery |

Never log JWTs, credentials, customer data, message text, push tokens, or
attachment URLs.

Cross-platform session, identity, offline, reinstall, language, and deployment
questions are answered in the
[integration FAQ](../../docs/integration-guide.md#frequently-asked-questions).

## Local verification

From the repository root:

```bash
swift package resolve
swift build -c release
xcodebuild \
  -scheme OnloSDK \
  -destination 'generic/platform=iOS Simulator' \
  build \
  CODE_SIGNING_ALLOWED=NO
```

## Contract

- Canonical contract: [`docs/api-contract.md`](../../docs/api-contract.md)
- Shared protocol: [`packages/protocol`](../protocol)
- Fixtures: [`contracts/v1`](../../contracts/v1)

Next: run the [iOS merchant example](../../examples/ios/README.md) with your app’s normal customer-login flow.
