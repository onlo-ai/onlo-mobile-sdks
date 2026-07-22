import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const podspec = await readFile(new URL('../ios/OnloReactNative.podspec', import.meta.url), 'utf8');
const swift = await readFile(new URL('../ios/Sources/OnloReactNativeIOSBridge.swift', import.meta.url), 'utf8');
const module = await readFile(new URL('../ios/Sources/OnloSDKModule.mm', import.meta.url), 'utf8');
const config = await readFile(new URL('../react-native.config.js', import.meta.url), 'utf8');

test('iOS adapter delegates the public RN surface to one native OnloSDK core', () => {
  assert.match(swift, /private let sdk = OnloSDK\(\)/);
  assert.match(swift, /initializeFrameworkBridge\(sdkKey: sdkKey, sdkFamily: \.reactNative\)/);
  for (const seam of ['loginUnidentifiedUser', 'loginIdentifiedUser', 'logout', 'setAPNsPushToken', 'handlePushNotificationFromBridge']) {
    assert.match(swift, new RegExp(`sdk\\.${seam}`));
  }
  assert.match(swift, /OnloMessengerPresenter\(sdk: sdk\)/);
  assert.match(module, /RCT_EXPORT_MODULE\(OnloSDK\)/);
  assert.match(module, /#import <OnloSDKSpec\/OnloSDKSpec\.h>/);
  assert.match(module, /NativeOnloSDKSpecJSI/);
  for (const method of ['initialize', 'loginUnidentifiedUser', 'loginIdentifiedUser', 'logout', 'present', 'dismiss', 'openConversation', 'setPushToken', 'handlePushNotification']) {
    assert.match(module, new RegExp(`RCT_REMAP_METHOD\\(${method}`));
  }
});

test('iOS adapter is a local autolinked pod with no parallel persistence, network, or content state', () => {
  assert.match(config, /podspecPath: '\.\/ios\/OnloReactNative\.podspec'/);
  assert.match(podspec, /\.\.\/\.\.\/ios\/Sources\/OnloSDK\/\*\*\/\*\.swift/);
  assert.match(podspec, /do not add the SwiftPM product/);
  assert.match(podspec, /SWIFT_INCLUDE_PATHS' => '\$\(PODS_TARGET_SRCROOT\)\/\.\.\/\.\.\/ios\/Sources\/CSQLite'/);
  assert.match(podspec, /OTHER_SWIFT_FLAGS.*-fmodule-map-file=.*CSQLite\/module\.modulemap/);
  assert.match(podspec, /OTHER_CFLAGS.*-fmodule-map-file=.*CSQLite\/module\.modulemap/);
  assert.doesNotMatch(swift, /UserDefaults|AsyncStorage|URLSession|SQLite|chatToken|clientMessageId|message\.text|print\(|NSLog/);
  assert.doesNotMatch(module, /UserDefaults|AsyncStorage|URLSession|SQLite|NSLog|printf|console/);
  assert.match(swift, /observeFrameworkState\(\)/);
  assert.match(swift, /"type": "connectionChanged"/);
  assert.match(swift, /"type": "unreadChanged"/);
  assert.match(swift, /case \.uninitialized: return "uninitialized"/);
  assert.match(swift, /case \.anonymousReady, \.identifiedReady, \.identifying: return "ready"/);
  assert.match(swift, /guard lastUnreadCount != unreadCount else \{ return \}/);
});

test('push navigation is authorised in the core before a host-selected presentation', () => {
  assert.match(swift, /handlePushNotificationFromBridge/);
  assert.match(swift, /guard let host, let target else \{ completion\("deferred", nil\); return \}/);
  assert.match(swift, /presenter\.present\(from: host, conversationId: target\)/);
  assert.match(module, /RCTPresentedViewController\(\)/);
});
