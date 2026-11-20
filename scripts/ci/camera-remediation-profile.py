#!/usr/bin/env python3
"""Materialize repository-approved source-built camera replacements over baseline.

This authenticates pinned bytes and recorded provenance. It is not independent
proof that a compiler ran, an immutable upstream publication, or hardware approval.
"""
from __future__ import annotations
import argparse
import base64
import ctypes
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent.parent / 'source/tb321fu-camera-rootfs-overlay'
PROFILE = BASE / 'remediation-profile'
spec = importlib.util.spec_from_file_location('arch_camera_overlay', BASE / 'tools/verify-camera-overlay.py')
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)
LIB = 'opt/libcamera-y700/lib/aarch64-linux-gnu/'
REPLACEMENTS = frozenset({'opt/libcamera-y700/bin/cam', LIB + 'libcamera.so.0.7.1',
    LIB + 'libcamera-base.so.0.7.1', LIB + 'libcamera/ipa/ipa_soft_simple.so',
    LIB + 'libcamera/ipa/ipa_soft_simple.so.sign', 'opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy',
    LIB + 'gstreamer-1.0/libgstlibcamera.so', overlay.PLUGIN_PATH})
FILES = {'PROFILE.json': 64 << 10, 'BUILD-PROVENANCE.json': 64 << 10,
         'BUILD-REPORT.txt': 4 << 20, 'remediation-runtime.tar.xz': 16 << 20}

def fail(message):
    raise RuntimeError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def digest(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail('duplicate remediation JSON field')
        result[key] = value
    return result

def snapshot(profile):
    profile = pathlib.Path(os.path.abspath(profile))
    if profile.resolve(strict=True) != profile:
        fail('profile path traverses a symlink')
    directory = os.open(profile, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before_root = os.fstat(directory)
        if stat.S_IMODE(before_root.st_mode) != 0o755:
            fail('remediation profile directory mode must be 0755')
        if set(os.listdir(directory)) != set(FILES):
            fail('remediation profile is not the closed four-file set')
        result, identities = {}, {}
        for name, limit in FILES.items():
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
            with os.fdopen(fd, 'rb') as stream:
                before = os.fstat(stream.fileno())
                if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                        or stat.S_IMODE(before.st_mode) != 0o644 or not 0 < before.st_size <= limit):
                    fail('unsafe remediation profile member: ' + name)
                data = stream.read(limit + 1)
                if len(data) != before.st_size or overlay.stat_identity(os.fstat(stream.fileno())) != overlay.stat_identity(before):
                    fail('remediation profile changed while reading')
                result[name], identities[name] = data, overlay.stat_identity(before)
        for name, identity in identities.items():
            if overlay.stat_identity(os.stat(name, dir_fd=directory, follow_symlinks=False)) != identity:
                fail('remediation profile member identity changed')
        after_root = profile.lstat()
        if (set(os.listdir(directory)) != set(FILES)
                or (after_root.st_dev, after_root.st_ino) != (before_root.st_dev, before_root.st_ino)):
            fail('remediation profile namespace changed')
        return result
    finally:
        os.close(directory)

def validate(data):
    value = json.loads(data['PROFILE.json'].decode(), object_pairs_hook=unique_object)
    fields = {'schema', 'baseline_manifest_sha256', 'archive_sha256', 'archive_bytes',
              'epoch', 'producer_provenance_sha256', 'producer_report_sha256',
              'package_sha256', 'package_version', 'producer_source', 'replacements'}
    if not isinstance(value, dict) or set(value) != fields or value['schema'] != 'tb321fu-camera-remediation-profile-v1':
        fail('unsupported remediation profile schema')
    expected, raw_manifest = overlay.parse_manifest(BASE / 'OVERLAY-MANIFEST.tsv')
    if value['baseline_manifest_sha256'] != sha(raw_manifest):
        fail('remediation profile does not bind the historical baseline')
    for field in ('archive_sha256', 'producer_provenance_sha256', 'producer_report_sha256', 'package_sha256'):
        if not digest(value[field]):
            fail('invalid remediation profile digest')
    if (type(value['epoch']) is not int or not 0 <= value['epoch'] <= 0x7FFFFFFF
            or type(value['archive_bytes']) is not int
            or value['archive_bytes'] != len(data['remediation-runtime.tar.xz'])
            or sha(data['remediation-runtime.tar.xz']) != value['archive_sha256']
            or sha(data['BUILD-PROVENANCE.json']) != value['producer_provenance_sha256']
            or sha(data['BUILD-REPORT.txt']) != value['producer_report_sha256']):
        fail('remediation artifact identity mismatch')
    if (not isinstance(value['package_version'], str)
            or re.fullmatch('[0-9][0-9A-Za-z.+:~-]{0,63}', value['package_version']) is None):
        fail('invalid remediation package version')
    source = value['producer_source']
    source_fields = {'kind', 'git_head', 'inputs_sha256', 'package_builder_sha256',
                     'spa_source_sha256', 'spa_producer_manifest_sha256', 'spa_toolchain_sha256'}
    if (not isinstance(source, dict) or set(source) != source_fields
            or source['kind'] not in ('working-tree-snapshot', 'immutable-git-commit')
            or not isinstance(source['git_head'], str) or re.fullmatch('[0-9a-f]{40}', source['git_head']) is None
            or any(not digest(source[key]) for key in source_fields - {'kind', 'git_head'})):
        fail('invalid source producer identity')
    source_path = BASE / 'source/libcamera-source.cpp.clean-minimal-daily'
    descriptor = os.open(source_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 < before.st_size <= 2 << 20:
            fail('invalid repository SPA source input')
        source_bytes = stream.read((2 << 20) + 1)
        if (len(source_bytes) != before.st_size
                or overlay.stat_identity(os.fstat(stream.fileno())) != overlay.stat_identity(before)
                or overlay.stat_identity(source_path.lstat()) != overlay.stat_identity(before)
                or sha(source_bytes) != source['spa_source_sha256']):
            fail('repository SPA source differs from the delivered source-built profile')
    provenance = json.loads(data['BUILD-PROVENANCE.json'].decode(), object_pairs_hook=unique_object)
    fields = {'schema', 'source', 'inputs', 'options', 'runtime_manifest_sha256',
              'replica_manifests', 'public_key_der_base64', 'public_key_sha256'}
    if (not isinstance(provenance, dict) or set(provenance) != fields
            or provenance['schema'] != 'tb321fu-libcamera-runtime-v1'
            or not isinstance(provenance['options'], list)
            or '-Dipa-force-isolation=true' not in provenance['options']
            or not isinstance(provenance['source'], dict)
            or provenance['source'].get('epoch') != value['epoch']
            or sha(json.dumps(provenance['inputs'], sort_keys=True, separators=(',', ':')).encode()) != source['inputs_sha256']):
        fail('remediation source/provenance binding mismatch')
    if (not digest(provenance['runtime_manifest_sha256'])
            or provenance['replica_manifests'] != [provenance['runtime_manifest_sha256']] * 2):
        fail('remediation provenance omits paired runtime identity')
    inputs = provenance['inputs']
    if (not isinstance(inputs, dict) or not 8 <= len(inputs) <= 32
            or any(not isinstance(name, str) or re.fullmatch('[A-Za-z0-9_.-]+', name) is None
                   or not digest(value) for name, value in inputs.items())
            or 'adapt-libcamera-build.py' not in inputs
            or 'build-tb321fu-libcamera-runtime.py' not in inputs):
        fail('invalid source producer input identities')
    report = data['BUILD-REPORT.txt'].decode('utf-8')
    for field, expected_value in (('version', value['package_version']), ('arch', 'arm64'),
            ('camera_source_sha256', source['spa_source_sha256']),
            ('camera_producer_manifest_sha256', source['spa_producer_manifest_sha256']),
            ('camera_toolchain_sha256', source['spa_toolchain_sha256'])):
        actual = re.findall('^' + field + '=(.*)$', report, flags=re.M)
        if actual != [expected_value]:
            fail('producer report does not bind the approved package/source: ' + field)
    package_checksum = value['package_sha256'] + '  tb321fu-camera-stack_' + value['package_version'] + '_arm64.deb'
    if report.splitlines().count(package_checksum) != 1:
        fail('producer report package checksum mismatch')
    encoded = provenance['public_key_der_base64']
    if not isinstance(encoded, str) or not 200 <= len(encoded) <= 1024:
        fail('invalid remediation public key framing')
    public_key = base64.b64decode(encoded, validate=True)
    if sha(public_key) != provenance['public_key_sha256']:
        fail('remediation public key digest mismatch')
    replacements = value['replacements']
    if not isinstance(replacements, dict) or replacements.keys() != REPLACEMENTS:
        fail('remediation profile must replace exactly the eight approved files')
    total = 0
    for name, record in replacements.items():
        if (not isinstance(record, dict) or set(record) != {'mode', 'size', 'sha256'}
                or record['mode'] != f'0{expected[name][1]:o}'
                or type(record['size']) is not int or not 0 < record['size'] <= overlay.MAX_FILE_SIZE
                or not digest(record['sha256'])):
            fail('invalid remediation replacement metadata: ' + name)
        expected[name] = ('file', int(record['mode'], 8), record['size'], record['sha256'], '-')
        total += record['size']
    if total > overlay.MAX_TOTAL_SIZE:
        fail('remediation replacement set exceeds its size bound')
    marker = '== complete runtime build provenance (public inputs only) ==\n'
    if report.count(marker) != 1:
        fail('producer report lacks unique runtime provenance')
    reported, _ = json.JSONDecoder(object_pairs_hook=unique_object).raw_decode(report.split(marker)[1])
    if reported != provenance:
        fail('profile provenance differs from the producer report')
    marker = '== complete build runtime manifest (includes build-only headers) ==\n'
    if report.count(marker) != 1:
        fail('producer report lacks unique runtime member identity')
    lines = report.split(marker)[1].splitlines()
    if not lines or lines[0] != 'path\ttype\tmode\tsize\tsha256\tlink_target':
        fail('reported runtime manifest header mismatch')
    selected, records = [lines[0]], {}
    for line in lines[1:]:
        fields = line.split('\t')
        if len(fields) != 6:
            break
        name, kind, mode, size, content_hash, target = fields
        overlay.validate_relative_path(name)
        if name in records or len(records) >= 256 or re.fullmatch('0[0-7]{3}', mode) is None or re.fullmatch('[0-9]{1,10}', size) is None:
            fail('invalid reported runtime member framing')
        records[name] = (kind, int(mode, 8), int(size), content_hash, target)
        selected.append(line)
    if sha(('\n'.join(selected) + '\n').encode()) != provenance['runtime_manifest_sha256']:
        fail('reported runtime manifest checksum mismatch')
    for name in REPLACEMENTS - {overlay.PLUGIN_PATH}:
        row = records.get(name)
        mode = 0o644 if name.endswith('.sign') else 0o755
        if row != ('file', mode, expected[name][2], expected[name][3], '-'):
            fail('replacement is not from the reported coherent runtime: ' + name)
    if re.findall('^camera_plugin_sha256=(.*)$', report, flags=re.M) != [expected[overlay.PLUGIN_PATH][3]]:
        fail('replacement SPA is not from the reported paired build')
    members = {}
    with tarfile.open(fileobj=io.BytesIO(data['remediation-runtime.tar.xz']), mode='r:xz') as archive:
        for member in archive:
            name = member.name
            if (name not in REPLACEMENTS or name in members or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE)
                    or member.uid != 0 or member.gid != 0 or member.uname or member.gname
                    or member.mtime != value['epoch'] or member.mode != expected[name][1]
                    or member.size != expected[name][2] or member.sparse is not None
                    or set(member.pax_headers) - {'path'}):
                fail('unexpected remediation archive member or metadata')
            stream = archive.extractfile(member)
            content = stream.read(overlay.MAX_FILE_SIZE + 1)
            if len(content) != expected[name][2] or sha(content) != expected[name][3]:
                fail('remediation archive member content mismatch')
            members[name] = content
    if members.keys() != REPLACEMENTS:
        fail('remediation archive is missing an approved replacement')
    return value, provenance, expected, members, public_key

def verify_signature(root, public_key):
    with tempfile.TemporaryDirectory(prefix='tb321fu-arch-camera-key-') as directory:
        key = pathlib.Path(directory) / 'public.der'
        key.write_bytes(public_key)
        result = subprocess.run(['/usr/bin/openssl', 'dgst', '-sha256', '-keyform', 'DER',
            '-verify', str(key), '-signature', str(root / (LIB + 'libcamera/ipa/ipa_soft_simple.so.sign')),
            str(root / (LIB + 'libcamera/ipa/ipa_soft_simple.so'))],
            env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=30, check=False)
        if result.returncode or result.stdout.strip() != b'Verified OK':
            fail('remediated IPA signature does not match its approved public key')

def verify_tree(root, profile=PROFILE):
    data = snapshot(profile)
    value, provenance, expected, members, public_key = validate(data)
    root = overlay.validate_root(root)
    if overlay.inspect_tree(root)[0] != expected:
        fail('remediated camera tree differs from its closed baseline/replacement contract')
    verify_signature(root, public_key)
    if overlay.inspect_tree(root)[0] != expected or snapshot(profile) != data:
        fail('camera profile or materialized tree changed during validation')
    return dict(value, verified_profile_sha256=sha(data['PROFILE.json']))

def promote(staging, output):
    library = ctypes.CDLL(None, use_errno=True)
    rename = getattr(library, 'renameat2', None)
    if rename is None:
        fail('atomic camera materialization requires renameat2')
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(staging), -100, os.fsencode(output), 1) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))

def materialize(output, profile=PROFILE):
    output = output.absolute()
    output = output.parent.resolve(strict=True) / output.name
    if (output.exists() or output.is_symlink() or output.is_relative_to(BASE.resolve())
            or output.is_relative_to(pathlib.Path(profile).resolve(strict=True))):
        fail('camera output must be an unused path outside the source baseline/profile')
    data = snapshot(profile)
    value, provenance, expected, members, public_key = validate(data)
    baseline = BASE / 'rootfs-overlay'
    overlay.verify(baseline, BASE / 'OVERLAY-MANIFEST.tsv', None)
    with tempfile.TemporaryDirectory(prefix='.tb321fu-arch-camera-', dir=output.parent) as directory:
        stage = pathlib.Path(directory) / 'payload'
        shutil.copytree(baseline, stage, symlinks=True)
        overlay.verify(stage, BASE / 'OVERLAY-MANIFEST.tsv', None)
        for name, content in members.items():
            path = stage / name
            fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), expected[name][1])
        if overlay.inspect_tree(stage)[0] != expected:
            fail('materialized remediation payload differs from expected bytes')
        verify_signature(stage, public_key)
        overlay.verify(baseline, BASE / 'OVERLAY-MANIFEST.tsv', None)
        if snapshot(profile) != data:
            fail('remediation profile changed during materialization')
        promote(stage, output)
    return dict(value, verified_profile_sha256=sha(data['PROFILE.json']))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--output', type=pathlib.Path)
    actions.add_argument('--verify-tree', type=pathlib.Path)
    actions.add_argument('--verify-profile', action='store_true')
    arguments = parser.parse_args()
    if arguments.output is not None:
        value = materialize(arguments.output)
    elif arguments.verify_tree is not None:
        value = verify_tree(arguments.verify_tree)
    else:
        data = snapshot(PROFILE)
        value = dict(validate(data)[0], verified_profile_sha256=sha(data['PROFILE.json']))
    print('CAMERA_REMEDIATION_PROFILE=PASS replacements=8 source_kind=' + value['producer_source']['kind'])
    print('camera_profile_sha256=' + value['verified_profile_sha256'])
    print('camera_source_package_sha256=' + value['package_sha256'])
    print('camera_producer_source_kind=' + value['producer_source']['kind'])

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        raise SystemExit('CAMERA_REMEDIATION_PROFILE=FAIL: ' + str(error))
