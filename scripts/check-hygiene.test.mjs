import assert from 'node:assert/strict';
import test from 'node:test';

import { auditPaths, classifyPath, MAX_SCANNED_FILE_BYTES } from './check-hygiene.mjs';

test('rejects sensitive and generated paths before reading content', () => {
  const paths = [
    '.env.local',
    'private/token/value.txt',
    'certificates/signing.p12',
    'packages/example/node_modules/dependency/index.js',
    'src/index.ts',
  ];
  const reads = [];
  const violations = auditPaths(paths, (path) => {
    reads.push(path);
    return 'export const safe = true;';
  });

  assert.deepEqual(reads, ['src/index.ts']);
  assert.deepEqual(violations, [
    { path: '.env.local', reason: 'environment file name' },
    { path: 'private/token/value.txt', reason: 'sensitive data path' },
    { path: 'certificates/signing.p12', reason: 'sensitive file extension' },
    { path: 'packages/example/node_modules/dependency/index.js', reason: 'generated dependency or build path' },
  ]);
});

test('detects private keys and non-placeholder compact JWT literals in safe text only', () => {
  const content = new Map([
    ['src/crypto-fixture.ts', ['const value = "-----BEGIN ', 'PRIVATE KEY-----";'].join('')],
    ['docs/sample.md', ['Unexpected value: eyJhbGciOiJIUzI1NiJ9', 'eyJzdWIiOiJjdXN0b21lciJ9', 'abcdefghijk'].join('.')],
    ['contracts/redacted.json', ['{"note":"synthetic","value":"-----BEGIN ', 'PRIVATE KEY-----"}'].join('')],
    ['assets/image.png', ['eyJhbGciOiJIUzI1NiJ9', 'eyJzdWIiOiJjdXN0b21lciJ9', 'abcdefghijk'].join('.')],
  ]);
  const reads = [];
  const violations = auditPaths([...content.keys()], (path) => {
    reads.push(path);
    return content.get(path);
  });

  assert.deepEqual(reads, ['src/crypto-fixture.ts', 'docs/sample.md', 'contracts/redacted.json']);
  assert.deepEqual(violations, [
    { path: 'src/crypto-fixture.ts', reason: 'PEM private key marker' },
    { path: 'docs/sample.md', reason: 'compact JWT-shaped literal' },
  ]);
});

test('does not treat API descriptor filenames as credential paths', () => {
  assert.deepEqual(classifyPath('contracts/v1/push-token.register.request.json'), {
    path: 'contracts/v1/push-token.register.request.json',
    scan: true,
  });
  assert.deepEqual(classifyPath('packages/protocol/src/TokenTypes.ts'), {
    path: 'packages/protocol/src/TokenTypes.ts',
    scan: true,
  });
});

test('rejects symlinks and oversized text before calling the reader', () => {
  const paths = ['src/link.ts', 'docs/oversized.md', 'src/safe.ts'];
  const reads = [];
  const metadata = new Map([
    ['src/link.ts', { isSymbolicLink: true, size: 12 }],
    ['docs/oversized.md', { isSymbolicLink: false, size: MAX_SCANNED_FILE_BYTES + 1 }],
    ['src/safe.ts', { isSymbolicLink: false, size: 24 }],
  ]);

  const violations = auditPaths(
    paths,
    (path) => {
      reads.push(path);
      return 'export const safe = true;';
    },
    (path) => metadata.get(path),
  );

  assert.deepEqual(reads, ['src/safe.ts']);
  assert.deepEqual(violations, [
    { path: 'src/link.ts', reason: 'symbolic link' },
    { path: 'docs/oversized.md', reason: 'oversized safe-text file' },
  ]);
});
