import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const GENERATED_PATH_PARTS = new Set([
  '.build',
  '.dart_tool',
  '.gradle',
  '.swiftpm',
  'DerivedData',
  'Pods',
  'build',
  'coverage',
  'dist',
  'node_modules',
]);

const SENSITIVE_PATH_PARTS = /^(?:cert|certs|customer-data|jwt|jwts|key|keys|secret|secrets|token|tokens|transcript|transcripts|upload|uploads)$/i;
const SENSITIVE_FILENAMES = /^(?:credentials|google-services|GoogleService-Info|id_ed25519|id_rsa|service-account)(?:\..*)?$/i;
const SENSITIVE_EXTENSIONS = new Set([
  '.cer', '.crt', '.der', '.jks', '.key', '.keystore', '.mobileprovision',
  '.p12', '.pem', '.pfx', '.pkcs12',
]);
const SAFE_TEXT_EXTENSIONS = new Set([
  '.c', '.cc', '.cpp', '.css', '.dart', '.gradle', '.h', '.html', '.java', '.js',
  '.json', '.jsx', '.kt', '.kts', '.m', '.md', '.mjs', '.mm', '.podspec', '.properties',
  '.rb', '.sh', '.swift', '.toml', '.ts', '.tsx', '.txt', '.xml', '.yaml', '.yml',
]);
const SAFE_TEXT_FILENAMES = new Set([
  '.gitignore', 'Gemfile', 'Package.swift', 'Podfile', 'gradlew', 'gradlew.bat',
]);

const PRIVATE_KEY_PATTERN = /-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----/;
const COMPACT_JWT_PATTERN = /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g;
const TEST_PLACEHOLDER_PATTERN = /\b(?:dummy|example|fake|mock|placeholder|redacted|synthetic)\b/i;
export const MAX_SCANNED_FILE_BYTES = 1024 * 1024;

function extension(path) {
  const basename = path.slice(path.lastIndexOf('/') + 1);
  const index = basename.lastIndexOf('.');
  return index <= 0 ? '' : basename.slice(index).toLowerCase();
}

export function classifyPath(rawPath) {
  const path = rawPath.replaceAll('\\', '/');
  const parts = path.split('/').filter(Boolean);
  const basename = parts.at(-1) ?? '';

  if (basename === '.env' || basename.startsWith('.env.')) {
    return { path, reject: 'environment file name', scan: false };
  }
  if (parts.some((part) => SENSITIVE_PATH_PARTS.test(part)) || SENSITIVE_FILENAMES.test(basename)) {
    return { path, reject: 'sensitive data path', scan: false };
  }
  if (SENSITIVE_EXTENSIONS.has(extension(path))) {
    return { path, reject: 'sensitive file extension', scan: false };
  }
  if (parts.some((part) => GENERATED_PATH_PARTS.has(part))) {
    return { path, reject: 'generated dependency or build path', scan: false };
  }

  const scan = SAFE_TEXT_FILENAMES.has(basename) || SAFE_TEXT_EXTENSIONS.has(extension(path));
  return { path, scan };
}

export function auditPaths(
  paths,
  readSafeText,
  inspectFile = () => ({ isSymbolicLink: false, size: 0 }),
) {
  const violations = [];

  for (const rawPath of paths) {
    const classification = classifyPath(rawPath);
    if (classification.reject) {
      violations.push({ path: classification.path, reason: classification.reject });
      continue;
    }
    if (!classification.scan) continue;

    const metadata = inspectFile(classification.path);
    if (metadata.isSymbolicLink) {
      violations.push({ path: classification.path, reason: 'symbolic link' });
      continue;
    }
    if (!Number.isSafeInteger(metadata.size) || metadata.size < 0 || metadata.size > MAX_SCANNED_FILE_BYTES) {
      violations.push({ path: classification.path, reason: 'oversized safe-text file' });
      continue;
    }

    const content = readSafeText(classification.path);
    const privateKeyMatch = PRIVATE_KEY_PATTERN.exec(content);
    if (privateKeyMatch) {
      const start = Math.max(0, privateKeyMatch.index - 80);
      const end = Math.min(content.length, privateKeyMatch.index + privateKeyMatch[0].length + 80);
      if (!TEST_PLACEHOLDER_PATTERN.test(content.slice(start, end))) {
        violations.push({ path: classification.path, reason: 'PEM private key marker' });
      }
    }

    for (const match of content.matchAll(COMPACT_JWT_PATTERN)) {
      const start = Math.max(0, (match.index ?? 0) - 80);
      const end = Math.min(content.length, (match.index ?? 0) + match[0].length + 80);
      const context = content.slice(start, end);
      if (!TEST_PLACEHOLDER_PATTERN.test(context) && match[0] !== 'header.payload.signature') {
        violations.push({ path: classification.path, reason: 'compact JWT-shaped literal' });
        break;
      }
    }
  }

  return violations;
}

function repositoryPaths() {
  const output = execFileSync(
    'git',
    ['ls-files', '--cached', '--others', '--exclude-standard', '-z'],
    { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 },
  );
  return output.split('\0').filter(Boolean);
}

export function runRepositoryAudit() {
  return auditPaths(
    repositoryPaths(),
    (path) => readFileSync(path, 'utf8'),
    (path) => {
      const stat = lstatSync(path);
      return { isSymbolicLink: stat.isSymbolicLink(), size: stat.size };
    },
  );
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const violations = runRepositoryAudit();
  if (violations.length > 0) {
    console.error('Repository hygiene check failed:');
    for (const violation of violations) console.error(`- ${violation.path}: ${violation.reason}`);
    process.exitCode = 1;
  } else {
    console.log('Repository hygiene check passed.');
  }
}
