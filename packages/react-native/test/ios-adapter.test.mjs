import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const podspec = await readFile(new URL('../OnloReactNative.podspec', import.meta.url), 'utf8');
const swift = await readFile(new URL('../ios/Sources/OnloReactNativeIOSBridge.swift', import.meta.url), 'utf8');
const module = await readFile(new URL('../ios/Sources/OnloSDKModule.mm', import.meta.url), 'utf8');
const config = await readFile(new URL('../react-native.config.js', import.meta.url), 'utf8');

test('iOS adapter delegates the public RN surface to one native OnloSDK core', () => {
  assert.match(swift, /private let sdk = OnloSDK\(\)/);
  assert.match(swift, /initializeFrameworkBridge\(sdkKey: sdkKey, sdkFamily: \.reactNative\)/);
  for (const seam of ['loginUnidentifiedUser', 'loginIdentifiedUser', 'logout', 'setAPNsPushToken', 'handlePushNotificationFromBridge']) {
    assert.match(swift, new RegExp(`sdk\\.${seam}`));
  }
  assert.match(swift, /OnloMessengerPresenter\(sdk: sdk, options: options\)/);
  assert.match(swift, /presenter\?\.isPresentingFrameworkMessenger != true/);
  assert.match(swift, /case nil, "contained": return OnloMessengerOptions\(presentationMode: \.contained\)/);
  assert.match(swift, /case "fullScreen": return OnloMessengerOptions\(presentationMode: \.fullScreen\)/);
  assert.match(module, /RCT_EXPORT_MODULE\(OnloSDK\)/);
  assert.match(module, /#import <OnloSDKSpec\/OnloSDKSpec\.h>/);
  assert.match(module, /NativeOnloSDKSpecJSI/);
  for (const method of ['setLogLevel', 'initialize', 'loginUnidentifiedUser', 'loginIdentifiedUser', 'logout', 'present', 'dismiss', 'openConversation', 'setPushToken', 'handlePushNotification']) {
    assert.match(module, new RegExp(`RCT_REMAP_METHOD\\(${method}`));
  }
});

test('iOS adapter is a local autolinked pod with no parallel persistence, network, or content state', () => {
  assert.match(config, /ios: \{\}/);
  assert.match(podspec, /s\.dependency 'OnloSDK', '0\.1\.0'/);
  assert.match(swift, /import OnloSDK/);
  assert.doesNotMatch(podspec, /Sources\/OnloSDK\/\*\*/);
  assert.doesNotMatch(swift, /UserDefaults|AsyncStorage|URLSession|SQLite|chatToken|clientMessageId|message\.text|print\(|NSLog/);
  assert.doesNotMatch(module, /UserDefaults|AsyncStorage|URLSession|SQLite|NSLog|printf|console/);
  assert.match(swift, /observeFrameworkState\(\)/);
  assert.match(swift, /"type": "connectionChanged"/);
  assert.match(swift, /"type": "unreadCountChanged"/);
  assert.match(swift, /snapshot\.unreadCount/);
  assert.match(swift, /case \.uninitialized: return "uninitialized"/);
  assert.match(swift, /case \.anonymousReady, \.identifiedReady, \.identifying: return "ready"/);
});

test('push navigation is authorised in the core before a host-selected presentation', () => {
  assert.match(swift, /handlePushNotificationFromBridge/);
  assert.match(swift, /guard let host, let target else \{ completion\("deferred", nil\); return \}/);
  assert.match(swift, /presentMessenger\(from: host, conversationID: target\)/);
  assert.match(module, /RCTPresentedViewController\(\)/);
});
