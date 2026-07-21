# Flutter example

The host app will call `Onlo.initialize`, obtain a short-lived user JWT from its own authenticated backend, call `Onlo.loginIdentifiedUser`, and present the native messenger from its own support entry point. It must not contain an Onlo signing secret or use Dart storage for Onlo credentials.
