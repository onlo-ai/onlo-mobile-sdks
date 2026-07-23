import 'dart:async';

import 'package:flutter/material.dart';
import 'package:onlo_flutter/onlo_flutter.dart';

void main() => runApp(const OnloLocalExample());

class OnloLocalExample extends StatefulWidget {
  const OnloLocalExample({super.key});
  @override
  State<OnloLocalExample> createState() => _OnloLocalExampleState();
}

class _OnloLocalExampleState extends State<OnloLocalExample> {
  static const String _publicSdkKey = String.fromEnvironment('ONLO_SDK_KEY');
  StreamSubscription<OnloStateSnapshot>? _stateSubscription;
  OnloSessionState _nativeState = OnloSessionState.uninitialized;
  bool _hostSignedIn = false;
  String? _supportError;

  @override
  void initState() {
    super.initState();
    _stateSubscription = Onlo.observeState().listen((snapshot) {
      if (mounted) setState(() => _nativeState = snapshot.session);
    });
    if (_publicSdkKey.isNotEmpty) {
      unawaited(
        Onlo.initialize(sdkKey: _publicSdkKey).catchError((_) {
          if (mounted) {
            setState(
              () => _supportError = 'Support is temporarily unavailable.',
            );
          }
        }),
      );
    }
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

  @override
  void dispose() {
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
                onPressed: _completeHostLogin,
                child: const Text('Complete host login'),
              ),
              FilledButton(
                onPressed: supportReady ? () => Onlo.present() : null,
                child: const Text('Support'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String> _fetchShortLivedOnloUserJwtFromOperatorBackend() async =>
    throw UnsupportedError(
      'Implement an authenticated Operator-backend call. Never sign or persist a JWT in Dart.',
    );
