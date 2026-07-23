import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const moduleSource = await readFile(
  new URL('../android/src/main/kotlin/ai/onlo/reactnative/OnloSDKModule.kt', import.meta.url),
  'utf8',
);
const packageSource = await readFile(
  new URL('../android/src/main/kotlin/ai/onlo/reactnative/OnloSDKPackage.kt', import.meta.url),
  'utf8',
);
const manifest = await readFile(new URL('../android/src/main/AndroidManifest.xml', import.meta.url), 'utf8');
const configSource = await readFile(new URL('../react-native.config.js', import.meta.url), 'utf8');
const coreInitializerSource = await readFile(
  new URL('../../android/src/main/kotlin/ai/onlo/sdk/Onlo.kt', import.meta.url),
  'utf8',
);

test('Android adapter delegates every supported operation to the native core', () => {
  assert.match(moduleSource, /OnloReactNativeBridge\.initialize/);
  for (const method of [
    'setLogLevel',
    'initialize',
    'loginUnidentifiedUser',
    'loginIdentifiedUser',
    'logout',
    'present',
    'dismiss',
    'openConversation',
    'setPushToken',
    'handlePushNotification',
  ]) {
    assert.match(moduleSource, new RegExp(`override fun ${method}\\b`));
  }
  assert.match(moduleSource, /core\.state\.collect/);
  assert.match(moduleSource, /emitOnOnloEvent/);
  assert.match(moduleSource, /"connectionChanged"/);
  assert.match(moduleSource, /core\.unreadCount\.collect/);
  assert.match(moduleSource, /"unreadCountChanged"/);
  assert.match(moduleSource, /OnloPhase\.RESTORING -> "uninitialized"/);
  assert.match(moduleSource, /OnloPhase\.OFFLINE_READY -> "offline"/);
  assert.match(moduleSource, /OnloMessenger\.present\(requireCurrentActivity\(\), requireClient\(\)\)/);
  assert.match(moduleSource, /OnloMessenger\.dismiss\(\)/);
  assert.match(moduleSource, /currentActivity/);
  assert.doesNotMatch(moduleSource, /PRESENTER_OUTCOME_GATE/);
  assert.match(moduleSource, /OnloMessenger\.openConversation\(requireCurrentActivity\(\), conversationId, requireClient\(\)\)/);
  assert.match(moduleSource, /OnloMessenger\.openConversation\(activity, outcome\.conversationId, core\)/);
  assert.match(moduleSource, /availableCurrentActivity\(\) \?: return@runResultOperation "deferred"/);
});

test('Android adapter contains no parallel storage, transport, or sensitive logging', () => {
  assert.doesNotMatch(moduleSource, /AsyncStorage|SharedPreferences|SQLite|OkHttp|HttpUrl|Log\.|println\(|ConversationDetail|TranscriptMessage|\.message\b/);
  assert.doesNotMatch(manifest, /<uses-permission|<activity|<service|<provider/);
});

test('autolinking registers the Android package and local iOS pod', () => {
  assert.match(packageSource, /listOf\(OnloSDKModule\(reactContext\)\)/);
  assert.match(configSource, /sourceDir: '\.\/android'/);
  assert.match(configSource, /podspecPath: '\.\/ios\/OnloReactNative\.podspec'/);
});

test('Android core declares only available FCM push capability, never attachment capability', () => {
  assert.match(coreInitializerSource, /Capability\.FCM/);
  assert.doesNotMatch(coreInitializerSource, /Capability\.(MEDIA_PICKER|ATTACHMENT_UPLOAD)/);
});
