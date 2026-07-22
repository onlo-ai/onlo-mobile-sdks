import 'package:flutter/material.dart';
import 'package:onlo_flutter/onlo_flutter.dart';

void main() => runApp(const OnloLocalExample());

class OnloLocalExample extends StatefulWidget {
  const OnloLocalExample({super.key});
  @override
  State<OnloLocalExample> createState() => _OnloLocalExampleState();
}

class _OnloLocalExampleState extends State<OnloLocalExample> {
  // Supply through private build configuration, never source control.
  static const String? _publicSdkKey = null;
  String _status = 'Local mock host: SDK key not configured';

  Future<void> _initialize() async {
    if (_publicSdkKey == null) return;
    await Onlo.initialize(sdkKey: _publicSdkKey);
    setState(() => _status = 'Native SDK initialized');
  }

  Future<void> _identifyAfterHostLogin() async {
    final userJwt = await _fetchShortLivedOnloUserJwtFromOperatorBackend();
    await Onlo.loginIdentifiedUser(userJwt: userJwt);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(home: Scaffold(
    appBar: AppBar(title: const Text('Onlo local example')),
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(_status),
      FilledButton(onPressed: _initialize, child: const Text('Initialize local host')),
      FilledButton(onPressed: _publicSdkKey == null ? null : _identifyAfterHostLogin, child: const Text('Sign in through host backend')),
      FilledButton(onPressed: _publicSdkKey == null ? null : () => Onlo.present(), child: const Text('Support')),
    ])),
  ));
}

Future<String> _fetchShortLivedOnloUserJwtFromOperatorBackend() async =>
    throw UnsupportedError('Implement an authenticated Operator-backend call. Never sign or persist a JWT in Dart.');
