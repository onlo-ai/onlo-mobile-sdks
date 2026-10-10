import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import release_publish as publish


class PublicationTests(unittest.TestCase):
    def test_approved_manifest_swap_blocks_before_any_upload(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'manifest.json').write_text('{}')
            with patch.object(sys, 'argv', ['release_publish.py', '0.3.4', str(root), '--manifest-sha', 'a'*64]), patch.object(publish, 'authority', return_value='a'*40), patch.object(publish, 'release', return_value={'isDraft': True}), patch.object(publish.subprocess, 'run') as command:
                with self.assertRaisesRegex(ValueError, 'manifest changed'):
                    publish.main()
                command.assert_not_called()


class OIDCTests(unittest.TestCase):
    def environment(self):
        return {
            'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
            'GITHUB_WORKFLOW_REF': f'{publish.REPO}/.github/workflows/publish.yml@refs/tags/0.3.4',
            'ACTIONS_ID_TOKEN_REQUEST_URL': 'https://example.invalid',
            'ACTIONS_ID_TOKEN_REQUEST_TOKEN': 'synthetic-test-only',
        }

    def test_hosted_oidc_prerequisites_do_not_claim_registry_authorization(self):
        with patch.dict(os.environ, self.environment(), clear=True), patch.object(publish, 'run', side_effect=['v24.15.0', '12.2.0']):
            publish.require_npm_oidc('0.3.4')

    def test_missing_oidc_wrong_workflow_or_self_hosted_fails_closed(self):
        for key, value in [('ACTIONS_ID_TOKEN_REQUEST_TOKEN', ''), ('ACTIONS_ID_TOKEN_REQUEST_URL', ''), ('GITHUB_WORKFLOW_REF', 'other/repo/.github/workflows/publish.yml@refs/tags/0.3.4'), ('RUNNER_ENVIRONMENT', 'self-hosted')]:
            with self.subTest(key=key), patch.dict(os.environ, {**self.environment(), key: value}, clear=True):
                with self.assertRaisesRegex(ValueError, 'approved GitHub-hosted'):
                    publish.require_npm_oidc('0.3.4')

    def test_static_token_cannot_fallback(self):
        for key in ('NODE_AUTH_TOKEN', 'NPM_TOKEN', 'NPM_CONFIG__AUTH', 'NPM_CONFIG__AUTHTOKEN'):
            with self.subTest(key=key), patch.dict(os.environ, {**self.environment(), key: 'synthetic'}, clear=True):
                with self.assertRaisesRegex(ValueError, 'long-lived'):
                    publish.require_npm_oidc('0.3.4')

    def test_unsupported_toolchain_fails_closed(self):
        for versions in [('v22.0.0', '12.2.0'), ('v24.15.0', '10.0.0')]:
            with self.subTest(versions=versions), patch.dict(os.environ, self.environment(), clear=True), patch.object(publish, 'run', side_effect=versions):
                with self.assertRaisesRegex(ValueError, 'pinned npm'):
                    publish.require_npm_oidc('0.3.4')

    def test_npm_auth_failure_prevents_other_sdk_uploads(self):
        import json
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'prepared'
            root.mkdir()
            manifest = {'commit': 'a'*40, 'version': '0.3.4'}
            data = json.dumps(manifest).encode()
            (root / 'manifest.json').write_bytes(data)
            states = dict.fromkeys(('ios', 'android', 'flutter', 'react-native'), 'missing')
            with patch.object(sys, 'argv', ['release_publish.py', '0.3.4', str(root), '--manifest-sha', publish.sha(data)]), patch.object(publish, 'authority', return_value='a'*40), patch.object(publish, 'release', return_value={'isDraft': True, 'assets': []}), patch.object(publish, 'verify_local'), patch.object(publish, 'verify_all', return_value=states), patch.object(publish, 'upload_status') as status, patch.object(publish, 'require_npm_oidc'), patch.object(publish, 'run'), patch.object(publish, 'publish_maven') as maven, patch.object(publish.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'npm')) as command:
                with self.assertRaises(subprocess.CalledProcessError):
                    publish.main()
                self.assertEqual(command.call_count, 1)
                self.assertEqual(command.call_args.args[0][:2], ['npm', 'publish'])
                self.assertIn(str(root / 'react-native.tgz'), command.call_args.args[0])
                maven.assert_not_called()
                self.assertEqual(set(json.loads((root.parent / 'publication-attempts.json').read_text())), {'react-native'})
                self.assertEqual(status.call_count, 2)


class FlutterOIDCTests(unittest.TestCase):
    def test_refreshes_stale_setup_token_at_upload_time(self):
        import io
        from urllib.parse import parse_qs, urlsplit
        with patch.dict(os.environ, {'ACTIONS_ID_TOKEN_REQUEST_URL': 'https://example.invalid/token?api-version=2', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN': 'synthetic-request', 'PUB_TOKEN': 'synthetic-expired'}, clear=True), patch.object(publish.urllib.request, 'urlopen', return_value=io.StringIO('{"value":"synthetic-fresh"}')) as request, patch.object(publish.subprocess, 'run') as command:
            publish.publish_flutter(Path('/approved'))
            url = request.call_args.args[0].full_url
            self.assertEqual(parse_qs(urlsplit(url).query), {'api-version':['2'], 'audience':['https://pub.dev']})
            self.assertEqual(command.call_args.kwargs['env']['PUB_TOKEN'], 'synthetic-fresh')
            self.assertEqual(os.environ['PUB_TOKEN'], 'synthetic-expired')
            self.assertEqual(command.call_args.args[0], ['dart', 'pub', 'publish', '--force', '--from-archive=/approved/flutter.tar.gz'])

    def test_token_exchange_failure_never_attempts_upload(self):
        import io
        for body in ('{}', '{"value":null}'):
            with self.subTest(body=body), patch.dict(os.environ, {'ACTIONS_ID_TOKEN_REQUEST_URL': 'https://example.invalid/token', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN': 'synthetic-request'}, clear=True), patch.object(publish.urllib.request, 'urlopen', return_value=io.StringIO(body)), patch.object(publish.subprocess, 'run') as command:
                with self.assertRaisesRegex(ValueError, 'missing token'):
                    publish.publish_flutter(Path('/approved'))
                command.assert_not_called()

    def test_missing_oidc_never_uses_stale_token(self):
        with patch.dict(os.environ, {'PUB_TOKEN':'synthetic-expired'}, clear=True), patch.object(publish.subprocess, 'run') as command:
            with self.assertRaisesRegex(ValueError, 'requires GitHub OIDC'):
                publish.publish_flutter(Path('/approved'))
            command.assert_not_called()
