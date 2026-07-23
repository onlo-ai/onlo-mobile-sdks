import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel_onlo.dart';
import 'types.dart';

abstract class OnloPlatform extends PlatformInterface {
  OnloPlatform() : super(token: _token);

  static final Object _token = Object();
  static OnloPlatform _instance = MethodChannelOnloPlatform();

  static OnloPlatform get instance => _instance;

  static set instance(OnloPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> setLogLevel(OnloLogLevel level);
  Future<void> initialize(OnloInitializeOptions options);
  Future<void> loginUnidentifiedUser();
  Future<void> loginIdentifiedUser(OnloIdentifiedLoginOptions options);
  Future<void> logout();
  Future<void> present(OnloPresentOptions options);
  Future<void> dismiss();
  Future<void> openConversation(String conversationId);
  Future<void> setPushToken(OnloPushTokenOptions options);
  Future<OnloPushHandlingResult> handlePushNotification(
    OnloPushNotificationPayload payload,
  );
  Stream<OnloStateSnapshot> observeState();
}
