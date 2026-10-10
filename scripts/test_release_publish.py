import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import release_publish as publish


class PublicationTests(unittest.TestCase):
    def test_unresolved_npm_failure_blocks_before_any_upload(self):
        with patch.object(sys, 'argv', ['release_publish.py', '0.3.4', '/unused', '--manifest-sha', 'a'*64]), patch.object(publish, 'authority', return_value='a'*40), patch.dict(os.environ, {'NPM_E404_RESOLVED': 'false'}), patch.object(publish, 'release') as remote, patch.object(publish.subprocess, 'run') as command:
            with self.assertRaisesRegex(ValueError, 'root cause'):
                publish.main()
            remote.assert_not_called()
            command.assert_not_called()

    def test_approved_manifest_swap_blocks_before_any_upload(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'manifest.json').write_text('{}')
            with patch.object(sys, 'argv', ['release_publish.py', '0.3.4', str(root), '--manifest-sha', 'a'*64]), patch.object(publish, 'authority', return_value='a'*40), patch.dict(os.environ, {'NPM_E404_RESOLVED': 'true'}), patch.object(publish, 'release', return_value={'isDraft': True}), patch.object(publish.subprocess, 'run') as command:
                with self.assertRaisesRegex(ValueError, 'manifest changed'):
                    publish.main()
                command.assert_not_called()
