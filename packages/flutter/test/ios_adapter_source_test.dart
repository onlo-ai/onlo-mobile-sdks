import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS bridge projects only authorised framework unread state', () async {
    final source = await File(
      'ios/Classes/OnloFlutterPlugin.swift',
    ).readAsString();

    expect(source, contains('observeFrameworkState()'));
    expect(source, contains('lastEmittedUnreadCount'));
    expect(source, contains('if let unreadCount = snapshot.unreadCount'));
    expect(source, contains('case .uninitialized: return "uninitialized"'));
    expect(source, contains('case .offlineReady: return "offline"'));
    expect(source, isNot(contains('ConversationDetail')));
    expect(source, isNot(contains('UserDefaults')));
  });
}
