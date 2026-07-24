import 'dart:async';

import 'package:flutter/material.dart';
import 'package:onlo_flutter/onlo_flutter.dart';

void main() => runApp(const OnloExample());

class OnloExample extends StatelessWidget {
  const OnloExample({super.key});

  static const sdkKey = String.fromEnvironment('ONLO_SDK_KEY');

  Future<void> _openSupport() async {
    await Onlo.initialize(sdkKey: sdkKey);
    await Onlo.loginUnidentifiedUser();
    await Onlo.present();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: sdkKey.isEmpty ? null : () => unawaited(_openSupport()),
            child: const Text('Open Support'),
          ),
        ),
      ),
    );
  }
}
