import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android bridge projects only native phase and authorised unread state',
      () async {
    final source = await File(
      'android/src/main/kotlin/ai/onlo/flutter/OnloFlutterPlugin.kt',
    ).readAsString();

    expect(source, contains('core.unreadCount.collect'));
    expect(source, contains('latestUnreadCount = null'));
    expect(source, contains('"unreadCount"'));
    expect(source, contains('OnloPhase.RESTORING -> "uninitialized"'));
    expect(source, contains('OnloPhase.OFFLINE_READY -> "offline"'));
    expect(source, isNot(contains('ConversationDetail')));
    expect(source, isNot(contains('SharedPreferences')));
  });
}
