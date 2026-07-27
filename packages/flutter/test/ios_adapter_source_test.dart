import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS bridge projects lifecycle state and identified unread total',
      () async {
    final source = await File(
      'ios/Classes/OnloFlutterPlugin.swift',
    ).readAsString();
    final podspec = await File('ios/onlo_flutter.podspec').readAsString();

    expect(source, contains('import OnloSDK'));
    expect(podspec, contains("s.dependency 'OnloSDK', '0.1.0'"));
    expect(podspec, isNot(contains('Sources/OnloSDK/**/*.swift')));
    expect(source, contains('observeFrameworkState()'));
    expect(source, contains('snapshot.unreadCount'));
    expect(source, contains('"unreadCount"'));
    expect(source, contains('case .uninitialized: return "uninitialized"'));
    expect(source, contains('case .offlineReady: return "offline"'));
    expect(
        source,
        contains(
            'case nil, "contained": return OnloMessengerOptions(presentationMode: .contained)'));
    expect(
        source,
        contains(
            'case "fullScreen": return OnloMessengerOptions(presentationMode: .fullScreen)'));
    expect(
        source, contains('OnloMessengerPresenter(sdk: sdk, options: options)'));
    expect(
        source, contains('presenter?.isPresentingFrameworkMessenger != true'));
    expect(source, isNot(contains('ConversationDetail')));
    expect(source, isNot(contains('UserDefaults')));
  });
}
