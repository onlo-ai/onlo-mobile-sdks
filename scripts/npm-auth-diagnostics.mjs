import {spawnSync} from 'node:child_process';

const registry = 'https://registry.npmjs.org/';
const packageName = '@onlo-ai/react-native';
function run(args) {
  const result = spawnSync('npm', [...args, '--json', '--registry', registry], {encoding: 'utf8'});
  let body;
  try { body = JSON.parse(result.stdout); } catch { body = undefined; }
  const errorCode = String(body?.error?.code ?? result.stderr.match(/\bE(?:401|403|404|OTP|NEEDAUTH)\b/)?.[0] ?? 'UNKNOWN');
  if (result.status !== 0) throw new Error(`npm ${args[0]} failed: ${errorCode}`);
  return body;
}
try {
  if (!process.env.NODE_AUTH_TOKEN) throw new Error('NPM_TOKEN_MISSING');
  const identity = run(['whoami']);
  if (typeof identity !== 'string' || !identity) throw new Error('npm identity unavailable');
  const access = run(['access', 'list', 'packages', identity]);
  const permission = access?.[packageName];
  console.log(JSON.stringify({registry, package: packageName, authenticated: true, packagePermission: permission ?? 'none'}));
  if (permission !== 'read-write') throw new Error('npm account does not have package write access');
  console.log('Read-only diagnosis passed. This does not prove token publish scope, 2FA bypass, or historical E404 root cause.');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
