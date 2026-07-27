import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onlo_flutter/onlo_flutter.dart';
import 'package:onlo_flutter/src/method_channel_onlo.dart';
import 'package:onlo_flutter/src/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    OnloPlatform.instance = _FakeOnloPlatform();
  });

  test('forwards the public API to the registered native bridge', () async {
    final fake = _FakeOnloPlatform();
    OnloPlatform.instance = fake;

    await Onlo.setLogLevel(OnloLogLevel.verbose);
    await Onlo.initialize(sdkKey: 'onlo_flutter_sk_public_example');
    await Onlo.loginUnidentifiedUser();
    await Onlo.loginIdentifiedUser(userJwt: 'header.payload.signature');
    await Onlo.present(
      conversationId: 'conversation-id',
      presentationMode: OnloPresentationMode.fullScreen,
    );
    expect(fake.lastPresentOptions?.conversationId, 'conversation-id');
    expect(
      fake.lastPresentOptions?.presentationMode,
      OnloPresentationMode.fullScreen,
    );
    await Onlo.dismiss();
    await Onlo.openConversation('conversation-id');
    await Onlo.setPushToken(
      provider: OnloPushProvider.fcm,
      token: 'synthetic-push-token',
      notificationPreference: OnloNotificationPreference.enabled,
      locale: 'en',
    );
    final pushResult = await Onlo.handlePushNotification(
      const OnloPushNotificationPayload(
        conversationId: 'conversation-id',
        messageId: 'message-id',
        notificationType: 'message_available',
      ),
    );
    await Onlo.logout();

    expect(pushResult, OnloPushHandlingResult.handled);

    expect(
      fake.calls,
      [
        'setLogLevel',
        'initialize',
        'loginUnidentifiedUser',
        'loginIdentifiedUser',
        'present',
        'dismiss',
        'openConversation',
        'setPushToken',
        'handlePushNotification',
        'logout',
      ],
    );
  });

  test('rejects malformed input before crossing the bridge', () {
    expect(
      () => Onlo.loginIdentifiedUser(userJwt: 'not-a-jwt'),
      throwsA(isA<OnloArgumentException>()),
    );
    expect(
      () => Onlo.present(conversationId: ' '),
      throwsA(isA<OnloArgumentException>()),
    );
    expect(
      () => Onlo.openConversation(''),
      throwsA(isA<OnloArgumentException>()),
    );
    expect(
      () => Onlo.setPushToken(
        provider: OnloPushProvider.apns,
        token: ' ',
      ),
      throwsA(isA<OnloArgumentException>()),
    );
    expect(
      () => Onlo.handlePushNotification(
        const OnloPushNotificationPayload(
          conversationId: 'conversation-id',
          messageId: 'message-id',
          notificationType: 'unexpected',
        ),
      ),
      throwsA(isA<OnloArgumentException>()),
    );
  });

  test('exposes typed distinct identity connection and unread streams',
      () async {
    final fake = _FakeOnloPlatform();
    OnloPlatform.instance = fake;

    await expectLater(
      Onlo.observeIdentityState(),
      emitsInOrder([OnloIdentityState.anonymous, emitsDone]),
    );
    await expectLater(
      Onlo.observeConnectionState(),
      emitsInOrder([OnloConnectionState.ready, emitsDone]),
    );
    await expectLater(
      Onlo.observeUnreadCount(),
      emitsInOrder([null, emitsDone]),
    );
  });

  test('uses stable typed local error codes', () {
    const error = OnloBridgeUnavailableException();

    expect(error.code, OnloErrorCode.nativeBridgeUnavailable);
    expect(error.code.wireValue, 'native_bridge_unavailable');
    expect(error.toString(), 'OnloException(native_bridge_unavailable)');
  });

  test('method-channel adapter forwards only typed boundary values', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('ai.onlo/onlo_flutter');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'handlePushNotification') return 'deferred';
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    OnloPlatform.instance = MethodChannelOnloPlatform();

    await Onlo.initialize(sdkKey: 'onlo_flutter_sk_public_example');
    await Onlo.present();
    final outcome = await Onlo.handlePushNotification(
      const OnloPushNotificationPayload(
        conversationId: 'conversation-id',
        messageId: 'message-id',
        notificationType: 'message_available',
      ),
    );

    expect(calls.map((call) => call.method), [
      'initialize',
      'present',
      'handlePushNotification',
    ]);
    expect(calls[1].arguments, <String, Object?>{
      'conversationId': null,
      'presentationMode': 'contained',
    });
    expect(outcome, OnloPushHandlingResult.deferred);
  });

  test('method-channel adapter maps native errors without native details',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('ai.onlo/onlo_flutter');
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'session_expired',
        details: <String, Object?>{
          'retry': <String, Object?>{'directive': 'after_token_refresh'},
        },
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    OnloPlatform.instance = MethodChannelOnloPlatform();

    expect(
      Onlo.logout(),
      throwsA(
        isA<OnloNativeException>()
            .having((value) => value.code, 'code', OnloErrorCode.sessionExpired)
            .having(
              (value) => value.retry?.directive,
              'retry directive',
              OnloRetryDirective.afterTokenRefresh,
            ),
      ),
    );
  });
}

final class _FakeOnloPlatform extends OnloPlatform {
  final List<String> calls = <String>[];
  OnloPresentOptions? lastPresentOptions;

  @override
  Future<void> dismiss() async => calls.add('dismiss');

  @override
  Future<void> setLogLevel(OnloLogLevel level) async =>
      calls.add('setLogLevel');

  @override
  Future<void> initialize(OnloInitializeOptions options) async =>
      calls.add('initialize');

  @override
  Future<void> loginIdentifiedUser(OnloIdentifiedLoginOptions options) async =>
      calls.add('loginIdentifiedUser');

  @override
  Future<void> loginUnidentifiedUser() async =>
      calls.add('loginUnidentifiedUser');

  @override
  Future<void> logout() async => calls.add('logout');

  @override
  Future<void> openConversation(String conversationId) async =>
      calls.add('openConversation');

  @override
  Stream<OnloStateSnapshot> observeState() => Stream<OnloStateSnapshot>.value(
        const OnloStateSnapshot(
          session: OnloSessionState.anonymousReady,
          identity: OnloIdentityState.anonymous,
          connection: OnloConnectionState.ready,
          unreadCount: null,
        ),
      );

  @override
  Future<void> present(OnloPresentOptions options) async {
    lastPresentOptions = options;
    calls.add('present');
  }

  @override
  Future<void> setPushToken(OnloPushTokenOptions options) async =>
      calls.add('setPushToken');

  @override
  Future<OnloPushHandlingResult> handlePushNotification(
    OnloPushNotificationPayload payload,
  ) async {
    calls.add('handlePushNotification');
    return OnloPushHandlingResult.handled;
  }
}
