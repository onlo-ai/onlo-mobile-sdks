import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:onlo_flutter/onlo_flutter.dart';

void main() => runApp(const OnloLocalExample());

class OnloLocalExample extends StatefulWidget {
  const OnloLocalExample({super.key});
  @override
  State<OnloLocalExample> createState() => _OnloLocalExampleState();
}

class _OnloLocalExampleState extends State<OnloLocalExample>
    with WidgetsBindingObserver {
  static const String _publicSdkKey = String.fromEnvironment('ONLO_SDK_KEY');
  static const String operatorBackendUrl = String.fromEnvironment(
    'ONLO_OPERATOR_BACKEND_URL',
  );
  StreamSubscription<OnloStateSnapshot>? _stateSubscription;
  OnloSessionState _nativeState = OnloSessionState.uninitialized;
  bool _hostSignedIn = false;
  String? _supportError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stateSubscription = Onlo.observeState().listen((snapshot) {
      if (mounted) setState(() => _nativeState = snapshot.session);
    });
    if (_publicSdkKey.isNotEmpty) {
      unawaited(_initializeOnlo());
    }
  }

  Future<void> _initializeOnlo() async {
    try {
      await Onlo.setLogLevel(
        kReleaseMode ? OnloLogLevel.off : OnloLogLevel.verbose,
      );
      await Onlo.initialize(sdkKey: _publicSdkKey);
    } catch (_) {
      if (mounted) {
        setState(
          () => _supportError = 'Support is temporarily unavailable.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Native owns foreground/background recovery. Dart retains no scheduler,
    // credential, outbox, or transcript state.
  }

  void _continueAnonymously() {
    unawaited(
      Onlo.loginUnidentifiedUser().catchError((_) {
        if (mounted) {
          setState(
            () => _supportError = 'Anonymous support is unavailable.',
          );
        }
      }),
    );
  }

  void _completeHostLogin() {
    // The host login completes independently; identified support preparation is background work.
    setState(() => _hostSignedIn = true);
    unawaited(
      _identifyForSupport().catchError((_) {
        if (mounted) {
          setState(() {
            _supportError =
                'Signed in. Support identity will retry when available.';
          });
        }
      }),
    );
  }

  Future<void> _identifyForSupport() async {
    final userJwt = await _fetchShortLivedOnloUserJwtFromOperatorBackend();
    await Onlo.loginIdentifiedUser(userJwt: userJwt);
  }

  Future<void> _logoutOrSwitchAccount() async {
    await Onlo.logout();
    if (mounted) {
      setState(() {
        _hostSignedIn = false;
        _supportError = null;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stateSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final supportReady = {
      OnloSessionState.anonymousReady,
      OnloSessionState.identifiedReady,
    }.contains(_nativeState);
    final supportPreparing =
        _publicSdkKey.isNotEmpty && !supportReady && _supportError == null;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Onlo local example')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Host account: ${_hostSignedIn ? 'signed in' : 'signed out'}',
              ),
              Text('Native state: ${_nativeState.name}'),
              if (supportPreparing) const CircularProgressIndicator(),
              if (_supportError case final error?) Text(error),
              FilledButton(
                onPressed: _continueAnonymously,
                child: const Text('Continue anonymously'),
              ),
              FilledButton(
                onPressed: _completeHostLogin,
                child: const Text('Complete host login'),
              ),
              FilledButton(
                onPressed: supportReady ? () => Onlo.present() : null,
                child: const Text(
                  'Support (attachments use native picker/camera)',
                ),
              ),
              FilledButton(
                onPressed: _logoutOrSwitchAccount,
                child: const Text('Log out / switch account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String> _fetchShortLivedOnloUserJwtFromOperatorBackend() async {
  if (_OnloLocalExampleState.operatorBackendUrl.isEmpty) {
    throw StateError('Configure the authenticated Operator-backend URL.');
  }
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse(
        '${_OnloLocalExampleState.operatorBackendUrl}/v1/onlo-user-jwt',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.write('{}');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Operator backend rejected the host session.');
    }
    final value =
        jsonDecode(await utf8.decodeStream(response)) as Map<String, Object?>;
    final userJwt = value['userJwt'];
    if (userJwt is! String) {
      throw StateError('Operator backend returned an invalid response.');
    }
    return userJwt;
  } finally {
    client.close();
  }
}

/// Call from the host APNs/FCM integration; Dart never stores the token.
Future<void> forwardPushTokenToOnlo(
  OnloPushProvider provider,
  String token,
) =>
    Onlo.setPushToken(provider: provider, token: token);

/// Call from the host notification callback; native re-authorises the route.
Future<OnloPushHandlingResult> forwardOnloNotification(
  OnloPushNotificationPayload payload,
) =>
    Onlo.handlePushNotification(payload);

/// Call from the host deep-link router; native authorises the conversation.
Future<bool> forwardOnloDeepLink(Uri uri) async {
  if (uri.pathSegments.length != 3 ||
      uri.pathSegments[0] != 'support' ||
      uri.pathSegments[1] != 'conversations') {
    return false;
  }
  await Onlo.openConversation(uri.pathSegments[2]);
  return true;
}
