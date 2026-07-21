# React Native example

This directory will contain a minimal host app after the native iOS and Android SDKs are linked. A normal host-owned button should call `Onlo.present()`; v1 does not supply a global overlay launcher.

The identified example must obtain a short-lived `userJwt` from the Operator backend. It must not embed a signing secret or persist the JWT in JavaScript.
