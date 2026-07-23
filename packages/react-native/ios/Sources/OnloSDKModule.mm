#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTUtils.h>
#import <OnloReactNative/OnloReactNative-Swift.h>
#import <UIKit/UIKit.h>

#if __has_include(<OnloSDKSpec/OnloSDKSpec.h>)
#import <OnloSDKSpec/OnloSDKSpec.h>
#define ONLO_RN_CODEGEN_SPEC 1
#endif

static NSDictionary *OnloInvalidArgument(void);
static NSDictionary *OnloOperationFailure(void);

/// The Objective-C++ shell is intentionally transport-free: it adapts React
/// Native promises/events to the Swift bridge, which delegates to OnloSDK.
#if ONLO_RN_CODEGEN_SPEC
@interface OnloSDKModule : RCTEventEmitter <NativeOnloSDKSpec>
#else
@interface OnloSDKModule : RCTEventEmitter <RCTBridgeModule>
#endif
@property(nonatomic, strong) OnloReactNativeIOSBridge *nativeBridge;
@end

@implementation OnloSDKModule

RCT_EXPORT_MODULE(OnloSDK)

+ (BOOL)requiresMainQueueSetup { return YES; }

- (instancetype)init {
  if ((self = [super init])) {
    __weak typeof(self) weakSelf = self;
    _nativeBridge = [[OnloReactNativeIOSBridge alloc] initWithEventSink:^(NSDictionary *event) {
      typeof(self) strongSelf = weakSelf;
      if (strongSelf != nil) [strongSelf sendEventWithName:@"onOnloEvent" body:event];
    }];
  }
  return self;
}

- (NSArray<NSString *> *)supportedEvents { return @[ @"onOnloEvent" ]; }

#if ONLO_RN_CODEGEN_SPEC && RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeOnloSDKSpecJSI>(params);
}
#endif

RCT_REMAP_METHOD(setLogLevel,
                 setLogLevel:(NSString *)level
                 resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject) {
  if (![level isKindOfClass:NSString.class] ||
      ![@[ @"off", @"error", @"info", @"verbose" ] containsObject:level]) {
    [self reject:reject payload:OnloInvalidArgument()]; return;
  }
  [self.nativeBridge setLogLevel:level completion:^(NSDictionary *error) {
    [self complete:resolve reject:reject error:error];
  }];
}

RCT_REMAP_METHOD(initialize,
                 initialize:(NSDictionary *)options
                 resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject) {
  NSString *sdkKey = [options[@"sdkKey"] isKindOfClass:NSString.class] ? options[@"sdkKey"] : nil;
  if (sdkKey.length == 0) { [self reject:reject payload:OnloInvalidArgument()]; return; }
  [self.nativeBridge initializeWithSDKKey:sdkKey completion:^(NSDictionary *error) { [self complete:resolve reject:reject error:error]; }];
}

RCT_REMAP_METHOD(loginUnidentifiedUser,
                 loginUnidentifiedUser:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject) {
  [self.nativeBridge loginUnidentifiedWithCompletion:^(NSDictionary *error) { [self complete:resolve reject:reject error:error]; }];
}

RCT_REMAP_METHOD(loginIdentifiedUser,
                 loginIdentifiedUser:(NSDictionary *)options
                 resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject) {
  NSString *jwt = [options[@"userJwt"] isKindOfClass:NSString.class] ? options[@"userJwt"] : nil;
  if (jwt.length == 0) { [self reject:reject payload:OnloInvalidArgument()]; return; }
  [self.nativeBridge loginIdentifiedWithUserJWT:jwt completion:^(NSDictionary *error) { [self complete:resolve reject:reject error:error]; }];
}

RCT_REMAP_METHOD(logout, logout:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
  [self.nativeBridge logoutWithCompletion:^(NSDictionary *error) { [self complete:resolve reject:reject error:error]; }];
}

RCT_REMAP_METHOD(present,
                 present:(NSDictionary *)options
                 resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject) {
  NSString *conversationID = options[@"conversationId"];
  if (conversationID != nil && (![conversationID isKindOfClass:NSString.class] || conversationID.length == 0)) {
    [self reject:reject payload:OnloInvalidArgument()]; return;
  }
  UIViewController *host = RCTPresentedViewController();
  if (host == nil) { [self reject:reject payload:OnloOperationFailure()]; return; }
  [self.nativeBridge presentFrom:host conversationID:conversationID completion:^(NSDictionary *error) { [self complete:resolve reject:reject error:error]; }];
}

RCT_REMAP_METHOD(dismiss, dismiss:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
  [self.nativeBridge dismissWithCompletion:^(NSDictionary *error) { [self complete:resolve reject:reject error:error]; }];
}

RCT_REMAP_METHOD(openConversation,
                 openConversation:(NSString *)conversationID
                 resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject) {
  if (![conversationID isKindOfClass:NSString.class] || conversationID.length == 0) { [self reject:reject payload:OnloInvalidArgument()]; return; }
  UIViewController *host = RCTPresentedViewController();
  if (host == nil) { [self reject:reject payload:OnloOperationFailure()]; return; }
  [self.nativeBridge openConversation:conversationID from:host completion:^(NSDictionary *error) { [self complete:resolve reject:reject error:error]; }];
}

RCT_REMAP_METHOD(setPushToken,
                 setPushToken:(NSDictionary *)options
                 resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject) {
  NSString *provider = options[@"provider"];
  NSString *token = options[@"token"];
  NSString *preference = options[@"notificationPreference"];
  NSString *locale = options[@"locale"];
  if (![provider isEqualToString:@"apns"] || ![token isKindOfClass:NSString.class] || token.length == 0 ||
      (preference != nil && ![preference isKindOfClass:NSString.class]) || (locale != nil && ![locale isKindOfClass:NSString.class])) {
    [self reject:reject payload:OnloInvalidArgument()]; return;
  }
  [self.nativeBridge setAPNsPushToken:token notificationPreference:preference locale:locale completion:^(NSDictionary *error) { [self complete:resolve reject:reject error:error]; }];
}

RCT_REMAP_METHOD(handlePushNotification,
                 handlePushNotification:(NSDictionary *)payload
                 resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject) {
  NSString *conversationID = payload[@"conversationId"];
  NSString *messageID = payload[@"messageId"];
  NSString *type = payload[@"notificationType"];
  if (![conversationID isKindOfClass:NSString.class] || conversationID.length == 0 || ![messageID isKindOfClass:NSString.class] || messageID.length == 0 || ![type isEqualToString:@"message_available"]) {
    [self reject:reject payload:OnloInvalidArgument()]; return;
  }
  [self.nativeBridge handlePushConversationID:conversationID messageID:messageID notificationType:type host:RCTPresentedViewController() completion:^(NSString *result, NSDictionary *error) {
    if (error != nil) [self reject:reject payload:error]; else resolve(result);
  }];
}

- (void)complete:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject error:(NSDictionary *)error {
  if (error == nil) resolve(nil); else [self reject:reject payload:error];
}

- (void)reject:(RCTPromiseRejectBlock)reject payload:(NSDictionary *)payload {
  NSString *code = [payload[@"code"] isKindOfClass:NSString.class] ? payload[@"code"] : @"native_operation_failed";
  NSError *error = [NSError errorWithDomain:@"ai.onlo.react-native" code:0 userInfo:payload];
  reject(code, [NSString stringWithFormat:@"Onlo operation failed (%@).", code], error);
}

static NSDictionary *OnloInvalidArgument(void) { return @{ @"code": @"invalid_argument", @"retry": @{ @"directive": @"never" } }; }
static NSDictionary *OnloOperationFailure(void) { return @{ @"code": @"native_operation_failed", @"retry": @{ @"directive": @"never" } }; }

@end
