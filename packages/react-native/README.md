# `@onlo/react-native`

React Native is a thin TypeScript facade over the native iOS and Android Onlo SDK cores. JavaScript does not retain a session, credential, transcript, outbox, push registry, or UI state.

Its host-app interface is:

```ts
Onlo.initialize({ sdkKey: 'onlo_rn_sk_…' });
Onlo.loginUnidentifiedUser();
Onlo.loginIdentifiedUser({ userJwt });
Onlo.present();
Onlo.dismiss();
Onlo.logout();
```

Subscribe to native lifecycle, unread-count, and typed-error events with `Onlo.addListener(listener)`. The native module is available in bare React Native apps and Expo development builds; Expo Go cannot load custom native modules.

The host application obtains `userJwt` from its Operator backend. Do not generate it in the app or persist it in JavaScript.

See the [integration guide](../../docs/integration-guide.md) and [delivery plan](../../docs/delivery-plan.md).
