import 'platform.dart';
import 'types.dart';

final RegExp _compactJwt = RegExp(
  r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$',
);

abstract final class Onlo {
  static Future<void> setLogLevel(OnloLogLevel level) =>
      OnloPlatform.instance.setLogLevel(level);

  static Future<void> initialize({required String sdkKey}) {
    _requireNonEmpty(sdkKey, 'sdkKey is required.');
    return OnloPlatform.instance
        .initialize(OnloInitializeOptions(sdkKey: sdkKey));
  }

  static Future<void> loginUnidentifiedUser() =>
      OnloPlatform.instance.loginUnidentifiedUser();

  static Future<void> loginIdentifiedUser({required String userJwt}) {
    _requireCompactJwt(userJwt);
    return OnloPlatform.instance.loginIdentifiedUser(
      OnloIdentifiedLoginOptions(userJwt: userJwt),
    );
  }

  static Future<void> logout() => OnloPlatform.instance.logout();

  static Future<void> present({
    String? conversationId,
    OnloPresentationMode presentationMode = OnloPresentationMode.contained,
  }) {
    if (conversationId != null) {
      _requireNonEmpty(
        conversationId,
        'conversationId cannot be empty when supplied.',
      );
    }
    return OnloPlatform.instance.present(
      OnloPresentOptions(
        conversationId: conversationId,
        presentationMode: presentationMode,
      ),
    );
  }

  static Future<void> dismiss() => OnloPlatform.instance.dismiss();

  static Future<void> openConversation(String conversationId) {
    _requireNonEmpty(
      conversationId,
      'openConversation requires a non-empty conversationId.',
    );
    return OnloPlatform.instance.openConversation(conversationId);
  }

  static Future<void> setPushToken({
    required OnloPushProvider provider,
    required String token,
    OnloNotificationPreference? notificationPreference,
    String? locale,
  }) {
    _requireNonEmpty(token, 'token is required.');
    if (locale != null) {
      _requireNonEmpty(locale, 'locale cannot be empty when supplied.');
    }
    return OnloPlatform.instance.setPushToken(
      OnloPushTokenOptions(
        provider: provider,
        token: token,
        notificationPreference: notificationPreference,
        locale: locale,
      ),
    );
  }

  static Future<OnloPushHandlingResult> handlePushNotification(
    OnloPushNotificationPayload payload,
  ) {
    _requireNonEmpty(
      payload.conversationId,
      'push payload requires a non-empty conversationId.',
    );
    _requireNonEmpty(
      payload.messageId,
      'push payload requires a non-empty messageId.',
    );
    if (payload.notificationType != 'message_available') {
      throw const OnloArgumentException(
        'push payload notificationType is not supported.',
      );
    }
    return OnloPlatform.instance.handlePushNotification(payload);
  }

  static Stream<OnloStateSnapshot> observeState() =>
      OnloPlatform.instance.observeState();

  static Stream<OnloIdentityState> observeIdentityState() =>
      observeState().map((snapshot) => snapshot.identity).distinct();

  static Stream<OnloConnectionState> observeConnectionState() =>
      observeState().map((snapshot) => snapshot.connection).distinct();

  static Stream<int?> observeUnreadCount() =>
      observeState().map((snapshot) => snapshot.unreadCount).distinct();

  static void _requireCompactJwt(String value) {
    _requireNonEmpty(value, 'userJwt is required.');
    if (!_compactJwt.hasMatch(value)) {
      throw const OnloArgumentException(
        'userJwt must have compact JWT shape.',
      );
    }
  }

  static void _requireNonEmpty(String value, String message) {
    if (value.trim().isEmpty) throw OnloArgumentException(message);
  }
}
