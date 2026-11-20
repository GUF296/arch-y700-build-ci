#!/usr/bin/env python3
"""Hostile profile/materialization tests; never install packages or access cameras."""
import copy
import importlib.util
import io
import json
import os
import pathlib
import shutil
import stat
import tarfile
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('camera_remediation_test', HERE / 'camera-remediation-profile.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)

class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = M.snapshot(M.PROFILE)
        cls.value, cls.provenance, cls.expected, cls.members, cls.public = M.validate(cls.data)

    def test_actual_profile_is_complete(self):
        self.assertEqual(set(self.members), M.REPLACEMENTS)
        self.assertEqual(len(self.expected), 56)
        self.assertIn(self.value['producer_source']['kind'], ('working-tree-snapshot', 'immutable-git-commit'))

    def test_materialized_tree_preserves_baseline(self):
        before, raw = M.overlay.parse_manifest(M.BASE / 'OVERLAY-MANIFEST.tsv')
        with tempfile.TemporaryDirectory(prefix='tb321fu-profile-test-') as directory:
            output = pathlib.Path(directory) / 'camera'
            M.materialize(output)
            M.verify_tree(output)
            actual, _ = M.overlay.inspect_tree(output)
            changed = {name for name in actual if actual[name] != before[name]}
            self.assertEqual(changed, M.REPLACEMENTS)
            self.assertEqual(M.overlay.inspect_tree(M.BASE / 'rootfs-overlay')[0], before)
            self.assertEqual((M.BASE / 'OVERLAY-MANIFEST.tsv').read_bytes(), raw)
            (output / 'opt/libcamera-y700/share/libcamera/ipa/simple/gc13a0.yaml').write_bytes(b'unapproved change')
            with self.assertRaises(RuntimeError):
                M.verify_tree(output)

    def test_existing_output_and_profile_child_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            marker = root / 'preserved'
            marker.write_text('keep me')
            with self.assertRaises(RuntimeError):
                M.materialize(root)
            self.assertEqual(marker.read_text(), 'keep me')
            profile = root / 'profile'
            shutil.copytree(M.PROFILE, profile)
            with self.assertRaises(RuntimeError):
                M.materialize(profile / 'output', profile)
            self.assertFalse((profile / 'output').exists())

    def test_profile_member_set_and_aliases_are_rejected(self):
        for change in ('extra', 'symlink', 'hardlink', 'writable'):
            with tempfile.TemporaryDirectory() as directory:
                profile = pathlib.Path(directory) / 'profile'
                shutil.copytree(M.PROFILE, profile)
                if change == 'extra':
                    (profile / 'private.pem').write_text('not an allowed member')
                elif change == 'writable':
                    (profile / 'PROFILE.json').chmod(0o666)
                else:
                    selected = profile / 'BUILD-REPORT.txt'
                    selected.unlink()
                    if change == 'symlink':
                        selected.symlink_to(M.PROFILE / 'BUILD-REPORT.txt')
                    else:
                        outside = pathlib.Path(directory) / 'report'
                        shutil.copyfile(M.PROFILE / 'BUILD-REPORT.txt', outside)
                        os.link(outside, selected)
                with self.subTest(change=change), self.assertRaises((RuntimeError, OSError)):
                    M.snapshot(profile)

    def test_metadata_and_hash_mutations_fail(self):
        changes = (lambda x: x.update(epoch=True),
                   lambda x: x.update(archive_sha256='0'*64),
                   lambda x: x.update(baseline_manifest_sha256='0'*64),
                   lambda x: x['replacements'].pop(M.overlay.PLUGIN_PATH),
                   lambda x: x['replacements'][M.overlay.PLUGIN_PATH].update(mode='0755'),
                   lambda x: x['producer_source'].update(inputs_sha256='0'*64),
                   lambda x: x.update(package_version='0+wrong'))
        for mutate in changes:
            data, value = dict(self.data), copy.deepcopy(self.value)
            mutate(value)
            data['PROFILE.json'] = json.dumps(value).encode()
            with self.subTest(mutation=mutate), self.assertRaises(RuntimeError):
                M.validate(data)

    def rewritten_archive(self, label):
        content = io.BytesIO()
        values = copy.deepcopy(self.value)
        with tarfile.open(fileobj=content, mode='w:xz', format=tarfile.PAX_FORMAT) as archive:
            names = sorted(self.members)
            for name in names:
                item = tarfile.TarInfo(name)
                item.mode = int(values['replacements'][name]['mode'], 8)
                item.mtime = values['epoch']
                data = self.members[name]
                if name == M.overlay.PLUGIN_PATH and label == 'rehashed':
                    data = data[:-1] + bytes([data[-1] ^ 1])
                    values['replacements'][name]['sha256'] = M.sha(data)
                item.size = len(data)
                if name == names[0] and label == 'symlink':
                    item.type, item.linkname, item.size = tarfile.SYMTYPE, '/tmp/not-owned', 0
                    archive.addfile(item)
                else:
                    archive.addfile(item, io.BytesIO(data))
                if name == names[0] and label == 'duplicate':
                    archive.addfile(item, io.BytesIO(data))
            if label == 'extra':
                item = tarfile.TarInfo('etc/unapproved')
                item.size, item.mode, item.mtime = 1, 0o644, values['epoch']
                archive.addfile(item, io.BytesIO(b'x'))
        archive_bytes = content.getvalue()
        values['archive_sha256'], values['archive_bytes'] = M.sha(archive_bytes), len(archive_bytes)
        data = dict(self.data)
        data['PROFILE.json'] = json.dumps(values).encode()
        data['remediation-runtime.tar.xz'] = archive_bytes
        return data

    def test_rehashed_archive_attacks_fail(self):
        for label in ('extra', 'duplicate', 'symlink', 'rehashed'):
            with self.subTest(label=label), self.assertRaises(RuntimeError):
                M.validate(self.rewritten_archive(label))

    def test_fake_provenance_cannot_replace_original_report(self):
        data, provenance = dict(self.data), copy.deepcopy(self.provenance)
        provenance['public_key_sha256'] = '0'*64
        data['BUILD-PROVENANCE.json'] = json.dumps(provenance).encode()
        value = copy.deepcopy(self.value)
        value['producer_provenance_sha256'] = M.sha(data['BUILD-PROVENANCE.json'])
        data['PROFILE.json'] = json.dumps(value).encode()
        with self.assertRaises(RuntimeError):
            M.validate(data)

    def test_no_clobber_publication_race(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            staging, existing = root / 'stage', root / 'existing'
            staging.mkdir()
            existing.mkdir()
            (existing / 'marker').write_text('untouched')
            with self.assertRaises(OSError):
                M.promote(staging, existing)
            self.assertEqual((existing / 'marker').read_text(), 'untouched')
            self.assertTrue(staging.is_dir())

if __name__ == '__main__':
    unittest.main()
