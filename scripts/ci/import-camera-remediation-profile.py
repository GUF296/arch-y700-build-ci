#!/usr/bin/env python3
"""Import an operator-trusted producer run; never install its Debian package.

--producer-repo is a trusted executable source checkout, not downloaded data.
This checks source/output consistency; the operator must separately authenticate
the producer run. Self-reported hashes are not a substitute for CI attestation.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
MAX_PAYLOAD_TAR_BYTES = 64 << 20
PAYLOAD_TIMEOUT = 45

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

contract = load(HERE / 'camera-remediation-profile.py', 'arch_camera_profile_import')

def field(report, name):
    values = re.findall('^' + re.escape(name) + '=(.*)$', report, flags=re.M)
    if len(values) != 1:
        raise RuntimeError('producer report field missing or duplicated: ' + name)
    return values[0]

def create_profile_stage(path):
    path.mkdir(mode=0o755)
    # The containing TemporaryDirectory remains private 0700. This explicit
    # output mode must not depend on the invoking shell's restrictive umask.
    path.chmod(0o755)

def emit_payload_tar(package, destination):
    process = subprocess.Popen(['/usr/bin/dpkg-deb', '--fsys-tarfile', str(package)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        start_new_session=True, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
    reaped = False
    try:
        os.set_blocking(process.stdout.fileno(), False)
        with selectors.DefaultSelector() as ready, destination.open('xb') as output:
            ready.register(process.stdout, selectors.EVENT_READ)
            deadline, size = time.monotonic() + PAYLOAD_TIMEOUT, 0
            while True:
                if time.monotonic() > deadline:
                    raise RuntimeError('camera package decompression timed out')
                if not ready.select(0.25):
                    continue
                chunk = os.read(process.stdout.fileno(), 1 << 20)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_PAYLOAD_TAR_BYTES:
                    raise RuntimeError('camera package payload exceeds its decompression budget')
                output.write(chunk)
        status = process.wait(timeout=5)
        reaped = True
        if status != 0:
            raise RuntimeError('camera package decompression failed')
    finally:
        if not reaped:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        process.stdout.close()

def materialize_deb_payload(payload_tar, payload, baseline):
    # Never extract package-supplied links. The approved baseline already owns
    # the one absolute GStreamer link; validate that record as inert data.
    extractor = load(HERE / 'safe-extract-archive.py', 'camera_import_bounded_tar')
    actual, replacements, root_seen = {}, {}, False
    with tarfile.open(payload_tar, mode='r:', tarinfo=extractor.BoundedTarInfo) as archive:
        for member in archive:
            name = member.name
            if name in ('.', './'):
                if root_seen or not member.isdir() or member.mode != 0o755 or member.uid or member.gid:
                    raise RuntimeError('invalid package root entry')
                root_seen = True
                continue
            if name.startswith('./'):
                name = name[2:]
            if name not in baseline or name in actual or member.uid or member.gid or member.sparse is not None:
                raise RuntimeError('unknown duplicate or unsafe package member')
            expected = baseline[name]
            if member.mode != expected[1]:
                raise RuntimeError('package member mode changed: ' + name)
            if expected[0] == 'directory':
                if not member.isdir() or member.size:
                    raise RuntimeError('package directory type mismatch')
                actual[name] = ('directory', member.mode, 0, '-', '-')
            elif expected[0] == 'symlink':
                if not member.issym() or member.size or member.linkname != expected[4]:
                    raise RuntimeError('package symlink differs from approved baseline')
                actual[name] = expected
            else:
                if member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or not 0 < member.size <= contract.overlay.MAX_FILE_SIZE:
                    raise RuntimeError('package file type/size mismatch')
                stream = archive.extractfile(member)
                content = stream.read(contract.overlay.MAX_FILE_SIZE + 1)
                if len(content) != member.size:
                    raise RuntimeError('truncated camera package member')
                actual[name] = ('file', member.mode, member.size, contract.sha(content), '-')
                if name in contract.REPLACEMENTS:
                    replacements[name] = content
                elif actual[name] != expected:
                    raise RuntimeError('package changes an unapproved baseline member: ' + name)
    if actual.keys() != baseline.keys() or replacements.keys() != contract.REPLACEMENTS:
        raise RuntimeError('camera package does not contain the complete approved payload')
    contract.overlay.verify(contract.BASE / 'rootfs-overlay', contract.BASE / 'OVERLAY-MANIFEST.tsv', None)
    shutil.copytree(contract.BASE / 'rootfs-overlay', payload, symlinks=True)
    for name, content in replacements.items():
        path = payload / name
        fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), actual[name][1])
    if contract.overlay.inspect_tree(payload)[0] != actual:
        raise RuntimeError('private payload assembly differs from preflight')

def import_profile(producer_repo, package, report_path, output):
    producer_repo = producer_repo.resolve(strict=True)
    output = output.absolute()
    output = output.parent.resolve(strict=True) / output.name
    if output.exists() or output.is_symlink():
        raise RuntimeError('profile output already exists; it will not be overwritten')
    producer = load(producer_repo / 'scripts/ci/verify-libcamera-runtime.py', 'trusted_camera_producer')
    inputs = producer.input_digests()
    source, _, _ = producer.expected_source()
    package_builder = producer_repo / 'scripts/ci/build-tb321fu-camera-stack-deb.sh'
    package_builder_digest = producer.sha(producer.read_regular(package_builder))
    initial_head = subprocess.check_output(['git', '-C', str(producer_repo), 'rev-parse', 'HEAD'], text=True).strip()
    package_bytes = producer.read_regular(package, 256 << 20)
    report_bytes = producer.read_regular(report_path, 4 << 20)
    report = report_bytes.decode('utf-8')
    version = field(report, 'version')
    if re.fullmatch('[0-9][0-9A-Za-z.+:~-]{0,63}', version) is None or field(report, 'arch') != 'arm64':
        raise RuntimeError('unsupported camera package version/architecture')
    checksum = producer.sha(package_bytes) + '  tb321fu-camera-stack_' + version + '_arm64.deb'
    if report.splitlines().count(checksum) != 1:
        raise RuntimeError('actual package bytes differ from the producer report')
    marker = '== complete runtime build provenance (public inputs only) ==\n'
    if report.count(marker) != 1:
        raise RuntimeError('producer report omits unique full-runtime provenance')
    provenance, end = json.JSONDecoder(object_pairs_hook=contract.unique_object).raw_decode(report.split(marker)[1])
    if (not isinstance(provenance, dict) or provenance.get('schema') != 'tb321fu-libcamera-runtime-v1'
            or provenance.get('inputs') != inputs or provenance.get('source') != source
            or provenance.get('options') != list(producer.OPTIONS)):
        raise RuntimeError('package does not bind the current trusted producer sources')
    provenance_bytes = (json.dumps(provenance, sort_keys=True, indent=2) + '\n').encode()
    if producer.sha(provenance_bytes) != field(report, 'libcamera_build_provenance_sha256'):
        raise RuntimeError('producer provenance record checksum mismatch')
    marker = '== complete build runtime manifest (includes build-only headers) ==\n'
    if report.count(marker) != 1:
        raise RuntimeError('producer report omits complete runtime member identity')
    lines = report.split(marker)[1].splitlines()
    if not lines:
        raise RuntimeError('producer runtime manifest is empty')
    selected = [lines[0]]
    for line in lines[1:]:
        if len(line.split('\t')) != 6:
            break
        selected.append(line)
    runtime_manifest = ('\n'.join(selected) + '\n').encode()
    manifest_digest = producer.sha(runtime_manifest)
    if (manifest_digest != field(report, 'libcamera_runtime_manifest_sha256')
            or provenance.get('runtime_manifest_sha256') != manifest_digest
            or provenance.get('replica_manifests') != [manifest_digest, manifest_digest]):
        raise RuntimeError('paired runtime member identity mismatch')
    camera_source = producer_repo / 'source/tb321fu-camera-rootfs-overlay/source'
    identities = {
        'spa_source_sha256': producer.sha(producer.read_regular(camera_source / 'libcamera-source.cpp.clean-minimal-daily')),
        'spa_producer_manifest_sha256': producer.sha(producer.read_regular(camera_source / 'spa-libcamera-producer/SOURCE-MANIFEST.tsv')),
        'spa_toolchain_sha256': producer.sha(producer.read_regular(camera_source / 'spa-libcamera-producer/TOOLCHAIN.tsv')),
    }
    for key, report_key in (('spa_source_sha256', 'camera_source_sha256'),
            ('spa_producer_manifest_sha256', 'camera_producer_manifest_sha256'),
            ('spa_toolchain_sha256', 'camera_toolchain_sha256')):
        if identities[key] != field(report, report_key):
            raise RuntimeError('SPA source identity mismatch: ' + key)
    baseline, baseline_raw = contract.overlay.parse_manifest(contract.BASE / 'OVERLAY-MANIFEST.tsv')
    if producer.sha(baseline_raw) != field(report, 'camera_overlay_manifest_sha256'):
        raise RuntimeError('Ubuntu and Arch historical baseline contracts differ')
    with tempfile.TemporaryDirectory(prefix='.camera-profile-import-', dir=output.parent) as directory:
        work = pathlib.Path(directory)
        private_package, payload_tar = work / 'camera.deb', work / 'payload.tar'
        private_package.write_bytes(package_bytes)
        emit_payload_tar(private_package, payload_tar)
        payload = work / 'payload'
        materialize_deb_payload(payload_tar, payload, baseline)
        actual, _ = contract.overlay.inspect_tree(payload)
        if actual.keys() != baseline.keys():
            raise RuntimeError('package member set differs from the historical camera overlay')
        for name, record in actual.items():
            if name in contract.REPLACEMENTS:
                if record[:2] != baseline[name][:2]:
                    raise RuntimeError('camera package changes baseline member type/mode')
            elif record != baseline[name]:
                raise RuntimeError('package changes an unapproved baseline member: ' + name)
        runtime_manifest_path = work / 'RUNTIME-MANIFEST.tsv'
        runtime_manifest_path.write_bytes(runtime_manifest)
        runtime_manifest_path.chmod(0o644)
        runtime, raw = producer.overlay.parse_manifest(runtime_manifest_path, require_plugin=False)
        producer.check_layout(runtime)
        for name in producer.COMPILED:
            if actual[name][0] != runtime[name][0] or actual[name][2:] != runtime[name][2:]:
                raise RuntimeError('package mixes full-runtime members from different builds')
        if actual[contract.overlay.PLUGIN_PATH][3] != field(report, 'camera_plugin_sha256'):
            raise RuntimeError('SPA package member checksum mismatch')
        stage = work / 'profile'
        create_profile_stage(stage)
        archive = stage / 'remediation-runtime.tar.xz'
        with tarfile.open(archive, mode='x:xz', format=tarfile.PAX_FORMAT, preset=6) as bundle:
            for name in sorted(contract.REPLACEMENTS):
                content = producer.read_regular(payload / name, contract.overlay.MAX_FILE_SIZE)
                member = tarfile.TarInfo(name)
                member.mode, member.size, member.mtime = actual[name][1], len(content), source['epoch']
                member.uid = member.gid = 0
                member.uname = member.gname = ''
                bundle.addfile(member, io.BytesIO(content))
        head = subprocess.check_output(['git', '-C', str(producer_repo), 'rev-parse', 'HEAD'], text=True).strip()
        dirty = subprocess.check_output(['git', '-C', str(producer_repo), 'status', '--porcelain'])
        value = {'schema': 'tb321fu-camera-remediation-profile-v1',
            'baseline_manifest_sha256': producer.sha(baseline_raw),
            'archive_sha256': producer.sha(archive.read_bytes()), 'archive_bytes': archive.stat().st_size,
            'epoch': source['epoch'], 'producer_provenance_sha256': producer.sha(provenance_bytes),
            'producer_report_sha256': producer.sha(report_bytes), 'package_sha256': producer.sha(package_bytes),
            'package_version': version, 'producer_source': {
                'kind': 'working-tree-snapshot' if dirty else 'immutable-git-commit', 'git_head': head,
                'inputs_sha256': producer.sha(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode()),
                'package_builder_sha256': package_builder_digest,
                **identities},
            'replacements': {name: {'mode': f'0{actual[name][1]:o}', 'size': actual[name][2], 'sha256': actual[name][3]}
                             for name in sorted(contract.REPLACEMENTS)}}
        (stage / 'PROFILE.json').write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
        (stage / 'BUILD-PROVENANCE.json').write_bytes(provenance_bytes)
        (stage / 'BUILD-REPORT.txt').write_bytes(report_bytes)
        for name in contract.FILES:
            (stage / name).chmod(0o644)
        contract.verify_tree(payload, stage)
        if producer.input_digests() != inputs or producer.expected_source()[0] != source:
            raise RuntimeError('trusted producer inputs changed during profile import')
        for key, name in (('spa_source_sha256', 'libcamera-source.cpp.clean-minimal-daily'),
                          ('spa_producer_manifest_sha256', 'spa-libcamera-producer/SOURCE-MANIFEST.tsv'),
                          ('spa_toolchain_sha256', 'spa-libcamera-producer/TOOLCHAIN.tsv')):
            if producer.sha(producer.read_regular(camera_source / name)) != identities[key]:
                raise RuntimeError('trusted SPA producer inputs changed during import')
        if (producer.sha(producer.read_regular(package_builder)) != package_builder_digest
                or head != initial_head
                or subprocess.check_output(['git', '-C', str(producer_repo), 'rev-parse', 'HEAD'], text=True).strip() != initial_head):
            raise RuntimeError('producer checkout identity changed during import')
        contract.promote(stage, output)
    return value

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--producer-repo', type=pathlib.Path, required=True)
    parser.add_argument('--deb', type=pathlib.Path, required=True)
    parser.add_argument('--report', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    try:
        args = parser.parse_args()
        value = import_profile(args.producer_repo, args.deb, args.report, args.output)
        print('CAMERA_REMEDIATION_IMPORT=PASS package_sha256=' + value['package_sha256'])
    except (RuntimeError, OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        raise SystemExit('CAMERA_REMEDIATION_IMPORT=FAIL: ' + str(error))
