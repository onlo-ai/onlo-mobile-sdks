import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android bridge projects native phase and identified unread total',
      () async {
    final source = await File(
      'android/src/main/kotlin/ai/onlo/flutter/OnloFlutterPlugin.kt',
    ).readAsString();

    expect(source, contains('core.unreadCount.collect'));
    expect(source, contains('"unreadCount"'));
    expect(source, contains('OnloPhase.RESTORING -> "uninitialized"'));
    expect(source, contains('OnloPhase.OFFLINE_READY -> "offline"'));
    expect(source, isNot(contains('ConversationDetail')));
    expect(source, isNot(contains('SharedPreferences')));
  });
}
