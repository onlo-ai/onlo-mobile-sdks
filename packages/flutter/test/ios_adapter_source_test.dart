import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS bridge projects lifecycle state and identified unread total',
      () async {
    final source = await File(
      'ios/Classes/OnloFlutterPlugin.swift',
    ).readAsString();

    expect(source, contains('observeFrameworkState()'));
    expect(source, contains('snapshot.unreadCount'));
    expect(source, contains('"unreadCount"'));
    expect(source, contains('case .uninitialized: return "uninitialized"'));
    expect(source, contains('case .offlineReady: return "offline"'));
    expect(source, isNot(contains('ConversationDetail')));
    expect(source, isNot(contains('UserDefaults')));
  });
}
