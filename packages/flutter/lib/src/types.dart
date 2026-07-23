enum OnloSessionState {
  uninitialized,
  restoring,
  anonymousReady,
  identifiedReady,
  offlineReady,
  identifying,
  refreshing,
  logoutPending,
  reauthRequired,
}

enum OnloIdentityState { unknown, anonymous, identified }

enum OnloConnectionState { uninitialized, ready, offline, unavailable }

enum OnloLogLevel { off, error, info, verbose }

enum OnloPushProvider { apns, fcm }

enum OnloNotificationPreference { enabled, muted }

enum OnloPushHandlingResult { handled, deferred, notOnlo }

enum OnloRetryDirective {
  never('never'),
  afterTokenRefresh('after_token_refresh'),
  afterAttestation('after_attestation'),
  afterBackoff('after_backoff'),
  afterFullSync('after_full_sync');

  const OnloRetryDirective(this.wireValue);

  final String wireValue;
}

enum OnloErrorCode {
  invalidRequest('invalid_request'),
  invalidTargetKey('invalid_target_key'),
  sdkNotAvailable('sdk_not_available'),
  targetDisabled('target_disabled'),
  incompatibleClient('incompatible_client'),
  proofRequired('proof_required'),
  invalidProof('invalid_proof'),
  expiredProof('expired_proof'),
  identityDisabled('identity_disabled'),
  attestationRequired('attestation_required'),
  invalidAttestation('invalid_attestation'),
  sessionExpired('session_expired'),
  sessionRevoked('session_revoked'),
  forbiddenPrincipal('forbidden_principal'),
  staleCursor('stale_cursor'),
  idempotencyConflict('idempotency_conflict'),
  configUnavailable('config_unavailable'),
  mediaUnavailable('media_unavailable'),
  rateLimited('rate_limited'),
  dependencyUnavailable('dependency_unavailable'),
  invalidArgument('invalid_argument'),
  nativeBridgeUnavailable('native_bridge_unavailable'),
  nativeOperationFailed('native_operation_failed');

  const OnloErrorCode(this.wireValue);

  final String wireValue;
}

final class OnloRetry {
  const OnloRetry({required this.directive, this.retryAfterMs});

  final OnloRetryDirective directive;
  final int? retryAfterMs;
}

sealed class OnloException implements Exception {
  const OnloException(
    this.code,
    this.message, {
    this.retry,
    this.requestId,
  });

  final OnloErrorCode code;
  final String message;
  final OnloRetry? retry;
  final String? requestId;

  @override
  String toString() => 'OnloException(${code.wireValue})';
}

final class OnloArgumentException extends OnloException {
  const OnloArgumentException(String message)
      : super(OnloErrorCode.invalidArgument, message);
}

final class OnloBridgeUnavailableException extends OnloException {
  const OnloBridgeUnavailableException()
      : super(
          OnloErrorCode.nativeBridgeUnavailable,
          'The native Onlo SDK bridge is not registered for this runtime.',
        );
}

final class OnloNativeException extends OnloException {
  const OnloNativeException(
    super.code,
    super.message, {
    super.retry,
    super.requestId,
  });
}

final class OnloInitializeOptions {
  const OnloInitializeOptions({required this.sdkKey});

  final String sdkKey;
}

final class OnloIdentifiedLoginOptions {
  const OnloIdentifiedLoginOptions({required this.userJwt});

  final String userJwt;
}

final class OnloPresentOptions {
  const OnloPresentOptions({this.conversationId});

  final String? conversationId;
}

final class OnloPushTokenOptions {
  const OnloPushTokenOptions({
    required this.provider,
    required this.token,
    this.notificationPreference,
    this.locale,
  });

  final OnloPushProvider provider;
  final String token;
  final OnloNotificationPreference? notificationPreference;
  final String? locale;
}

final class OnloPushNotificationPayload {
  const OnloPushNotificationPayload({
    required this.conversationId,
    required this.messageId,
    required this.notificationType,
  });

  final String conversationId;
  final String messageId;
  final String notificationType;
}

final class OnloStateSnapshot {
  const OnloStateSnapshot({
    required this.session,
    required this.identity,
    required this.connection,
    required this.unreadCount,
  });

  final OnloSessionState session;
  final OnloIdentityState identity;
  final OnloConnectionState connection;
  final int? unreadCount;
}
