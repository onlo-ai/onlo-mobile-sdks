import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const semverPattern = /^[0-9]+\.[0-9]+\.[0-9]+$/;

function read(path) {
  return readFileSync(resolve(repositoryRoot, path), 'utf8');
}

function json(path) {
  return JSON.parse(read(path));
}

function manifestVersion(path) {
  const value = json(path).version;
  assert.match(value, semverPattern, `${path} must contain a semantic version`);
  return value;
}

export function checkVersions(expectedVersion) {
  const version = read('VERSION').trim();
  assert.match(version, semverPattern, 'VERSION must contain one semantic version');
  if (expectedVersion !== undefined) {
    assert.equal(version, expectedVersion, 'VERSION does not match the requested release version');
  }

  for (const path of [
    'package.json',
    'packages/protocol/package.json',
    'packages/react-native/package.json',
  ]) {
    assert.equal(manifestVersion(path), version, `${path} does not match VERSION`);
  }
  assert.equal(
    json('packages/react-native/package.json').name,
    '@onlo-ai/react-native',
    'React Native package identity changed',
  );

  const rootLock = json('package-lock.json');
  assert.equal(rootLock.version, version, 'package-lock.json does not match VERSION');
  assert.equal(rootLock.packages[''].version, version, 'root lock package does not match VERSION');
  assert.equal(
    rootLock.packages['packages/protocol'].version,
    version,
    'protocol lock package does not match VERSION',
  );

  const flutterVersion = read('packages/flutter/pubspec.yaml')
    .match(/^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$/m)?.[1];
  assert.equal(flutterVersion, version, 'packages/flutter/pubspec.yaml does not match VERSION');

  const androidBuild = read('packages/android/build.gradle.kts');
  assert.match(androidBuild, /project\.file\("\.\.\/\.\.\/VERSION"\)/);
  assert.match(androidBuild, /buildConfigField\("String", "ONLO_SDK_VERSION"/);
  assert.match(androidBuild, /onloReleaseVersion == canonicalVersion/);
  assert.match(
    read('packages/android/src/main/kotlin/ai/onlo/sdk/OnloClient.kt'),
    /SDK_VERSION: String = BuildConfig\.ONLO_SDK_VERSION/,
  );

  const iosVersionSource = read('packages/ios/Sources/OnloSDK/SDKVersion.swift');
  assert.match(
    iosVersionSource,
    new RegExp(`static let current = ["']${version.replaceAll('.', '\\.')}["']`),
  );
  assert.match(iosVersionSource, /Generated from VERSION by scripts\/generate-sdk-version\.mjs/);
  assert.match(
    read('packages/ios/Sources/OnloSDK/OnloSDK.swift'),
    /sdkVersion: String = OnloSDKVersion\.current/,
  );
  const podspec = read('OnloSDK.podspec');
  assert.match(podspec, /File\.read\(File\.join\(__dir__, 'VERSION'\)\)/);
  assert.match(podspec, /s\.version\s*= onlo_sdk_version/);
  assert.doesNotMatch(podspec, /resource_bundles/);

  const reactNativePodspec = read('packages/react-native/OnloReactNative.podspec');
  assert.match(reactNativePodspec, /package_version = package\.fetch\('version'\)/);
  assert.match(reactNativePodspec, /s\.dependency 'OnloSDK', package_version/);
  assert.match(
    read('packages/react-native/android/build.gradle'),
    /getOrElse\(packageVersion\)/,
  );

  const flutterPodspec = read('packages/flutter/ios/onlo_flutter.podspec');
  assert.match(flutterPodspec, /package_version = pubspec\[/);
  assert.match(flutterPodspec, /s\.dependency 'OnloSDK', package_version/);
  assert.match(read('packages/flutter/android/build.gradle'), /getOrElse\(packageVersion\)/);

  const escapedVersion = version.replaceAll('.', '\\.');
  for (const path of [
    'CHANGELOG.md',
    'packages/android/CHANGELOG.md',
    'packages/ios/CHANGELOG.md',
    'packages/react-native/CHANGELOG.md',
    'packages/flutter/CHANGELOG.md',
  ]) {
    assert.match(
      read(path),
      new RegExp(`^## ${escapedVersion}$`, 'm'),
      `${path} has no section for VERSION`,
    );
  }

  return version;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const expectedIndex = process.argv.indexOf('--expected');
  const expected = expectedIndex === -1 ? undefined : process.argv[expectedIndex + 1];
  if (expectedIndex !== -1 && !expected) throw new Error('--expected requires a version');
  const version = checkVersions(expected);
  console.log(`Version consistency check passed (${version}).`);
}
