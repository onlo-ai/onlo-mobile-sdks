"""Fail-closed release content verification. No upload or credential access."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.error
import urllib.parse
import urllib.request

SDK_NAMES = {'ios', 'android', 'flutter', 'react-native'}
ALLOWED_HOSTS = {'trunk.cocoapods.org', 'repo1.maven.org', 'pub.dev', 'registry.npmjs.org', 'codeload.github.com', 'raw.githubusercontent.com'}
MAX_BYTES = 200 * 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def archive_content(data, strip_root=False):
    """Hash regular-file paths, executable bits and bytes; ignore archive timestamps."""
    entries = {}
    total = 0
    roots = set()
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
        for item in archive:
            path = PurePosixPath(item.name)
            if path.is_absolute() or '..' in path.parts or '\\' in item.name:
                raise ValueError('unsafe archive path')
            if item.isdir():
                continue
            if not item.isfile():
                raise ValueError('unsupported archive member')
            parts = path.parts
            roots.add(parts[0])
            name = '/'.join(parts[1:] if strip_root else parts)
            if not name or name in entries:
                raise ValueError('empty or duplicate archive path')
            total += item.size
            if total > MAX_BYTES:
                raise ValueError('archive exceeds size limit')
            content = archive.extractfile(item).read()
            entries[name] = {'sha256': sha(content), 'executable': bool(item.mode & 0o111)}
    if not entries or (strip_root and len(roots) != 1):
        raise ValueError('empty archive or inconsistent root')
    return sha(canonical_json(entries))


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_url(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != 'https' or parsed.hostname not in ALLOWED_HOSTS or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError('unexpected registry URL')
    if parsed.hostname == 'raw.githubusercontent.com' and not parsed.path.startswith('/CocoaPods/Specs/'):
        raise ValueError('unexpected CocoaPods source path')


def fetch(url):
    check_url(url)
    try:
        with urllib.request.build_opener(SafeRedirect()).open(url, timeout=60) as response:
            data = response.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise ValueError('registry artifact exceeds size limit')
            return data
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise RuntimeError(f'registry HTTP {error.code}') from None


def digest(data, mode, strip_root=False):
    if mode == 'bytes':
        return sha(data)
    if mode == 'json':
        return sha(canonical_json(json.loads(data)))
    if mode == 'tar-content':
        return archive_content(data, strip_root)
    raise ValueError('unknown hash format')


def verify_sdk(name, expected, version, get=fetch):
    """Only a 404 is missing. Timeouts/auth errors are unverifiable, never skip."""
    results = []
    for artifact in expected:
        body = get(artifact['url'])
        if body is None:
            results.append('missing')
            continue
        if artifact.get('download_key'):
            metadata = json.loads(body)
            url = metadata
            for key in artifact['download_key'].split('.'):
                url = url[key]
            body = get(url)
            if body is None:
                raise ValueError('metadata references missing artifact')
        actual = digest(body, artifact['mode'], artifact.get('strip_root', False))
        if actual != artifact['sha256']:
            return 'mismatch'
        results.append('verified')
    if not results:
        raise ValueError('empty SDK manifest')
    if all(item == 'verified' for item in results):
        return 'verified'
    # A partial Maven/iOS publication must not be uploaded again.
    if name == 'ios' and results == ['missing', 'missing']:
        return 'unverifiable'
    if name == 'ios' and results == ['missing', 'verified']:
        return 'missing'  # Approved source tag exists; CocoaPods is not published yet.
    return 'missing' if all(item == 'missing' for item in results) else 'partial'


def verify_all(manifest, get=fetch):
    if manifest.get('schema') != 1 or set(manifest['sdks']) != SDK_NAMES:
        raise ValueError('manifest must include all four SDKs')
    states = {}
    for name, artifacts in manifest['sdks'].items():
        try:
            states[name] = verify_sdk(name, artifacts, manifest['version'], get)
        except Exception as error:
            states[name] = 'unverifiable'
    return states


def publication_decision(states):
    if set(states) != SDK_NAMES:
        raise ValueError('four SDK results required')
    if any(value not in ('missing', 'verified') for value in states.values()):
        return 'hard-stop'
    return 'finalize' if all(value == 'verified' for value in states.values()) else 'publish-missing'


def verify_local(directory, manifest):
    actual = {str(p.relative_to(directory)) for p in directory.rglob('*') if p.is_file() and p != directory / 'manifest.json'}
    if actual != set(manifest['files']):
        raise ValueError('prepared file set differs from approved manifest')
    for name, expected in manifest['files'].items():
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('unsafe manifest file path')
        if (directory / name).is_symlink():
            raise ValueError('prepared symlink forbidden')
        if sha((directory / name).read_bytes()) != expected:
            raise ValueError('prepared artifact hash mismatch: ' + name)


def build_manifest(directory, version, commit):
    sdks = {}
    base = f'https://repo1.maven.org/maven2/ai/onlo/onlo-android-sdk/{version}/'
    maven = sorted((directory / 'maven').glob('*'))
    required = {f'onlo-android-sdk-{version}{suffix}' for suffix in ('.aar', '.pom', '-sources.jar', '-javadoc.jar')}
    if not required.issubset({p.name for p in maven}):
        raise ValueError('incomplete Maven artifacts')
    sdks['android'] = [{'url': base + p.name, 'mode': 'bytes', 'sha256': sha(p.read_bytes())} for p in maven if p.suffix in ('.aar', '.jar', '.pom', '.module')]
    sdks['ios'] = [
        {'url': f'https://trunk.cocoapods.org/api/v1/pods/OnloSDK/specs/{version}', 'mode': 'json', 'sha256': digest((directory / 'OnloSDK.podspec.json').read_bytes(), 'json')},
        {'url': f'https://codeload.github.com/onlo-ai/onlo-mobile-sdks/tar.gz/refs/tags/{version}', 'mode': 'tar-content', 'strip_root': True, 'sha256': archive_content((directory / 'ios-source.tar.gz').read_bytes())},
    ]
    # iOS source tag exists before pod publication. The orchestrator treats that
    # particular partial state as publishable only after independently matching source.
    sdks['react-native'] = [{'url': f'https://registry.npmjs.org/@onlo-ai/react-native/{version}', 'mode': 'bytes', 'download_key': 'dist.tarball', 'sha256': sha((directory / 'react-native.tgz').read_bytes())}]
    sdks['flutter'] = [{'url': f'https://pub.dev/api/packages/onlo_flutter/versions/{version}', 'mode': 'bytes', 'download_key': 'archive_url', 'sha256': sha((directory / 'flutter.tar.gz').read_bytes())}]
    files = {str(p.relative_to(directory)): sha(p.read_bytes()) for p in sorted(directory.rglob('*')) if p.is_file() and p != directory / 'manifest.json'}
    return {'schema': 1, 'version': version, 'commit': commit, 'sdks': sdks, 'files': files}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['create', 'local', 'registry'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--version')
    parser.add_argument('--commit')
    args = parser.parse_args()
    path = args.directory / 'manifest.json'
    if args.command == 'create':
        path.write_text(json.dumps(build_manifest(args.directory, args.version, args.commit), indent=2) + '\n')
        return
    manifest = json.loads(path.read_text())
    verify_local(args.directory, manifest)
    if args.command == 'registry':
        states = verify_all(manifest)
        print(json.dumps(states, sort_keys=True))
        if publication_decision(states) != 'finalize':
            raise SystemExit(1)


if __name__ == '__main__':
    main()
