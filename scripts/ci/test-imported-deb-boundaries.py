#!/usr/bin/env python3
"""Offline hostile-input tests for the Arch Debian import verifier.

The Arch image intentionally imports a small, fixed set of Ubuntu DEB data
trees.  These tests construct tiny packages locally and exercise the same
dpkg-deb path used by the builder, including the extraction-stage recheck.
No network, root filesystem, or package database is touched.
"""

from __future__ import annotations

import gzip
import hashlib
import importlib.util
import io
import os
import pathlib
import signal
import shutil
import stat
import sys
import tarfile
import tempfile
import time
from collections.abc import Iterable


os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.dont_write_bytecode = True
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
HELPER = SCRIPT_DIR / "verify-imported-deb.py"
PACKAGE = "tb321fu-haptics"
VERSION = "20260627.2"
ARCH = "arm64"
DEPENDS = "kmod, systemd, udev, coreutils, findutils, feedbackd, feedbackd-device-themes"


def load_helper():
    spec = importlib.util.spec_from_file_location("verify_imported_deb", HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load DEB verifier")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


VERIFIER = load_helper()


def tar_member(
    archive: tarfile.TarFile,
    name: str,
    kind: str,
    payload: bytes = b"",
    *,
    mode: int = 0o644,
    linkname: str = "",
    pax_headers: dict[str, str] | None = None,
) -> None:
    member = tarfile.TarInfo(name)
    member.uid = 0
    member.gid = 0
    member.mtime = 0
    member.mode = mode
    if pax_headers:
        member.pax_headers = dict(pax_headers)
    if kind == "dir":
        member.type = tarfile.DIRTYPE
        member.size = 0
        archive.addfile(member)
    elif kind == "file":
        member.type = tarfile.REGTYPE
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    elif kind == "symlink":
        member.type = tarfile.SYMTYPE
        member.linkname = linkname
        member.size = 0
        archive.addfile(member)
    elif kind == "hardlink":
        member.type = tarfile.LNKTYPE
        member.linkname = linkname
        member.size = 0
        archive.addfile(member)
    elif kind == "fifo":
        member.type = tarfile.FIFOTYPE
        member.size = 0
        archive.addfile(member)
    else:
        raise AssertionError(f"unknown tar fixture kind: {kind}")


def make_tar(
    entries: Iterable[tuple[str, str, bytes, int, str]],
    *,
    pax: bool = False,
) -> bytes:
    output = io.BytesIO()
    fmt = tarfile.PAX_FORMAT if pax else tarfile.GNU_FORMAT
    with tarfile.open(fileobj=output, mode="w", format=fmt) as archive:
        for name, kind, payload, mode, linkname in entries:
            tar_member(
                archive,
                name,
                kind,
                payload,
                mode=mode,
                linkname=linkname,
                pax_headers={"fixture": "pax"} if pax else None,
            )
    return output.getvalue()


def control_tar(
    *,
    package: str = PACKAGE,
    version: str = VERSION,
    arch: str = ARCH,
    depends: str = DEPENDS,
    extra_field: str = "",
) -> bytes:
    control = (
        f"Package: {package}\n"
        f"Version: {version}\n"
        f"Architecture: {arch}\n"
        f"Depends: {depends}\n"
        f"{extra_field}"
        "Description: tiny verifier fixture\n"
    ).encode("ascii")
    entries = [
        ("./", "dir", b"", 0o755, ""),
        ("./control", "file", control, 0o644, ""),
        ("./postinst", "file", b"#!/bin/sh\nexit 0\n", 0o755, ""),
        ("./postrm", "file", b"#!/bin/sh\nexit 0\n", 0o755, ""),
    ]
    return gzip.compress(make_tar(entries), mtime=0)


BASE_DATA_ENTRIES: list[tuple[str, str, bytes, int, str]] = [
    ("./", "dir", b"", 0o755, ""),
    ("./usr", "dir", b"", 0o755, ""),
    ("./usr/share", "dir", b"", 0o755, ""),
    ("./usr/share/tb321fu", "dir", b"", 0o755, ""),
    ("./usr/share/tb321fu/fixture", "file", b"known-good\n", 0o644, ""),
]


def ar_header(name: str, size: int, *, mode: int = 0o100644) -> bytes:
    if len(name) > 16 or name.endswith("/") or "/" in name:
        raise AssertionError(name)
    fields = (
        name.ljust(16),
        "0".ljust(12),
        "0".ljust(6),
        "0".ljust(6),
        format(mode, "o").ljust(8),
        str(size).ljust(10),
    )
    header = "".join(fields).encode("ascii") + b"`\n"
    assert len(header) == 60
    return header


def make_deb(
    destination: pathlib.Path,
    *,
    data_entries: Iterable[tuple[str, str, bytes, int, str]] = BASE_DATA_ENTRIES,
    control_package: str = PACKAGE,
    control_version: str = VERSION,
    control_arch: str = ARCH,
    control_depends: str = DEPENDS,
    control_extra_field: str = "",
    data_pax: bool = False,
    extra_ar_member: bool = False,
    ar_mode: int = 0o100644,
) -> pathlib.Path:
    data = gzip.compress(make_tar(data_entries, pax=data_pax), mtime=0)
    control = control_tar(
        package=control_package,
        version=control_version,
        arch=control_arch,
        depends=control_depends,
        extra_field=control_extra_field,
    )
    members = [
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control),
        ("data.tar.gz", data),
    ]
    if extra_ar_member:
        members.append(("extra", b"x"))
    output = bytearray(b"!<arch>\n")
    for name, payload in members:
        output.extend(ar_header(name, len(payload), mode=ar_mode))
        output.extend(payload)
        if len(payload) & 1:
            output.extend(b"\n")
    destination.write_bytes(output)
    return destination


def install_fixture_contract(deb: pathlib.Path) -> list:
    fields = ("Package", "Version", "Architecture", "Depends", "Description")
    members = ("control", "postinst", "postrm")
    base = VERIFIER.DebContract(
        VERSION,
        ARCH,
        DEPENDS,
        members,
        fields,
        "",
        "",
        "",
    )
    VERIFIER.CONTRACTS[PACKAGE] = base
    fd, metadata = VERIFIER._open_deb(deb)
    try:
        control_tar_bytes = VERIFIER._dpkg_tar_bytes(
            fd, "--ctrl-tarfile", "fixture control", VERIFIER.MAX_CONTROL_BYTES
        )
        records = VERIFIER._verify_data(fd, PACKAGE)
        deb_digest = VERIFIER._hash_fd(fd, metadata.st_size)
    finally:
        os.close(fd)
    with tarfile.open(fileobj=io.BytesIO(control_tar_bytes), mode="r:") as archive:
        control = archive.extractfile("./control")
        if control is None:
            raise SystemExit("fixture control file is missing")
        control_blob = control.read()
    VERIFIER.CONTRACTS[PACKAGE] = VERIFIER.DebContract(
        VERSION,
        ARCH,
        DEPENDS,
        members,
        fields,
        deb_digest,
        hashlib.sha256(control_blob).hexdigest(),
        VERIFIER._manifest_sha256(records),
    )
    return records


def require_direct_rejected(
    deb: pathlib.Path,
    label: str,
    *,
    stage: pathlib.Path | None = None,
) -> None:
    try:
        VERIFIER.verify(deb, PACKAGE, stage)
    except VERIFIER.DebError:
        return
    raise SystemExit(f"unsafe fixture accepted by direct verifier: {label}")


def require_call_rejected(action, label: str, *, max_elapsed: float | None = None) -> None:
    started = time.monotonic()
    try:
        action()
    except VERIFIER.DebError:
        elapsed = time.monotonic() - started
        if max_elapsed is not None and elapsed > max_elapsed:
            raise SystemExit(
                f"hostile fixture exceeded its deadline: {label}: {elapsed:.3f}s"
            )
        return
    raise SystemExit(f"unsafe fixture accepted: {label}")


def pathname_only_stage_records(
    root: pathlib.Path,
    swap_target: str,
    swap,
) -> list:
    """Model the old pathname walker and deterministically trigger one swap.

    The callback runs after the walk has authenticated a directory with a
    no-follow stat, while all subsequent recursion and hashing resolve the
    saved pathname again. A byte-identical replacement therefore remains
    indistinguishable to this intentionally unsafe oracle; the production
    verifier must reject it by descriptor identity instead.
    """
    records = []
    swapped = False

    def walk(directory: pathlib.Path, prefix: str = "") -> None:
        nonlocal swapped
        with os.scandir(directory) as entries:
            ordered = sorted(entries, key=lambda item: os.fsencode(item.name))
            for entry in ordered:
                name = entry.name
                relative = f"{prefix}/{name}" if prefix else name
                metadata = entry.stat(follow_symlinks=False)
                if relative == swap_target and not swapped:
                    swapped = True
                    swap()
                mode = metadata.st_mode
                if stat.S_ISDIR(mode):
                    records.append(VERIFIER.TreeRecord(
                        relative, "d", mode & 0o7777, 0, ""
                    ))
                    # entry.path is a pathname, so this follows the replacement.
                    walk(pathlib.Path(entry.path), relative)
                elif stat.S_ISREG(mode):
                    payload = pathlib.Path(entry.path).read_bytes()
                    records.append(VERIFIER.TreeRecord(
                        relative,
                        "f",
                        mode & 0o7777,
                        metadata.st_size,
                        hashlib.sha256(payload).hexdigest(),
                    ))
                elif stat.S_ISLNK(mode):
                    records.append(VERIFIER.TreeRecord(
                        relative,
                        "l",
                        mode & 0o7777,
                        0,
                        os.readlink(entry.path),
                    ))
                else:
                    raise SystemExit(
                        f"pathname oracle encountered unsupported member: {relative}"
                    )

    root_metadata = root.lstat()
    records.append(VERIFIER.TreeRecord(
        "", "d", root_metadata.st_mode & 0o7777, 0, ""
    ))
    walk(root)
    if not swapped:
        raise SystemExit(f"pathname oracle did not reach swap target: {swap_target}")
    return sorted(records, key=lambda item: item.path)


def collect_bounded(command: list[str], label: str, limit: int, timeout: float) -> bytes:
    with VERIFIER._BoundedProcess(
        command,
        label,
        limit,
        timeout=timeout,
    ) as output:
        result = output.read()
        output.finish()
        return result


def assert_process_stopped(pid: int, label: str) -> None:
    proc_stat = pathlib.Path(f"/proc/{pid}/stat")
    for _ in range(100):
        try:
            text = proc_stat.read_text(encoding="ascii")
        except FileNotFoundError:
            return
        state = text.rsplit(")", 1)[1].split()[0]
        if state == "Z":
            return
        time.sleep(0.01)
    raise SystemExit(f"hostile descendant survived process-group cleanup: {label}: {pid}")


def main() -> None:
    if not HELPER.is_file():
        raise SystemExit(f"missing verifier: {HELPER}")
    if not shutil_which("dpkg-deb"):
        raise SystemExit("dpkg-deb is required for imported DEB boundary tests")

    # A child may fill stderr before producing stdout. Both pipes must be
    # drained concurrently so this succeeds instead of deadlocking on a full
    # stderr pipe.
    stderr_fill = collect_bounded(
        [
            sys.executable,
            "-c",
            "import sys; "
            "sys.stderr.buffer.write(b'e' * (256 * 1024)); "
            "sys.stderr.buffer.flush(); "
            "sys.stdout.buffer.write(b'ok')",
        ],
        "stderr-fill fixture",
        16,
        3.0,
    )
    if stderr_fill != b"ok":
        raise SystemExit("concurrent stderr fixture returned wrong stdout")

    require_call_rejected(
        lambda: collect_bounded(
            [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'x' * 4096)"],
            "stdout-bound fixture",
            1024,
            3.0,
        ),
        "subprocess stdout byte bound",
        max_elapsed=3.0,
    )
    stderr_limit = VERIFIER.MAX_DPKG_STDERR_BYTES
    VERIFIER.MAX_DPKG_STDERR_BYTES = 1024
    try:
        require_call_rejected(
            lambda: collect_bounded(
                [sys.executable, "-c", "import sys; sys.stderr.buffer.write(b'e' * 4096)"],
                "stderr-bound fixture",
                16,
                3.0,
            ),
            "subprocess stderr byte bound",
            max_elapsed=3.0,
        )
    finally:
        VERIFIER.MAX_DPKG_STDERR_BYTES = stderr_limit

    require_call_rejected(
        lambda: collect_bounded(
            [
                sys.executable,
                "-c",
                "import sys,time; sys.stdout.buffer.write(b'x'); "
                "sys.stdout.buffer.flush(); time.sleep(30)",
            ],
            "stdout-stall fixture",
            16,
            0.25,
        ),
        "stalled stdout deadline",
        max_elapsed=3.0,
    )

    signal_child_pid = -1
    previous_sigterm = signal.signal(signal.SIGTERM, VERIFIER._raise_termination)
    try:
        try:
            with VERIFIER._BoundedProcess(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                "termination fixture",
                16,
                timeout=30.0,
            ) as output:
                signal_child_pid = output.proc.pid
                os.kill(os.getpid(), signal.SIGTERM)
        except VERIFIER.TerminationRequested as exc:
            if exc.signum != signal.SIGTERM:
                raise SystemExit("termination fixture returned the wrong signal")
        else:
            raise SystemExit("termination fixture did not interrupt the verifier")
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
    assert_process_stopped(signal_child_pid, "termination cleanup")

    with tempfile.TemporaryDirectory(prefix="tb321fu-deb-boundary.") as raw:
        root = pathlib.Path(raw)
        descendant_pid_file = root / "descendant.pid"
        require_call_rejected(
            lambda: collect_bounded(
                [
                    sys.executable,
                    "-c",
                    "import os,sys,time; child=os.fork(); "
                    "(open(sys.argv[1], 'w').write(str(os.getpid())), "
                    "time.sleep(30), os._exit(0)) if child == 0 else os._exit(0)",
                    str(descendant_pid_file),
                ],
                "descendant fixture",
                16,
                0.5,
            ),
            "pipe-holding descendant deadline",
            max_elapsed=3.0,
        )
        for _ in range(100):
            if descendant_pid_file.is_file():
                break
            time.sleep(0.01)
        if not descendant_pid_file.is_file():
            raise SystemExit("descendant fixture did not record its pid")
        assert_process_stopped(
            int(descendant_pid_file.read_text(encoding="ascii")),
            "pipe-holding descendant",
        )

        valid = make_deb(root / "valid.deb")
        valid_records = install_fixture_contract(valid)
        valid_digest = VERIFIER.verify(valid, PACKAGE)
        if valid_digest != VERIFIER.CONTRACTS[PACKAGE].deb_sha256:
            raise SystemExit("direct verifier returned the wrong authenticated digest")

        # Replace the pathname immediately after the ar preflight. Every
        # subsequent hash/dpkg/extraction operation must continue through the
        # already authenticated fd and produce the original tree/digest.
        swappable = make_deb(root / "swappable.deb")
        install_fixture_contract(swappable)
        expected_swap_digest = VERIFIER.CONTRACTS[PACKAGE].deb_sha256
        attacker_entries = [
            *BASE_DATA_ENTRIES[:-1],
            ("./usr/share/tb321fu/fixture", "file", b"path-swap\n", 0o644, ""),
        ]
        attacker = make_deb(root / "attacker.deb", data_entries=attacker_entries)
        swap_stage = root / "swap-stage"
        swap_stage.mkdir()
        original_parse_ar = VERIFIER.parse_ar

        def parse_and_swap(fd, metadata):
            records = original_parse_ar(fd, metadata)
            os.replace(attacker, swappable)
            return records

        VERIFIER.parse_ar = parse_and_swap
        try:
            swap_digest = VERIFIER.verify(
                swappable,
                PACKAGE,
                swap_stage,
                extract=True,
            )
        finally:
            VERIFIER.parse_ar = original_parse_ar
        if swap_digest != expected_swap_digest:
            raise SystemExit("path swap changed the authenticated DEB digest")
        install_fixture_contract(valid)

        # The command-line boundary must reject a symlink, even if it points
        # to an otherwise valid package.  This guards against resolve()-based
        # identity bypasses.
        deb_link = root / "valid-link.deb"
        deb_link.symlink_to(valid)
        require_direct_rejected(deb_link, "DEB symlink")

        require_direct_rejected(
            make_deb(root / "extra-member.deb", extra_ar_member=True),
            "extra ar member",
        )
        require_direct_rejected(
            make_deb(root / "bad-version.deb", control_version="20260627.1"),
            "version drift",
        )
        require_direct_rejected(
            make_deb(root / "bad-arch.deb", control_arch="amd64"),
            "architecture drift",
        )
        require_direct_rejected(
            make_deb(root / "bad-depends.deb", control_depends="libc6"),
            "dependency drift",
        )
        require_direct_rejected(
            make_deb(root / "extra-control-field.deb", control_extra_field="X-Evil: yes\n"),
            "unexpected control field",
        )

        traversal = [*BASE_DATA_ENTRIES, ("./../escape", "file", b"x", 0o644, "")]
        require_direct_rejected(make_deb(root / "traversal.deb", data_entries=traversal), "dot-dot path")
        absolute = [*BASE_DATA_ENTRIES, ("/etc/passwd", "file", b"x", 0o644, "")]
        require_direct_rejected(make_deb(root / "absolute.deb", data_entries=absolute), "absolute path")
        hardlink = [*BASE_DATA_ENTRIES, ("./usr/share/tb321fu/hard", "hardlink", b"", 0o644, "./usr/share/tb321fu/fixture")]
        require_direct_rejected(make_deb(root / "hardlink.deb", data_entries=hardlink), "hardlink")
        fifo = [*BASE_DATA_ENTRIES, ("./usr/share/tb321fu/fifo", "fifo", b"", 0o644, "")]
        require_direct_rejected(make_deb(root / "fifo.deb", data_entries=fifo), "FIFO")
        unsafe_link = [*BASE_DATA_ENTRIES, ("./usr/share/tb321fu/link", "symlink", b"", 0o777, "/etc/passwd")]
        require_direct_rejected(make_deb(root / "unsafe-link.deb", data_entries=unsafe_link), "unsafe symlink")
        require_direct_rejected(
            make_deb(root / "pax.deb", data_entries=BASE_DATA_ENTRIES, data_pax=True),
            "PAX metadata",
        )
        extra_ordinary = [
            *BASE_DATA_ENTRIES,
            ("./etc", "dir", b"", 0o755, ""),
            ("./etc/evil", "file", b"unexpected\n", 0o644, ""),
        ]
        require_direct_rejected(
            make_deb(root / "extra-ordinary.deb", data_entries=extra_ordinary),
            "extra ordinary path",
        )
        changed_content = [
            *BASE_DATA_ENTRIES[:-1],
            ("./usr/share/tb321fu/fixture", "file", b"changed\n", 0o644, ""),
        ]
        require_direct_rejected(
            make_deb(root / "changed-content.deb", data_entries=changed_content),
            "changed regular-file content",
        )

        # A real dpkg-deb extraction must match the stream-derived member set;
        # a symlink stage must not be accepted by the --stage option.
        stage = root / "stage"
        stage.mkdir()
        VERIFIER.verify(valid, PACKAGE, stage, extract=True)
        VERIFIER.verify(valid, PACKAGE, stage)

        # First prove the exploit model independently of the production
        # verifier. The old pathname-only walk sees the original directory
        # metadata, then follows the saved path into a byte-identical clone and
        # accepts the resulting records. This avoids tying the regression to
        # the current verifier's os.stat() implementation detail.
        pathname_stage = root / "stage-pathname-oracle"
        shutil.copytree(stage, pathname_stage)
        pathname_directory = pathname_stage / "usr/share/tb321fu"
        pathname_replacement = root / "tb321fu-pathname-replacement"
        pathname_backup = root / "tb321fu-pathname-original"
        shutil.copytree(pathname_directory, pathname_replacement)
        if os.path.samestat(
            pathname_directory.stat(), pathname_replacement.stat()
        ):
            raise SystemExit("pathname oracle replacement unexpectedly kept identity")

        def swap_for_pathname_oracle():
            os.replace(pathname_directory, pathname_backup)
            os.replace(pathname_replacement, pathname_directory)

        pathname_records = pathname_only_stage_records(
            pathname_stage,
            "usr/share/tb321fu",
            swap_for_pathname_oracle,
        )
        if pathname_records != sorted(valid_records, key=lambda item: item.path):
            raise SystemExit(
                "pathname-only oracle did not accept the byte-identical directory swap"
            )

        # A directory can be replaced after its no-follow stat but before the
        # verifier opens/descends it.  Swap in a byte-identical clone so a
        # pathname-only walker would accept the tree; the descriptor-relative
        # walker must reject the changed inode identity instead.
        stage_identity_swap = root / "stage-identity-swap"
        shutil.copytree(stage, stage_identity_swap)
        swapped = {"done": False}
        original_stat = os.stat
        swapped_directory = stage_identity_swap / "usr/share/tb321fu"
        replacement_directory = stage_identity_swap / "usr/share/tb321fu-replacement"
        shutil.copytree(swapped_directory, replacement_directory)

        def stat_and_swap(path, *args, **kwargs):
            result = original_stat(path, *args, **kwargs)
            directory_fd = kwargs.get("dir_fd")
            if (
                not swapped["done"]
                and path == "tb321fu"
                and kwargs.get("follow_symlinks") is False
                and isinstance(directory_fd, int)
            ):
                try:
                    parent_name = os.readlink(f"/proc/self/fd/{directory_fd}")
                except OSError:
                    parent_name = ""
                if parent_name == str(stage_identity_swap / "usr/share"):
                    swapped["done"] = True
                    # Keep the replacement parent namespace byte-for-byte
                    # identical; the only intentional difference is inode
                    # identity.  Store the old directory outside the stage so
                    # a pathname-only implementation cannot reject merely on
                    # an extra member.
                    backup = root / "tb321fu-original"
                    os.replace(swapped_directory, backup)
                    os.replace(replacement_directory, swapped_directory)
            return result

        os.stat = stat_and_swap
        try:
            try:
                VERIFIER._verify_stage(stage_identity_swap, PACKAGE, valid_records)
            except VERIFIER.DebError as exc:
                if "changed" not in str(exc) and "identity" not in str(exc):
                    raise SystemExit(
                        f"directory path-swap rejected for an unrelated reason: {exc}"
                    )
            else:
                raise SystemExit("directory path-swap fixture was accepted")
        finally:
            os.stat = original_stat
        if not swapped["done"]:
            raise SystemExit("directory path-swap fixture did not reach its trigger")

        stage_link = root / "stage-link"
        stage_link.symlink_to(stage, target_is_directory=True)
        require_direct_rejected(valid, "extraction stage symlink", stage=stage_link)

        member_limit = VERIFIER.MAX_DATA_MEMBERS
        VERIFIER.MAX_DATA_MEMBERS = len(valid_records) - 1
        try:
            require_call_rejected(
                lambda: VERIFIER._verify_stage(stage, PACKAGE, valid_records),
                "extracted-stage member count bound",
            )
        finally:
            VERIFIER.MAX_DATA_MEMBERS = member_limit

        data_limit = VERIFIER.MAX_DATA_BYTES
        VERIFIER.MAX_DATA_BYTES = 8
        try:
            require_call_rejected(
                lambda: VERIFIER._verify_stage(stage, PACKAGE, valid_records),
                "extracted-stage aggregate byte bound",
            )
        finally:
            VERIFIER.MAX_DATA_BYTES = data_limit

        stage_timeout = VERIFIER.STAGE_VERIFY_TIMEOUT_SECONDS
        VERIFIER.STAGE_VERIFY_TIMEOUT_SECONDS = 1e-12
        try:
            require_call_rejected(
                lambda: VERIFIER._verify_stage(stage, PACKAGE, valid_records),
                "extracted-stage monotonic deadline",
                max_elapsed=1.0,
            )
        finally:
            VERIFIER.STAGE_VERIFY_TIMEOUT_SECONDS = stage_timeout

        extra_stage = stage / "extra"
        extra_stage.write_text("unexpected\n", encoding="ascii")
        require_direct_rejected(valid, "extra extracted member", stage=stage)
        extra_stage.unlink()

        fixture_stage = stage / "usr/share/tb321fu/fixture"
        original = fixture_stage.read_bytes()
        fixture_stage.write_bytes(b"changed-stage\n")
        require_direct_rejected(valid, "changed extracted file content", stage=stage)
        fixture_stage.write_bytes(original)

        hard_stage = stage / "hard"
        os.link(stage / "usr/share/tb321fu/fixture", hard_stage)
        require_direct_rejected(valid, "hard-linked extracted file", stage=stage)
        hard_stage.unlink()

        fifo_stage = stage / "fifo"
        os.mkfifo(fifo_stage, 0o644)
        require_direct_rejected(valid, "special extracted member", stage=stage)
        fifo_stage.unlink()

        # Exercise the direct API as well as the CLI so callers cannot bypass
        # the non-following stage check by importing the helper.
        try:
            VERIFIER.verify(valid, PACKAGE, stage_link)
        except VERIFIER.DebError:
            pass
        else:
            raise SystemExit("direct API accepted extraction stage symlink")

    print("IMPORTED_DEB_BOUNDARY_FIXTURES=PASS")


def shutil_which(command: str) -> str | None:
    # Keep this test self-contained and avoid importing a module solely for a
    # one-line lookup in minimal CI Python images.
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = pathlib.Path(directory) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


if __name__ == "__main__":
    main()
