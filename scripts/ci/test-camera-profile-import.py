#!/usr/bin/env python3
"""Operator-import boundary tests with small, real tar and process fixtures."""
import importlib.util
import io
import os
import pathlib
import subprocess
import stat
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('camera_import_test', HERE / 'import-camera-remediation-profile.py')
I = importlib.util.module_from_spec(spec)
spec.loader.exec_module(I)
M = I.contract

class ImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.baseline, _ = M.overlay.parse_manifest(M.BASE / 'OVERLAY-MANIFEST.tsv')
        cls.value, _, cls.expected, cls.members, _ = M.validate(M.snapshot(M.PROFILE))

    def package_tar(self, path, attack=None):
        with tarfile.open(path, mode='w', format=tarfile.PAX_FORMAT) as archive:
            for name, row in sorted(self.baseline.items()):
                item = tarfile.TarInfo('./' + name)
                item.mode = row[1]
                if row[0] == 'directory':
                    item.type = tarfile.DIRTYPE
                    archive.addfile(item)
                elif row[0] == 'symlink':
                    item.type = tarfile.SYMTYPE
                    item.linkname = '/tmp/not-owned' if attack == 'link' else row[4]
                    archive.addfile(item)
                else:
                    content = self.members.get(name)
                    if content is None:
                        content = (M.BASE / 'rootfs-overlay' / name).read_bytes()
                    item.size = len(content)
                    if attack == 'data' and name.endswith('gc13a0.yaml'):
                        content = b'X' * len(content)
                    if attack == 'hardlink' and name == M.overlay.PLUGIN_PATH:
                        item.type, item.linkname, item.size = tarfile.LNKTYPE, '/tmp/not-owned', 0
                        archive.addfile(item)
                    else:
                        archive.addfile(item, io.BytesIO(content))
                    if attack == 'duplicate' and name == M.overlay.PLUGIN_PATH:
                        archive.addfile(item, io.BytesIO(content))
            if attack == 'extra':
                item = tarfile.TarInfo('../../outside')
                item.mode, item.size = 0o644, 1
                archive.addfile(item, io.BytesIO(b'x'))

    def test_complete_payload_with_approved_absolute_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive, payload = root / 'package.tar', root / 'payload'
            self.package_tar(archive)
            I.materialize_deb_payload(archive, payload, self.baseline)
            self.assertEqual(M.overlay.inspect_tree(payload)[0], self.expected)
            M.verify_tree(payload)

    def test_package_attacks_fail_before_any_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for attack in ('link', 'data', 'hardlink', 'duplicate', 'extra'):
                archive, payload = root / (attack + '.tar'), root / (attack + '-payload')
                self.package_tar(archive, attack)
                with self.subTest(attack=attack), self.assertRaises(RuntimeError):
                    I.materialize_deb_payload(archive, payload, self.baseline)
                self.assertFalse(payload.exists())

    def test_repeated_report_fields_fail(self):
        self.assertEqual(I.field('version=1\n', 'version'), '1')
        for report in ('', 'version=1\nversion=2\n'):
            with self.assertRaises(RuntimeError):
                I.field(report, 'version')

    def test_private_umask_preserves_explicit_profile_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            saved = os.umask(0o077)
            try:
                profile = parent / 'profile'
                I.create_profile_stage(profile)
            finally:
                os.umask(saved)
            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(profile.stat().st_mode), 0o755)

    def run_fake_decompressor(self, code, output):
        original = subprocess.Popen
        def popen(_command, **kwargs):
            return original([sys.executable, '-I', '-B', '-c', code], **kwargs)
        with patch.object(I.subprocess, 'Popen', side_effect=popen):
            I.emit_payload_tar(pathlib.Path('/unused-fixture.deb'), output)

    def test_decompression_byte_budget(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(I, 'MAX_PAYLOAD_TAR_BYTES', 4096):
            output = pathlib.Path(directory) / 'payload.tar'
            with self.assertRaisesRegex(RuntimeError, 'budget'):
                self.run_fake_decompressor('import sys; sys.stdout.buffer.write(b"x"*8192)', output)
            self.assertLessEqual(output.stat().st_size, 4096)

    def test_decompression_timeout_reaps_owned_process(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(I, 'PAYLOAD_TIMEOUT', 0.1):
            before = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                self.run_fake_decompressor('import time; time.sleep(30)', pathlib.Path(directory) / 'payload.tar')
            self.assertLess(time.monotonic() - before, 10)

if __name__ == '__main__':
    unittest.main()
