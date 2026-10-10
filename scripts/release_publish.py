"""Publish only approved prepared bytes; ambiguous uploads require manual diagnosis."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
import zipfile
from release_artifacts import sha, verify_local, verify_all, publication_decision
from release_control import REPO, authority, release, run, upload_status


def central_request(path, data=None, content_type=None):
    token = base64.b64encode((os.environ['MAVEN_CENTRAL_USERNAME'] + ':' + os.environ['MAVEN_CENTRAL_PASSWORD']).encode()).decode()
    headers = {'Authorization': 'Bearer ' + token}
    if content_type:
        headers['Content-Type'] = content_type
    request = urllib.request.Request('https://central.sonatype.com/api/v1/publisher/' + path, data=data, headers=headers, method='POST')
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def publish_maven(directory, version, remember):
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        home = root / 'gnupg'
        home.mkdir(mode=0o700)
        subprocess.run(['gpg', '--batch', '--homedir', str(home), '--import'], input=os.environ['MAVEN_SIGNING_KEY'].encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        files = root / 'bundle/ai/onlo/onlo-android-sdk' / version
        shutil.copytree(directory / 'maven', files)
        for path in sorted(files.iterdir()):
            subprocess.run(['gpg', '--batch', '--homedir', str(home), '--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--armor', '--detach-sign', str(path)], input=os.environ['MAVEN_SIGNING_PASSWORD'].encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        for path in list(files.iterdir()):
            for algorithm in ('md5', 'sha1', 'sha256', 'sha512'):
                (files / (path.name + '.' + algorithm)).write_text(hashlib.new(algorithm, path.read_bytes()).hexdigest())
        bundle = root / 'bundle.zip'
        with zipfile.ZipFile(bundle, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in sorted((root / 'bundle').rglob('*')):
                if path.is_file():
                    archive.write(path, str(path.relative_to(root / 'bundle')))
        boundary = 'onlo-' + uuid.uuid4().hex
        payload = (f'--{boundary}\r\nContent-Disposition: form-data; name="bundle"; filename="bundle.zip"\r\nContent-Type: application/zip\r\n\r\n'.encode() + bundle.read_bytes() + f'\r\n--{boundary}--\r\n'.encode())
        deployment = central_request('upload?publishingType=AUTOMATIC', payload, 'multipart/form-data; boundary=' + boundary).decode().strip()
        if not all(c in '0123456789abcdef-' for c in deployment) or not deployment:
            raise ValueError('Central returned unexpected deployment identity')
        remember(deployment)
        for _ in range(120):
            state = json.loads(central_request('status?id=' + deployment))['deploymentState']
            if state == 'PUBLISHED':
                return
            if state == 'FAILED':
                raise ValueError('Central validation failed; inspect deployment before retry')
            time.sleep(15)
        raise TimeoutError('Central publication unconfirmed; do not upload again')


def require_npm_oidc(version):
    # Prerequisites only: npm validates the trust relationship during publish.
    expected = f'{REPO}/.github/workflows/publish.yml@refs/tags/{version}'
    if (os.environ.get('GITHUB_ACTIONS') != 'true'
            or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or os.environ.get('GITHUB_WORKFLOW_REF') != expected
            or not os.environ.get('ACTIONS_ID_TOKEN_REQUEST_URL')
            or not os.environ.get('ACTIONS_ID_TOKEN_REQUEST_TOKEN')):
        raise ValueError('npm requires the approved GitHub-hosted OIDC workflow')
    if any(os.environ.get(key) for key in ('NODE_AUTH_TOKEN', 'NPM_TOKEN', 'NPM_CONFIG__AUTH', 'NPM_CONFIG__AUTHTOKEN')):
        raise ValueError('long-lived npm authentication is forbidden in the OIDC job')
    node = tuple(int(part) for part in run('node', '--version').lstrip('v').split('.'))
    if node < (24, 15, 0) or run('npm', '--version') != '12.2.0':
        raise ValueError('npm OIDC requires Node >=24.15.0 and pinned npm 12.2.0')


def publish_flutter(directory):
    # setup-dart registers PUB_TOKEN; earlier registry uploads may outlive that JWT.
    # Mint immediately before upload and keep it in this child process environment.
    endpoint = os.environ.get('ACTIONS_ID_TOKEN_REQUEST_URL', '')
    request_token = os.environ.get('ACTIONS_ID_TOKEN_REQUEST_TOKEN', '')
    if urllib.parse.urlsplit(endpoint).scheme != 'https' or not request_token:
        raise ValueError('Flutter publication requires GitHub OIDC credentials')
    parts = urllib.parse.urlsplit(endpoint)
    query = dict(urllib.parse.parse_qsl(parts.query))
    query['audience'] = 'https://pub.dev'
    endpoint = urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))
    request = urllib.request.Request(endpoint, headers={'Authorization': 'Bearer ' + request_token})
    with urllib.request.urlopen(request, timeout=30) as response:
        token = json.load(response).get('value')
    if not isinstance(token, str) or not token:
        raise ValueError('GitHub OIDC response missing token')
    environment = os.environ.copy()
    environment['PUB_TOKEN'] = token
    subprocess.run(['dart', 'pub', 'publish', '--force', '--from-archive=' + str(directory / 'flutter.tar.gz')], env=environment, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('version')
    parser.add_argument('directory', type=Path)
    parser.add_argument('--manifest-sha', required=True)
    args = parser.parse_args()
    commit = authority(args.version)
    if not release(args.version)['isDraft']:
        raise ValueError('draft release required')
    path = args.directory / 'manifest.json'
    if sha(path.read_bytes()) != args.manifest_sha:
        raise ValueError('approved manifest changed')
    manifest = json.loads(path.read_text())
    if manifest['commit'] != commit or manifest['version'] != args.version:
        raise ValueError('manifest source mismatch')
    verify_local(args.directory, manifest)
    states = verify_all(manifest)
    upload_status(args.version, states, args.directory.parent)
    if publication_decision(states) == 'hard-stop':
        raise ValueError('registry content mismatch, partial or unverifiable; no uploads')
    if states['react-native'] != 'verified':
        require_npm_oidc(args.version)
    journal = args.directory.parent / 'publication-attempts.json'
    assets = release(args.version)['assets']
    if any(a['name'] == journal.name for a in assets):
        run('gh', 'release', 'download', args.version, '--repo', REPO, '--pattern', journal.name, '--dir', str(journal.parent))
    attempts = json.loads(journal.read_text()) if journal.exists() else {}

    def persist(name, value):
        attempts[name] = value
        journal.write_text(json.dumps(attempts, indent=2) + '\n')
        run('gh', 'release', 'upload', args.version, str(journal), '--repo', REPO, '--clobber')

    try:
        # Establish actual npm OIDC authorization before uploading other packages.
        for name in ('react-native', 'ios', 'android', 'flutter'):
            states = verify_all(manifest)
            if publication_decision(states) == 'hard-stop':
                raise ValueError('registry state changed; publication stopped')
            if states[name] == 'verified':
                continue
            if name in attempts:
                raise ValueError(f'{name}: prior upload outcome unresolved; inspect registry/deployment before retry')
            verify_local(args.directory, manifest)
            persist(name, {'state': 'upload-started'})
            if name == 'ios':
                subprocess.run(['pod', 'trunk', 'push', str(args.directory / 'OnloSDK.podspec.json'), '--allow-warnings'], check=True)
            elif name == 'android':
                publish_maven(args.directory, args.version, lambda deployment: persist(name, {'state': 'uploaded', 'deploymentId': deployment}))
            elif name == 'flutter':
                publish_flutter(args.directory)
            else:
                subprocess.run(['npm', 'publish', str(args.directory / 'react-native.tgz'), '--access', 'public', '--provenance', '--registry', 'https://registry.npmjs.org/'], check=True)
            # Bounded visibility polling; no upload retry. Mismatch stops immediately.
            for _ in range(120):
                states = verify_all(manifest)
                upload_status(args.version, states, args.directory.parent)
                if states[name] == 'verified':
                    break
                if states[name] == 'mismatch':
                    raise ValueError(name + ': published artifact mismatch')
                time.sleep(15)
            else:
                raise TimeoutError(name + ': published content could not be verified')
            persist(name, {'state': 'verified'})
    finally:
        upload_status(args.version, verify_all(manifest), args.directory.parent)
    # Finalization is a separate step which downloads all registry artifacts again.


if __name__ == '__main__':
    main()
