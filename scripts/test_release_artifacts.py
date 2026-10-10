import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from release_artifacts import *


def archive(files, stamp=0):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode='w:gz') as tar:
        for name, data in files:
            item = tarfile.TarInfo(name)
            item.size = len(data)
            item.mtime = stamp
            tar.addfile(item, io.BytesIO(data))
    return result.getvalue()


class ArtifactTests(unittest.TestCase):
    def test_same_version_different_package_is_hard_stop(self):
        expected = [{'url': 'artifact', 'mode': 'bytes', 'sha256': sha(b'approved')}]
        self.assertEqual(verify_sdk('android', expected, '0.3.4', lambda _: b'old'), 'mismatch')

    def test_matching_package_is_safe_skip(self):
        expected = [{'url': 'artifact', 'mode': 'bytes', 'sha256': sha(b'approved')}]
        self.assertEqual(verify_sdk('android', expected, '0.3.4', lambda _: b'approved'), 'verified')

    def test_canonical_archive_ignores_transport_metadata_not_content(self):
        one = archive([('a', b'a'), ('b', b'b')])
        two = archive([('root/b', b'b'), ('root/a', b'a')], 123)
        self.assertEqual(archive_content(one), archive_content(two, True))
        self.assertNotEqual(archive_content(one), archive_content(archive([('a', b'changed'), ('b', b'b')])))

    def test_archive_traversal_and_duplicate_rejected(self):
        for files in [[('../a', b'a')], [('a', b'1'), ('a', b'2')]]:
            with self.assertRaises(ValueError):
                archive_content(archive(files))

    def test_registry_timeout_is_unverifiable_not_missing(self):
        def fail(_):
            raise TimeoutError()
        manifest = {'schema': 1, 'version': '0.3.4', 'sdks': {k: [{'url': 'artifact', 'mode': 'bytes', 'sha256': sha(b'a')}] for k in SDK_NAMES}}
        states = verify_all(manifest, fail)
        self.assertEqual(set(states.values()), {'unverifiable'})
        self.assertEqual(publication_decision(states), 'hard-stop')

    def test_one_registry_failure_never_finalizes(self):
        for failure in ('missing', 'partial', 'mismatch', 'unverifiable'):
            states = {k: 'verified' for k in SDK_NAMES}
            states['flutter'] = failure
            self.assertNotEqual(publication_decision(states), 'finalize')

    def test_rerun_only_publishes_missing_and_never_overwrites(self):
        states = {k: 'verified' for k in SDK_NAMES}
        states['react-native'] = 'missing'
        self.assertEqual(publication_decision(states), 'publish-missing')
        states['react-native'] = 'verified'
        self.assertEqual(publication_decision(states), 'finalize')
        states['react-native'] = 'mismatch'
        self.assertEqual(publication_decision(states), 'hard-stop')

    def test_incomplete_results_cannot_finalize(self):
        with self.assertRaises(ValueError):
            publication_decision({'ios': 'verified'})

    def test_npm_fetches_actual_package_not_version_metadata(self):
        content = b'package bytes'
        responses = {'metadata': json.dumps({'version': '0.3.4', 'dist': {'tarball': 'download'}}).encode(), 'download': content}
        expected = [{'url': 'metadata', 'download_key': 'dist.tarball', 'mode': 'bytes', 'sha256': sha(content)}]
        self.assertEqual(verify_sdk('react-native', expected, '0.3.4', responses.get), 'verified')
        responses['download'] = b'wrong'
        self.assertEqual(verify_sdk('react-native', expected, '0.3.4', responses.get), 'mismatch')

    def test_partial_maven_upload_not_republished(self):
        expected = [{'url': k, 'mode': 'bytes', 'sha256': sha(b'a')} for k in ['pom', 'aar']]
        self.assertEqual(verify_sdk('android', expected, '0.3.4', {'pom': b'a'}.get), 'partial')

    def test_ios_existing_approved_tag_without_pod_is_publishable(self):
        expected = [{'url': k, 'mode': 'bytes', 'sha256': sha(b'a')} for k in ['pod', 'source']]
        self.assertEqual(verify_sdk('ios', expected, '0.3.4', {'source': b'a'}.get), 'missing')
        self.assertEqual(verify_sdk('ios', expected, '0.3.4', {'source': b'wrong'}.get), 'mismatch')

    def test_prepared_bytes_cannot_change_after_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'package').write_bytes(b'old')
            with self.assertRaises(ValueError):
                verify_local(root, {'files': {'package': sha(b'approved')}})

    def test_unapproved_extra_file_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'injected-package').write_bytes(b'not approved')
            with self.assertRaises(ValueError):
                verify_local(root, {'files': {}})

    def test_registry_download_cannot_redirect_to_arbitrary_host(self):
        for url in ('http://pub.dev/archive', 'https://evil.example/archive', 'https://user@pub.dev/archive'):
            with self.assertRaises(ValueError):
                check_url(url)


if __name__ == '__main__':
    unittest.main()
