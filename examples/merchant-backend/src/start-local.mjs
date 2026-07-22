import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const backendDirectory = fileURLToPath(new URL('../', import.meta.url));
const localDirectory = fileURLToPath(new URL('../.local/', import.meta.url));
const certificatePath = `${localDirectory}localhost-cert.pem`;
const keyPath = `${localDirectory}localhost-key.pem`;
const safeLogPath = `${localDirectory}merchant-backend.log`;

if (process.env.NODE_ENVIRONMENT !== 'development') {
  console.error('This fixed-user simulator runs only with NODE_ENVIRONMENT=development.');
  process.exitCode = 1;
} else try {
  mkdirSync(localDirectory, { recursive: true });
  if (!existsSync(certificatePath) || !existsSync(keyPath)) {
    execFileSync('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', keyPath,
      '-out', certificatePath,
      '-days', '7',
      '-subj', '/CN=127.0.0.1',
      '-addext', 'subjectAltName=IP:127.0.0.1',
    ], { stdio: 'ignore' });
    console.log('Generated an ignored local TLS certificate for the merchant backend.');
  }
} catch {
  console.error('Could not prepare local TLS. Install OpenSSL, then run npm start again.');
  process.exitCode = 1;
}

if (process.exitCode !== 1) {
  const child = spawn(process.execPath, ['src/server.mjs'], {
    cwd: backendDirectory,
    env: {
      ...process.env,
      MERCHANT_BACKEND_TLS_CERT_PATH: certificatePath,
      MERCHANT_BACKEND_TLS_KEY_PATH: keyPath,
      MERCHANT_BACKEND_SAFE_LOG_PATH: safeLogPath,
    },
    stdio: 'inherit',
  });
  child.on('exit', (code) => { process.exitCode = code ?? 1; });
}
