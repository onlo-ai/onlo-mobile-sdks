import 'dart:async';

import 'package:flutter/services.dart';

import 'platform.dart';
import 'types.dart';

/// Flutter's only runtime boundary. It holds no credential, transcript, token,
/// or customer state; those remain in the native SDK cores.
final class MethodChannelOnloPlatform extends OnloPlatform {
  MethodChannelOnloPlatform({
    MethodChannel? methodChannel,
    EventChannel? stateChannel,
  })  : _methodChannel = methodChannel ?? const MethodChannel(_methodName),
        _stateChannel = stateChannel ?? const EventChannel(_stateName);

  static const String _methodName = 'ai.onlo/onlo_flutter';
  static const String _stateName = 'ai.onlo/onlo_flutter/state';

  final MethodChannel _methodChannel;
  final EventChannel _stateChannel;

  @override
  Future<void> initialize(OnloInitializeOptions options) =>
      _invokeVoid('initialize', <String, Object?>{'sdkKey': options.sdkKey});

  @override
  Future<void> loginUnidentifiedUser() => _invokeVoid('loginUnidentifiedUser');

  @override
  Future<void> loginIdentifiedUser(OnloIdentifiedLoginOptions options) =>
      _invokeVoid(
        'loginIdentifiedUser',
        <String, Object?>{'userJwt': options.userJwt},
      );

  @override
  Future<void> logout() => _invokeVoid('logout');

  @override
  Future<void> present(OnloPresentOptions options) => _invokeVoid(
        'present',
        <String, Object?>{'conversationId': options.conversationId},
      );

  @override
  Future<void> dismiss() => _invokeVoid('dismiss');

  @override
  Future<void> openConversation(String conversationId) =>
      _invokeVoid('openConversation', <String, Object?>{
        'conversationId': conversationId,
      });

  @override
  Future<void> setPushToken(OnloPushTokenOptions options) => _invokeVoid(
        'setPushToken',
        <String, Object?>{
          'provider': options.provider.name,
          'token': options.token,
          'notificationPreference': options.notificationPreference?.name,
          'locale': options.locale,
        },
      );

  @override
  Future<OnloPushHandlingResult> handlePushNotification(
    OnloPushNotificationPayload payload,
  ) async {
    final value =
        await _invoke<Object?>('handlePushNotification', <String, Object?>{
      'conversationId': payload.conversationId,
      'messageId': payload.messageId,
      'notificationType': payload.notificationType,
    });
    return switch (value) {
      'handled' => OnloPushHandlingResult.handled,
      'deferred' => OnloPushHandlingResult.deferred,
      'notOnlo' => OnloPushHandlingResult.notOnlo,
      _ => throw const OnloNativeException(
          OnloErrorCode.nativeOperationFailed,
          'Native Onlo bridge returned an invalid push result.',
        ),
    };
  }

  @override
  Stream<OnloStateSnapshot> observeState() => _stateChannel
      .receiveBroadcastStream()
      .map<OnloStateSnapshot>(_stateFromWire)
      .handleError(_mapPlatformError);

  Future<void> _invokeVoid(String method, [Object? arguments]) async {
    await _invoke<Object?>(method, arguments);
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _methodChannel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw _nativeException(error);
    } on MissingPluginException {
      throw const OnloBridgeUnavailableException();
    }
  }

  OnloStateSnapshot _stateFromWire(Object? event) {
    if (event is! Map) {
      throw const OnloNativeException(
        OnloErrorCode.nativeOperationFailed,
        'Native Onlo bridge returned an invalid state event.',
      );
    }
    final session = _sessionState(event['session']);
    final identity = _identityState(event['identity']);
    final connection = _connectionState(event['connection']);
    final unreadCount = event['unreadCount'];
    if (unreadCount != null && (unreadCount is! int || unreadCount < 0)) {
      throw const OnloNativeException(
        OnloErrorCode.nativeOperationFailed,
        'Native Onlo bridge returned an invalid unread count.',
      );
    }
    return OnloStateSnapshot(
      session: session,
      identity: identity,
      connection: connection,
      unreadCount: unreadCount as int?,
    );
  }

  OnloNativeException _nativeException(PlatformException error) {
    final code =
        OnloErrorCode.values.where((value) => value.wireValue == error.code);
    final errorCode =
        code.isEmpty ? OnloErrorCode.nativeOperationFailed : code.first;
    final details = error.details;
    OnloRetry? retry;
    String? requestId;
    if (details is Map) {
      final retryMap = details['retry'];
      if (retryMap is Map) {
        final directiveValue = retryMap['directive'];
        final directive = OnloRetryDirective.values.where(
          (value) => value.wireValue == directiveValue,
        );
        if (directive.isNotEmpty) {
          final retryAfterMs = retryMap['retryAfterMs'];
          retry = OnloRetry(
            directive: directive.first,
            retryAfterMs:
                retryAfterMs is int && retryAfterMs >= 0 ? retryAfterMs : null,
          );
        }
      }
      requestId = details['requestId'] as String?;
    }
    return OnloNativeException(
      errorCode,
      'Native Onlo operation failed (${errorCode.wireValue}).',
      retry: retry,
      requestId: requestId,
    );
  }

  Never _mapPlatformError(Object error, StackTrace _) {
    if (error is PlatformException) throw _nativeException(error);
    if (error is MissingPluginException) {
      throw const OnloBridgeUnavailableException();
    }
    throw error;
  }

  static OnloSessionState _sessionState(Object? value) => switch (value) {
        'uninitialized' => OnloSessionState.uninitialized,
        'restoring' => OnloSessionState.restoring,
        'anonymousReady' => OnloSessionState.anonymousReady,
        'identifiedReady' => OnloSessionState.identifiedReady,
        'offlineReady' => OnloSessionState.offlineReady,
        'identifying' => OnloSessionState.identifying,
        'refreshing' => OnloSessionState.refreshing,
        'logoutPending' => OnloSessionState.logoutPending,
        'reauthRequired' => OnloSessionState.reauthRequired,
        _ => throw const OnloNativeException(
            OnloErrorCode.nativeOperationFailed,
            'Native Onlo bridge returned an invalid session state.',
          ),
      };

  static OnloIdentityState _identityState(Object? value) => switch (value) {
        'unknown' => OnloIdentityState.unknown,
        'anonymous' => OnloIdentityState.anonymous,
        'identified' => OnloIdentityState.identified,
        _ => throw const OnloNativeException(
            OnloErrorCode.nativeOperationFailed,
            'Native Onlo bridge returned an invalid identity state.',
          ),
      };

  static OnloConnectionState _connectionState(Object? value) => switch (value) {
        'uninitialized' => OnloConnectionState.uninitialized,
        'ready' => OnloConnectionState.ready,
        'offline' => OnloConnectionState.offline,
        'unavailable' => OnloConnectionState.unavailable,
        _ => throw const OnloNativeException(
            OnloErrorCode.nativeOperationFailed,
            'Native Onlo bridge returned an invalid connection state.',
          ),
      };
}
