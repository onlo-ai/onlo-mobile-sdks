import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const version = readFileSync(resolve(repositoryRoot, 'VERSION'), 'utf8').trim();
if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version)) {
  throw new Error('VERSION must contain one semantic version');
}

const outputPath = resolve(
  repositoryRoot,
  'packages/ios/Sources/OnloSDK/SDKVersion.swift',
);
const generated = `// Generated from VERSION by scripts/generate-sdk-version.mjs. Do not edit.
import Foundation

enum OnloSDKVersion {
    static let current = "${version}"
}
`;

if (process.argv.includes('--check')) {
  if (readFileSync(outputPath, 'utf8') !== generated) {
    throw new Error('SDKVersion.swift is stale; run npm run generate:version');
  }
  console.log(`Generated iOS SDK version is current (${version}).`);
} else {
  writeFileSync(outputPath, generated);
  console.log(`Generated iOS SDK version ${version}.`);
}
