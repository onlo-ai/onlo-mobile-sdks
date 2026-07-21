import assert from 'node:assert/strict';
import { lstatSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { classifyPath, MAX_SCANNED_FILE_BYTES } from '../../scripts/check-hygiene.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const scenariosDirectory = path.join(root, 'conformance/scenarios/v1');
const contractsDirectory = path.join(root, 'contracts/v1');
const sharedManifestPath = path.join(root, 'conformance/shared-fixtures-v1.json');
const PLACEHOLDER = /(?:dummy|example|fake|mock|opaque|optional|placeholder|redacted|server-issued|synthetic)/i;
const SENSITIVE_VALUE_KEY = /^(?:answer|authenticatedDownload|chatToken|content|intent|question|receipt|token|url|userJwt)$/i;
const PRIVATE_KEY = /-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----/;
const COMPACT_JWT = /^eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$/;

function validateFixturePath(fixturePath) {
  assert.equal(typeof fixturePath, 'string');
  assert.ok(fixturePath.length > 0, 'fixture path must not be empty');
  assert.equal(path.isAbsolute(fixturePath), false, `${fixturePath} must be relative`);
  assert.equal(fixturePath.includes('\\'), false, `${fixturePath} must use POSIX separators`);
  assert.equal(fixturePath.split('/').includes('..'), false, `${fixturePath} must not traverse`);
  assert.equal(path.posix.normalize(fixturePath), fixturePath, `${fixturePath} must be normalized`);
  assert.equal(path.posix.dirname(fixturePath), 'contracts/v1', `${fixturePath} must be directly under contracts/v1`);
  assert.equal(path.posix.extname(fixturePath), '.json', `${fixturePath} must be JSON`);

  const classification = classifyPath(fixturePath);
  assert.equal(classification.reject, undefined, `${fixturePath} is a prohibited path`);
  assert.equal(classification.scan, true, `${fixturePath} must be safe text`);
}

function validateSyntheticContent(value, location = '$') {
  if (Array.isArray(value)) {
    value.forEach((item, index) => validateSyntheticContent(item, `${location}[${index}]`));
    return;
  }
  if (typeof value !== 'object' || value === null) return;
  const isTranscriptMessage = 'timestamp' in value && 'role' in value && 'text' in value;
  const isChatRequest = 'sessionId' in value && 'clientMessageId' in value && 'message' in value;

  for (const [key, child] of Object.entries(value)) {
    const childLocation = `${location}.${key}`;
    if (typeof child === 'string') {
      assert.equal(/^https?:\/\//i.test(child), false, `${childLocation} contains a URL`);
      assert.equal(PRIVATE_KEY.test(child), false, `${childLocation} contains a private key`);
      if (COMPACT_JWT.test(child)) {
        assert.match(child, PLACEHOLDER, `${childLocation} contains a non-placeholder JWT`);
      }
      if (SENSITIVE_VALUE_KEY.test(key) || (key === 'text' && isTranscriptMessage) || (key === 'message' && isChatRequest)) {
        assert.match(child, PLACEHOLDER, `${childLocation} must be synthetic or redacted`);
      }
    }
    validateSyntheticContent(child, childLocation);
  }
}

function loadFixture(fixturePath, io = {}) {
  validateFixturePath(fixturePath);
  const absolutePath = path.join(root, fixturePath);
  const inspect = io.inspect ?? ((target) => lstatSync(target));
  const read = io.read ?? ((target) => readFileSync(target, 'utf8'));
  const stat = inspect(absolutePath);
  assert.equal(stat.isSymbolicLink(), false, `${fixturePath} must not be a symbolic link`);
  assert.equal(stat.isFile(), true, `${fixturePath} must be a regular file`);
  assert.ok(stat.size <= MAX_SCANNED_FILE_BYTES, `${fixturePath} exceeds the scan limit`);
  const parsed = JSON.parse(read(absolutePath));
  validateSyntheticContent(parsed);
  return parsed;
}

function loadJsonFile(absolutePath) {
  const stat = lstatSync(absolutePath);
  assert.equal(stat.isSymbolicLink(), false, `${absolutePath} must not be a symbolic link`);
  assert.equal(stat.isFile(), true, `${absolutePath} must be a regular file`);
  assert.ok(stat.size <= MAX_SCANNED_FILE_BYTES, `${absolutePath} exceeds the scan limit`);
  return JSON.parse(readFileSync(absolutePath, 'utf8'));
}

test('every v1 scenario is well-formed and references safe parseable fixtures', () => {
  const scenarioEntries = readdirSync(scenariosDirectory, { withFileTypes: true })
    .filter((entry) => entry.name.endsWith('.json'))
    .sort((left, right) => left.name.localeCompare(right.name));
  assert.ok(scenarioEntries.length > 0);

  const scenarioNames = new Set();
  const referencedFixtures = new Set();
  for (const entry of scenarioEntries) {
    assert.equal(entry.isSymbolicLink(), false, `${entry.name} must not be a symbolic link`);
    assert.equal(entry.isFile(), true, `${entry.name} must be a regular file`);
    const scenario = loadJsonFile(path.join(scenariosDirectory, entry.name));
    assert.equal(scenario.protocolVersion, 1, `${entry.name} must target protocol v1`);
    assert.match(scenario.scenario, /^[a-z0-9]+(?:-[a-z0-9]+)*$/);
    assert.equal(entry.name, `${scenario.scenario}.json`);
    assert.equal(scenarioNames.has(scenario.scenario), false, `duplicate scenario ${scenario.scenario}`);
    scenarioNames.add(scenario.scenario);
    assert.ok(Array.isArray(scenario.fixtures) && scenario.fixtures.length > 0, `${entry.name} needs fixtures`);
    assert.ok(Array.isArray(scenario.assertions) && scenario.assertions.length > 0, `${entry.name} needs assertions`);
    for (const assertion of scenario.assertions) {
      assert.equal(typeof assertion, 'string');
      assert.ok(assertion.trim().length > 0, `${entry.name} contains an empty assertion`);
    }
    for (const fixturePath of scenario.fixtures) {
      loadFixture(fixturePath);
      referencedFixtures.add(fixturePath);
    }
  }

  const shared = loadJsonFile(sharedManifestPath);
  assert.equal(shared.protocolVersion, 1);
  assert.ok(Array.isArray(shared.sharedFixtures));
  const sharedFixtures = new Set();
  for (const item of shared.sharedFixtures) {
    assert.deepEqual(Object.keys(item).sort(), ['path', 'reason']);
    assert.equal(typeof item.reason, 'string');
    assert.ok(item.reason.trim().length > 0);
    loadFixture(item.path);
    sharedFixtures.add(item.path);
  }

  const contractFixtures = readdirSync(contractsDirectory, { withFileTypes: true })
    .filter((entry) => entry.name.endsWith('.json'))
    .map((entry) => {
      assert.equal(entry.isSymbolicLink(), false, `${entry.name} must not be a symbolic link`);
      assert.equal(entry.isFile(), true, `${entry.name} must be a regular file`);
      return `contracts/v1/${entry.name}`;
    })
    .sort();
  const classifiedFixtures = new Set([...referencedFixtures, ...sharedFixtures]);
  assert.deepEqual([...classifiedFixtures].sort(), contractFixtures);
});

test('prohibited and traversing fixture paths fail before filesystem access', () => {
  for (const prohibitedPath of ['../outside.json', '/absolute.json', 'contracts/v1/token/value.json']) {
    let inspected = false;
    let read = false;
    assert.throws(() => loadFixture(prohibitedPath, {
      inspect() {
        inspected = true;
        throw new Error('must not inspect');
      },
      read() {
        read = true;
        throw new Error('must not read');
      },
    }));
    assert.equal(inspected, false);
    assert.equal(read, false);
  }
});
