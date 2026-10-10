import unittest
from release_control import validate_candidate

class AuthorityTests(unittest.TestCase):
    def test_non_main_candidate_rejected(self):
        with self.assertRaises(ValueError):
            validate_candidate('0.3.4', 'a'*40, 'a'*40, False, True, True)
    def test_tag_sha_mismatch_rejected(self):
        with self.assertRaises(ValueError):
            validate_candidate('0.3.4', 'a'*40, 'b'*40, True, True, True)
    def test_unprotected_main_rejected(self):
        with self.assertRaises(ValueError):
            validate_candidate('0.3.4', 'a'*40, 'a'*40, True, False, True)
    def test_exact_ci_failure_rejected(self):
        with self.assertRaises(ValueError):
            validate_candidate('0.3.4', 'a'*40, 'a'*40, True, True, False)
    def test_eligible_main_candidate(self):
        validate_candidate('0.3.4', 'a'*40, 'a'*40, True, True, True)


class FinalizeTests(unittest.TestCase):
    def test_release_public_only_with_four_verified_artifacts(self):
        import json
        import sys
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        import release_control as control
        for failing in (None, 'mismatch', 'missing', 'unverifiable', 'partial'):
            with self.subTest(failing=failing), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                manifest = {'version': '0.3.4', 'commit': 'a'*40, 'files': {}}
                (root / 'manifest.json').write_text(json.dumps(manifest))
                states = {name: 'verified' for name in ('ios', 'android', 'flutter', 'react-native')}
                if failing:
                    states['flutter'] = failing
                with patch.object(sys, 'argv', ['release_control.py', 'finalize', '0.3.4', '--directory', str(root)]), patch.object(control, 'authority', return_value='a'*40), patch.object(control, 'verify_all', return_value=states), patch.object(control, 'release', return_value={'isDraft': True}), patch.object(control, 'upload_status') as status, patch.object(control, 'run') as command:
                    if failing:
                        with self.assertRaises(ValueError): control.main()
                        command.assert_not_called()
                    else:
                        control.main()
                        self.assertIn('--draft=false', command.call_args.args)
                    status.assert_called_once()
