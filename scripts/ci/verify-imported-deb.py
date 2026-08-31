#!/usr/bin/env python3
"""Verify a Debian payload before it is imported into the Arch rootfs.

The Arch builder deliberately extracts only the data member of a Debian
package.  This verifier keeps that exception closed-world: the package
identity and dependency metadata are fixed to the tested release, the ar
container is canonical, and every data-tar entry is a contained regular file,
directory, or explicitly safe relative symlink.  It does not execute any
maintainer script.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import pathlib
import re
import selectors
import signal
import stat
import subprocess
import tarfile
import time
from dataclasses import dataclass


AR_MAGIC = b"!<arch>\n"
AR_HEADER_BYTES = 60
AR_TRAILER = b"`\n"
MAX_DEB_BYTES = 512 * 1024 * 1024
MAX_CONTROL_BYTES = 16 * 1024 * 1024
MAX_DATA_BYTES = 8 * 1024 * 1024 * 1024
MAX_DATA_MEMBERS = 250_000
MAX_MEMBER_BYTES = 512 * 1024 * 1024
MAX_PATH_BYTES = 4096
MAX_COMPONENT_BYTES = 255
MAX_SYMLINK_BYTES = 4096
MAX_DPKG_STDERR_BYTES = 1024 * 1024
MAX_EXTRACT_STDOUT_BYTES = 64 * 1024
MAX_DATA_STREAM_BYTES = (
    MAX_DATA_BYTES
    + MAX_DATA_MEMBERS * (MAX_PATH_BYTES + 2048)
    + 1024 * 1024
)
DPKG_TIMEOUT_SECONDS = 30.0
STAGE_VERIFY_TIMEOUT_SECONDS = 15 * 60.0
PROCESS_REAP_SECONDS = 2.0
PROCESS_READ_BYTES = 64 * 1024

PACKAGE_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]{0,127}$")
VERSION_RE = re.compile(r"^[0-9][0-9A-Za-z.+:~-]{0,127}$")
ARCH_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")


@dataclass(frozen=True)
class DebContract:
    version: str
    architecture: str
    depends: str
    control_members: tuple[str, ...]
    control_fields: tuple[str, ...]
    deb_sha256: str
    control_sha256: str
    data_manifest_sha256: str
    filename: str = ""


# These are the exact packages carried by the tested 2026-06 release inputs.
# The byte and tree digests are deliberately part of the source contract: a
# plausible filename/control stanza is not enough to enter an Arch image.
# Values are filled from the immutable release assets and their canonical
# dpkg data trees.  Tests may replace one contract in-process with a synthetic
# contract, but the production table is always fully pinned.
CONTRACTS: dict[str, DebContract] = {
    "y700-daily-kernel-modules": DebContract(
        "0.1+20260624-201420", "arm64", "", ("control", "postinst"),
        ("Package", "Version", "Section", "Priority", "Architecture", "Maintainer", "Description"),
        "75750a5235f5d494cdfad6ac0a7fc3832b9e181cf61999168ccd34fe8a53e0d8",
        "ec86e0a02c5392d0348326365d8eca6e0937100b22f7a6494c1b1865e69dcc8d",
        "1a31607e2c660b0bc7c10aa45cf585fdd0d7f8cc0456ce8c83a98c5062f56082",
        "y700-daily-kernel-modules_0.1+20260624-201420_arm64.deb",
    ),
    "y700-daily-rootfs-overlay": DebContract(
        "0.1+20260624-201420", "arm64", "", ("control", "postinst"),
        ("Package", "Version", "Section", "Priority", "Architecture", "Maintainer", "Replaces", "Description"),
        "9b45ab04d455cfcc24ed40779e9522930543330151c254e87a2aee7f381db5bc",
        "2f41fe4d8a68f970dd6faefdfdee849be000453914cdcf9ebffc98559d6d4462",
        "84072031b5b13858de617a971b205b03387ce8bac59815fec75573043d4295fc",
        "y700-daily-rootfs-overlay_0.1+20260624-201420_arm64.deb",
    ),
    "qcom-sns-hexagonrpc": DebContract(
        "20260627.1", "arm64", "libc6", ("control", "postinst", "postrm"),
        ("Package", "Version", "Section", "Priority", "Architecture", "Maintainer", "Provides", "Depends", "Description"),
        "606e8a27e451d270c7260efa8c96b7d03e6232102696ee001536df6b77fbaeb5",
        "e73f740bdf98ea6dfaf5e4be6bf210e4022e990a15db8a3312812776a3067c51",
        "984df09d3135828141fd7bf1cba024432ca0cd7702421cf7a307abf869f0b938",
        "qcom-sns-hexagonrpc_20260627.1_arm64.deb",
    ),
    "qcom-sns-iio-sensor-proxy": DebContract(
        "20260627.1", "arm64",
        "libc6, dbus, libglib2.0-0, libgudev-1.0-0, libpolkit-gobject-1-0, qcom-sns-libssc",
        ("control", "postinst", "postrm"),
        ("Package", "Version", "Section", "Priority", "Architecture", "Maintainer", "Provides", "Depends", "Replaces", "Description"),
        "b010a9a783629c4e0fd4c404b1a34e14258fab8a674d0499d553d361cb59a843",
        "f5544de9523060acc34f34c261ac50194f0fdac4d829e90ad5d86466f0c5689c",
        "016679ac3058de3bbd7df41719bfee1f8be387564a1df3faccb0a4b3fb9d33e1",
        "qcom-sns-iio-sensor-proxy_20260627.1_arm64.deb",
    ),
    "qcom-sns-libssc": DebContract(
        "20260627.1", "arm64", "libc6, libglib2.0-0, libprotobuf-c1, libqmi-glib5",
        ("control", "postinst", "postrm"),
        ("Package", "Version", "Section", "Priority", "Architecture", "Maintainer", "Provides", "Depends", "Description"),
        "4c6f84c266a2c6d588289b5a9700a59711f0a7824744c8a788c8adf7c5786f86",
        "866fb206e9b714c65e585fab3104a5355dd7a83fde39873788f0441fa4a174d0",
        "4b27b8ecfae94f2ecfb00b1373ce075f18ec4eb3d1b8fcc589d7ce9de6a502e2",
        "qcom-sns-libssc_20260627.1_arm64.deb",
    ),
    "tb321fu-sensors": DebContract(
        "20260627.1", "arm64",
        "qcom-sns-hexagonrpc, qcom-sns-iio-sensor-proxy, qcom-sns-libssc, systemd, coreutils, findutils",
        ("control", "postinst", "postrm"),
        ("Package", "Version", "Section", "Priority", "Architecture", "Maintainer", "Depends", "Replaces", "Description"),
        "6ead79941ac1e7f6acb89859915e10301e4bd87ea4d3e5246808ac7e6e632501",
        "738b81bf794b64d8e5166baaef15e53e266350a5b89ee404ea5ff96672d354b8",
        "d60286e360df1f2c1639d1d11737cf7e0af64e119bb322395f92d538495abb9e",
        "tb321fu-sensors_20260627.1_arm64.deb",
    ),
    "tb321fu-haptics": DebContract(
        "20260627.2", "arm64",
        "kmod, systemd, udev, coreutils, findutils, feedbackd, feedbackd-device-themes",
        ("control", "postinst", "postrm"),
        ("Package", "Version", "Section", "Priority", "Architecture", "Maintainer", "Depends", "Conflicts", "Replaces", "Description"),
        "e1929600075d96aa79b4d4b2ee3082355c23e73a06aa54a2f237420d0f0dd522",
        "0e9787d651c988c22a28c2b1125ff0c64550d175bfaf71271b747f8bee7f9b0c",
        "6f0baef0b087b0c7dc9dfaf606b744d2d57b41f6747e3cac0cd86865e697f36b",
        "tb321fu-haptics_20260627.2_arm64.deb",
    ),
}


@dataclass(frozen=True)
class ArMember:
    name: str
    offset: int
    size: int
    mtime: int
    uid: int
    gid: int
    mode: int


@dataclass(frozen=True)
class TreeRecord:
    path: str
    kind: str
    mode: int
    size: int
    value: str


class DebError(ValueError):
    pass


class TerminationRequested(BaseException):
    def __init__(self, signum: int):
        super().__init__(f"termination signal {signum}")
        self.signum = signum


def _raise_termination(signum: int, _frame) -> None:
    # Raising lets every active _BoundedProcess context kill and reap its
    # independent process group before the CLI returns 128 + signal.
    raise TerminationRequested(signum)


class _PreadHandle:
    """Small seekable reader whose offset is private from the authenticated fd."""

    def __init__(self, fd: int, size: int):
        self.fd = fd
        self.size = size
        self.position = 0

    def tell(self) -> int:
        return self.position

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_SET:
            position = offset
        elif whence == os.SEEK_CUR:
            position = self.position + offset
        elif whence == os.SEEK_END:
            position = self.size + offset
        else:
            raise ValueError(f"unsupported seek mode: {whence}")
        if position < 0:
            raise ValueError("negative authenticated-fd seek")
        self.position = position
        return position

    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            size = max(0, self.size - self.position)
        if size == 0:
            return b""
        data = os.pread(self.fd, size, self.position)
        self.position += len(data)
        return data


class _BoundedProcess:
    """Drain both child pipes under one process-group deadline."""

    def __init__(
        self,
        command: list[str],
        label: str,
        stdout_limit: int,
        *,
        pass_fds: tuple[int, ...] = (),
        timeout: float = DPKG_TIMEOUT_SECONDS,
    ):
        if stdout_limit < 0 or timeout <= 0:
            raise DebError(f"invalid subprocess bound for {label}")
        self.label = label
        self.stdout_limit = stdout_limit
        self.deadline = time.monotonic() + timeout
        self.stdout_buffer = bytearray()
        self.stderr_buffer = bytearray()
        self.stdout_count = 0
        self.finished = False
        self.selector = selectors.DefaultSelector()
        try:
            self.proc = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                pass_fds=pass_fds,
                start_new_session=True,
            )
        except OSError as exc:
            self.selector.close()
            raise DebError(f"cannot start {label}") from exc
        if self.proc.stdout is None or self.proc.stderr is None:
            self._abort()
            raise DebError(f"cannot capture {label}")
        try:
            for stream, name in ((self.proc.stdout, "stdout"), (self.proc.stderr, "stderr")):
                os.set_blocking(stream.fileno(), False)
                self.selector.register(stream, selectors.EVENT_READ, name)
        except BaseException:
            self._abort()
            raise

    def __enter__(self) -> _BoundedProcess:
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        if not self.finished:
            self._abort()

    def _remaining(self) -> float:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise DebError(f"timed out reading {self.label}")
        return remaining

    def _pump(self) -> None:
        while True:
            events = self.selector.select(self._remaining())
            if events:
                break
            if time.monotonic() >= self.deadline:
                raise DebError(f"timed out reading {self.label}")
        for key, _ in events:
            stream = key.fileobj
            try:
                chunk = os.read(stream.fileno(), PROCESS_READ_BYTES)
            except BlockingIOError:
                continue
            except OSError as exc:
                raise DebError(f"cannot drain {self.label} {key.data}") from exc
            if not chunk:
                self.selector.unregister(stream)
                stream.close()
                continue
            if key.data == "stdout":
                self.stdout_count += len(chunk)
                if self.stdout_count > self.stdout_limit:
                    raise DebError(
                        f"{self.label} expands beyond {self.stdout_limit} bytes"
                    )
                self.stdout_buffer.extend(chunk)
            else:
                self.stderr_buffer.extend(chunk)
                if len(self.stderr_buffer) > MAX_DPKG_STDERR_BYTES:
                    raise DebError(
                        f"{self.label} stderr exceeds {MAX_DPKG_STDERR_BYTES} bytes"
                    )

    def read(self, size: int = -1) -> bytes:
        if size == 0:
            return b""
        if size is None or size < 0:
            while self._stream_registered("stdout"):
                self._pump()
            result = bytes(self.stdout_buffer)
            self.stdout_buffer.clear()
            return result
        while len(self.stdout_buffer) < size and self._stream_registered("stdout"):
            self._pump()
        result = bytes(self.stdout_buffer[:size])
        del self.stdout_buffer[:size]
        return result

    def _stream_registered(self, name: str) -> bool:
        return any(key.data == name for key in self.selector.get_map().values())

    def _stderr_text(self) -> str:
        return bytes(self.stderr_buffer[:4096]).decode(errors="replace").strip()

    def finish(self) -> None:
        # Bytes already buffered count against the limit even when the caller
        # has finished parsing the logical stream.
        self.stdout_buffer.clear()
        while self.selector.get_map():
            self._pump()
        try:
            status = self.proc.wait(timeout=self._remaining())
        except subprocess.TimeoutExpired as exc:
            raise DebError(f"timed out waiting for {self.label}") from exc
        if status != 0:
            detail = self._stderr_text()
            suffix = f": {detail}" if detail else ""
            raise DebError(f"{self.label} failed with exit status {status}{suffix}")
        # A successful wrapper must not leave a pipe-closing daemon behind.
        # Once the group leader is reaped, a surviving group denotes an
        # unaccounted descendant and is rejected before returning success.
        try:
            os.killpg(self.proc.pid, 0)
        except ProcessLookupError:
            pass
        except OSError as exc:
            raise DebError(f"cannot account for {self.label} process group") from exc
        else:
            raise DebError(f"{self.label} left a descendant process")
        self.finished = True
        self.selector.close()

    def _abort(self) -> None:
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except OSError:
            pass
        for stream in (self.proc.stdout, self.proc.stderr):
            if stream is not None and not stream.closed:
                try:
                    stream.close()
                except OSError:
                    pass
        self.selector.close()
        try:
            self.proc.wait(timeout=PROCESS_REAP_SECONDS)
        except subprocess.TimeoutExpired:
            try:
                self.proc.kill()
                self.proc.wait(timeout=PROCESS_REAP_SECONDS)
            except (OSError, subprocess.TimeoutExpired):
                pass
        self.finished = True


def _ascii_decimal(raw: bytes, label: str, width: int) -> int:
    if len(raw) != width:
        raise DebError(f"invalid ar {label} width")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise DebError(f"ar {label} is not ASCII") from exc
    digits = text.rstrip(" ")
    if not digits or text != digits.ljust(width) or not digits.isdecimal():
        raise DebError(f"ar {label} is not canonical decimal")
    if len(digits) > 1 and digits.startswith("0"):
        raise DebError(f"ar {label} has a leading zero")
    return int(digits, 10)


def _ascii_octal(raw: bytes, label: str, width: int) -> int:
    if len(raw) != width:
        raise DebError(f"invalid ar {label} width")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise DebError(f"ar {label} is not ASCII") from exc
    digits = text.rstrip(" ")
    if not digits or text != digits.ljust(width) or any(c not in "01234567" for c in digits):
        raise DebError(f"ar {label} is not canonical octal")
    return int(digits, 8)


def _field(value: int, width: int) -> bytes:
    text = str(value).encode("ascii")
    if len(text) > width:
        raise DebError("ar numeric field is too wide")
    return text + b" " * (width - len(text))


def read_exact(handle, size: int, label: str) -> bytes:
    data = handle.read(size)
    if len(data) != size:
        raise DebError(f"truncated {label}")
    return data


def _open_deb(path: pathlib.Path) -> tuple[int, os.stat_result]:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow or not pathlib.Path("/proc/self/fd").is_dir():
        raise DebError("single-fd DEB verification requires Linux O_NOFOLLOW and procfs")
    flags = (
        os.O_RDONLY
        | nofollow
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise DebError(f"cannot securely open DEB: {path}") from exc
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise DebError("DEB must be a regular non-symlink file")
        if metadata.st_size <= len(AR_MAGIC) or metadata.st_size > MAX_DEB_BYTES:
            raise DebError(f"DEB size is outside 1..{MAX_DEB_BYTES} bytes")
        return fd, metadata
    except BaseException:
        os.close(fd)
        raise


def parse_ar(fd: int, metadata: os.stat_result) -> list[ArMember]:
    handle = _PreadHandle(fd, metadata.st_size)
    if read_exact(handle, len(AR_MAGIC), "ar magic") != AR_MAGIC:
        raise DebError("DEB lacks ar archive magic")
    members: list[ArMember] = []
    expected_prefix = ("debian-binary", "control.tar.", "data.tar.")
    for index in range(3):
        header = read_exact(handle, AR_HEADER_BYTES, f"ar header {index + 1}")
        if header[58:60] != AR_TRAILER:
            raise DebError("invalid ar member trailer")
        raw_name = header[0:16]
        try:
            name = raw_name.decode("ascii")
        except UnicodeDecodeError as exc:
            raise DebError("ar member name is not ASCII") from exc
        name = name.rstrip(" ")
        if name != name.strip() or name.endswith("/") or "/" in name:
            raise DebError(f"non-canonical ar member name: {name!r}")
        if not name.startswith(expected_prefix[index]):
            raise DebError(f"unexpected ar member {name!r}")
        if index == 0 and name != "debian-binary":
            raise DebError("first ar member must be debian-binary")
        if index in (1, 2) and not re.fullmatch(r"(?:control|data)\.tar\.(?:gz|xz|zst)", name):
            raise DebError(f"unsupported compressed ar member: {name!r}")
        mtime = _ascii_decimal(header[16:28], "mtime", 12)
        uid = _ascii_decimal(header[28:34], "uid", 6)
        gid = _ascii_decimal(header[34:40], "gid", 6)
        mode = _ascii_octal(header[40:48], "mode", 8)
        size = _ascii_decimal(header[48:58], "size", 10)
        if mtime < 0 or uid != 0 or gid != 0 or mode != 0o100644:
            raise DebError(f"unsafe ar metadata for {name}")
        if index == 0 and size != 4:
            raise DebError("debian-binary must be exactly four bytes")
        if index == 1 and not 1 <= size <= MAX_CONTROL_BYTES:
            raise DebError("control archive is outside size bound")
        if index == 2 and not 1 <= size <= MAX_DEB_BYTES:
            raise DebError("data archive is outside size bound")
        offset = handle.tell()
        end = offset + size
        if end > metadata.st_size:
            raise DebError(f"truncated ar member: {name}")
        members.append(ArMember(name, offset, size, mtime, uid, gid, mode))
        handle.seek(size, os.SEEK_CUR)
        if size & 1:
            if read_exact(handle, 1, "ar padding") != b"\n":
                raise DebError(f"invalid ar padding for {name}")
    if handle.read(1):
        raise DebError("ar archive contains extra members or trailing bytes")
    handle.seek(members[0].offset)
    debian_binary = read_exact(handle, 4, "debian-binary")
    if debian_binary != b"2.0\n":
        raise DebError("debian-binary payload must be exactly 2.0\\n")
    return members


def _dpkg_command(fd: int, *arguments: str) -> list[str]:
    return ["dpkg-deb", *arguments, f"/proc/self/fd/{fd}"]


def _dpkg_tar_bytes(fd: int, option: str, label: str, limit: int) -> bytes:
    with _BoundedProcess(
        _dpkg_command(fd, option),
        label,
        limit,
        pass_fds=(fd,),
    ) as output:
        result = output.read()
        output.finish()
        return result


def _normalize_path(raw: str, label: str) -> str:
    if not raw or "\x00" in raw or "\\" in raw or any(ord(char) < 0x20 or ord(char) == 0x7F for char in raw):
        raise DebError(f"unsafe {label} path: {raw!r}")
    if raw in (".", "./"):
        return ""
    if not raw.startswith("./"):
        raise DebError(f"{label} path must be relative: {raw!r}")
    name = raw[2:].rstrip("/")
    if not name:
        return ""
    encoded = name.encode("utf-8", "surrogateescape")
    if len(encoded) >= MAX_PATH_BYTES:
        raise DebError(f"overlong {label} path")
    parts = name.split("/")
    if any(not part or part in (".", "..") or len(part.encode("utf-8", "surrogateescape")) > MAX_COMPONENT_BYTES for part in parts):
        raise DebError(f"unsafe {label} path: {raw!r}")
    return name


ABSOLUTE_SYMLINKS: dict[tuple[str, str], str] = {
    (
        "y700-daily-kernel-modules",
        "usr/lib/modules/7.1.1-g5df8e852ea72/build",
    ): "/home/guf296/y700-daily/build",
    (
        "y700-daily-rootfs-overlay",
        "etc/systemd/system/smartmontools.service",
    ): "/dev/null",
    (
        "y700-daily-rootfs-overlay",
        "usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so",
    ): "/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so",
}


def _safe_link(member: str, target: str, package: str, hard: bool = False) -> bool:
    if not target or "\x00" in target or "\\" in target or any(ord(char) < 0x20 or ord(char) == 0x7F for char in target):
        return False
    if target.startswith("/"):
        return not hard and ABSOLUTE_SYMLINKS.get((package, member)) == target
    if ":" in target.split("/", 1)[0]:
        return False
    base = [] if hard else member.split("/")[:-1]
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not base:
                return False
            base.pop()
        else:
            base.append(part)
    return True


def _hash_fd(fd: int, expected_size: int) -> str:
    digest = hashlib.sha256()
    offset = 0
    while offset < expected_size:
        try:
            chunk = os.pread(fd, min(1024 * 1024, expected_size - offset), offset)
        except OSError as exc:
            raise DebError("cannot hash authenticated DEB fd") from exc
        if not chunk:
            raise DebError("authenticated DEB fd became truncated")
        digest.update(chunk)
        offset += len(chunk)
    if os.pread(fd, 1, expected_size):
        raise DebError("authenticated DEB fd grew while being hashed")
    return digest.hexdigest()


def _stage_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    """Return the mutable identity fields used for stage TOCTOU checks."""
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _stage_stat(dir_fd: int, name: str, label: str) -> os.stat_result:
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError as exc:
        raise DebError(f"cannot stat extracted member: {label}") from exc


def _hash_stage_fd(
    fd: int,
    expected_size: int,
    deadline: float,
    label: str,
    expected_identity: tuple[int, int, int, int, int, int, int],
) -> str:
    """Hash an already-open stage file and reject any fd identity mutation."""
    digest = hashlib.sha256()
    before = os.fstat(fd)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size != expected_size
        or _stage_identity(before) != expected_identity
    ):
        raise DebError(f"extracted file changed while being verified: {label}")
    while True:
        if time.monotonic() >= deadline:
            raise DebError("timed out verifying extracted DEB tree")
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    after = os.fstat(fd)
    if _stage_identity(after) != expected_identity:
        raise DebError(f"extracted file changed while being verified: {label}")
    return digest.hexdigest()


def _manifest_bytes(records: list[TreeRecord]) -> bytes:
    # JSON strings keep the record unambiguous while the path/link validators
    # above reject control characters.  Sorting makes the digest independent
    # of tar/directory enumeration order.
    lines = []
    for record in sorted(records, key=lambda item: item.path):
        lines.append(json.dumps(
            [record.path, record.kind, record.mode, record.size, record.value],
            ensure_ascii=True,
            separators=(",", ":"),
        ))
    return ("\n".join(lines) + "\n").encode("ascii")


def _manifest_sha256(records: list[TreeRecord]) -> str:
    return hashlib.sha256(_manifest_bytes(records)).hexdigest()


def _parse_control(raw: bytes, package: str) -> dict[str, str]:
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        members = archive.getmembers()
        contract = CONTRACTS[package]
        expected = contract.control_members
        names: list[str] = []
        blobs: dict[str, bytes] = {}
        for member in members:
            name = _normalize_path(member.name, "control tar member")
            if name in names:
                raise DebError(f"duplicate control tar member: {name}")
            names.append(name)
            if member.pax_headers or member.islnk() or member.issym() or not (member.isdir() or member.isreg()):
                raise DebError(f"unsafe control tar member: {member.name!r}")
            if member.uid != 0 or member.gid != 0:
                raise DebError(f"control tar member is not root-owned: {name}")
            if member.isdir():
                if name != "":
                    raise DebError(f"unexpected control directory: {name}")
                if member.mode & 0o7777 != 0o755:
                    raise DebError("control tar root directory has unsafe mode")
            else:
                if name not in expected or member.mode & 0o7777 != (0o644 if name == "control" else 0o755):
                    raise DebError(f"unexpected control member or mode: {name}")
                if member.size > MAX_MEMBER_BYTES:
                    raise DebError(f"control member is too large: {name}")
                source = archive.extractfile(member)
                if source is None:
                    raise DebError(f"cannot read control member: {name}")
                blobs[name] = source.read(MAX_MEMBER_BYTES + 1)
                if len(blobs[name]) > MAX_MEMBER_BYTES:
                    raise DebError(f"control member is too large: {name}")
        if set(names) != {"", *expected}:
            raise DebError(f"control member set mismatch for {package}")
    control = blobs.get("control")
    if control is None or b"\x00" in control or not control.endswith(b"\n"):
        raise DebError("control file has invalid bytes or termination")
    try:
        control_text = control.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        raise DebError("control file is not valid UTF-8") from exc
    if "\r" in control_text or "\n\n" in control_text:
        raise DebError("control file contains CR or multiple paragraphs")
    fields: dict[str, str] = {}
    current: str | None = None
    for line in control_text.splitlines():
        if line.startswith((" ", "\t")):
            if current is None:
                raise DebError("orphan control continuation line")
            fields[current] += "\n" + line[1:]
        elif re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*:.*", line):
            key, value = line.split(":", 1)
            if value.startswith(" "):
                value = value[1:]
            if key in fields:
                raise DebError(f"duplicate control field: {key}")
            fields[key] = value
            current = key
        else:
            raise DebError("malformed dpkg control output")
    expected_version = contract.version
    expected_arch = contract.architecture
    expected_depends = contract.depends
    if not PACKAGE_RE.fullmatch(package):
        raise DebError(f"invalid package contract name: {package}")
    if not VERSION_RE.fullmatch(expected_version):
        raise DebError(f"invalid package contract version: {expected_version}")
    if not ARCH_RE.fullmatch(expected_arch):
        raise DebError(f"invalid package contract architecture: {expected_arch}")
    if fields.get("Package") != package:
        raise DebError(f"Package field mismatch: {fields.get('Package')!r}")
    if fields.get("Version") != expected_version:
        raise DebError(f"Version field mismatch for {package}")
    if fields.get("Architecture") != expected_arch:
        raise DebError(f"Architecture field mismatch for {package}")
    if fields.get("Depends", "") != expected_depends:
        raise DebError(f"Depends field mismatch for {package}")
    unexpected = sorted(set(fields) - set(contract.control_fields))
    missing = sorted(set(contract.control_fields) - set(fields))
    if unexpected or missing:
        raise DebError(
            f"control field set mismatch for {package}: unexpected={unexpected!r} missing={missing!r}"
        )
    control_digest = hashlib.sha256(control).hexdigest()
    if contract.control_sha256 and control_digest != contract.control_sha256:
        raise DebError(
            f"control digest mismatch for {package}: expected {contract.control_sha256}, got {control_digest}"
        )
    return fields


def _verify_data(fd: int, package: str) -> list[TreeRecord]:
    seen: set[str] = set()
    records: list[TreeRecord] = []
    total = 0
    try:
        with _BoundedProcess(
            _dpkg_command(fd, "--fsys-tarfile"),
            "data archive",
            MAX_DATA_STREAM_BYTES,
            pass_fds=(fd,),
        ) as output:
            with tarfile.open(fileobj=output, mode="r|") as archive:
                for index, member in enumerate(archive):
                    if index >= MAX_DATA_MEMBERS:
                        raise DebError("data tar has too many members")
                    name = _normalize_path(member.name, "data tar member")
                    if name in seen:
                        raise DebError(f"duplicate data tar member: {name or '.'}")
                    seen.add(name)
                    if member.pax_headers or member.sparse is not None:
                        raise DebError(f"data tar contains PAX/sparse metadata: {member.name!r}")
                    if member.name.endswith("/") and not member.isdir():
                        raise DebError(f"non-directory data member has trailing slash: {member.name!r}")
                    if member.uid != 0 or member.gid != 0:
                        raise DebError(f"data tar member is not root-owned: {name or '.'}")
                    if member.isdir():
                        if member.mode & 0o7777 not in (0o755, 0o777):
                            raise DebError(f"data directory has unsafe mode: {name or '.'}")
                        records.append(TreeRecord(name, "d", member.mode & 0o7777, 0, ""))
                    elif member.isreg():
                        if member.mode & 0o7777 not in (0o644, 0o755, 0o777):
                            raise DebError(f"data file has unsafe mode: {name}")
                        if member.size < 0 or member.size > MAX_MEMBER_BYTES:
                            raise DebError(f"data file exceeds size bound: {name}")
                        total += member.size
                        if total > MAX_DATA_BYTES:
                            raise DebError("data tar expands beyond size bound")
                        source = archive.extractfile(member)
                        if source is None:
                            raise DebError(f"cannot read data member: {name}")
                        digest = hashlib.sha256()
                        remaining = member.size
                        while remaining:
                            chunk = source.read(min(1024 * 1024, remaining))
                            if not chunk:
                                raise DebError(f"truncated data member: {name}")
                            digest.update(chunk)
                            remaining -= len(chunk)
                        if source.read(1):
                            raise DebError(f"data member has unexpected trailing bytes: {name}")
                        records.append(TreeRecord(name, "f", member.mode & 0o7777, member.size, digest.hexdigest()))
                    elif member.issym():
                        if len(member.linkname.encode("utf-8", "surrogateescape")) > MAX_SYMLINK_BYTES or not _safe_link(name, member.linkname, package):
                            raise DebError(f"unsafe data symlink: {name} -> {member.linkname!r}")
                        records.append(TreeRecord(name, "l", member.mode & 0o7777, 0, member.linkname))
                    elif member.islnk():
                        raise DebError(f"hardlinks are forbidden in data tar: {name}")
                    else:
                        raise DebError(f"unsupported data tar member type: {name}")
            output.finish()
    except DebError:
        raise
    except (tarfile.TarError, EOFError, OSError) as exc:
        raise DebError("invalid data tar stream") from exc
    # A valid dpkg data stream contains one root directory entry.  Requiring
    # it explicitly prevents a stage created from an archive with a missing
    # root from being treated as equivalent to the fixed contract.
    if "" not in seen:
        raise DebError("data tar is missing its root directory entry")
    return records


def _verify_stage(stage: pathlib.Path, package: str, expected: list[TreeRecord]) -> list[TreeRecord]:
    deadline = time.monotonic() + STAGE_VERIFY_TIMEOUT_SECONDS
    try:
        stage_metadata = stage.lstat()
    except OSError as exc:
        raise DebError(f"cannot stat DEB extraction stage: {stage}") from exc
    if not stat.S_ISDIR(stage_metadata.st_mode):
        raise DebError("DEB extraction stage must be a real directory")
    # All descendants are opened relative to an authenticated directory fd.
    # Walking saved pathnames would allow a concurrent rename/symlink swap to
    # redirect the verifier between lstat(), recurse, and file hashing.
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if not nofollow or not directory:
        raise DebError("descriptor-relative stage verification requires no-follow directory opens")
    directory_flags = os.O_RDONLY | nofollow | directory | getattr(os, "O_CLOEXEC", 0)
    file_flags = os.O_RDONLY | nofollow | getattr(os, "O_CLOEXEC", 0)

    def list_names(fd: int, label: str) -> list[str]:
        try:
            names = [os.fsdecode(name) for name in os.listdir(fd)]
        except OSError as exc:
            raise DebError(f"cannot enumerate DEB extraction stage: {label}") from exc
        if len(names) != len(set(names)):
            raise DebError(f"extracted directory returned duplicate names: {label}")
        if len(names) + 1 > MAX_DATA_MEMBERS:
            raise DebError("extracted DEB tree has too many members")
        return sorted(names)

    def stat_at(fd: int, name: str, label: str) -> os.stat_result:
        try:
            return os.stat(name, dir_fd=fd, follow_symlinks=False)
        except OSError as exc:
            raise DebError(f"cannot stat extracted member: {label}") from exc

    def identity_changed(
        before: tuple[int, int, int, int, int, int, int],
        after: os.stat_result,
    ) -> bool:
        return before != _stage_identity(after)

    def close_fd(fd: int) -> None:
        try:
            os.close(fd)
        except OSError as exc:
            raise DebError("cannot close extracted stage directory") from exc

    # The extraction destination itself represents the tar root member ``.``.
    actual: list[TreeRecord] = []
    member_count = 1
    total = 0
    open_fds: set[int] = set()
    try:
        try:
            root_fd = os.open(stage, directory_flags)
        except OSError as exc:
            raise DebError("cannot securely open DEB extraction stage") from exc
        open_fds.add(root_fd)
        root_opened = os.fstat(root_fd)
        root_identity = _stage_identity(stage_metadata)
        if (
            not stat.S_ISDIR(root_opened.st_mode)
            or _stage_identity(root_opened) != root_identity
        ):
            raise DebError("DEB extraction stage root changed during verification")

        # A frame owns one open directory fd.  Its child frame is completed
        # before the parent entry is checked again, closing the rename window
        # around both directory enumeration and descendant processing.
        stack: list[dict[str, object]] = [{
            "fd": root_fd,
            "prefix": "",
            "identity": root_identity,
            "parent_fd": None,
            "parent_name": None,
            "parent_identity": None,
            "names": list_names(root_fd, "."),
            "index": 0,
            "entry_identities": {},
        }]
        while stack:
            if time.monotonic() >= deadline:
                raise DebError("timed out verifying extracted DEB tree")
            frame = stack[-1]
            fd = int(frame["fd"])
            prefix = str(frame["prefix"])
            names = frame["names"]
            index = int(frame["index"])
            if index < len(names):
                name = str(names[index])
                frame["index"] = index + 1
                if not name or "/" in name or "\\" in name or "\x00" in name:
                    raise DebError(f"unsafe extracted member name: {name!r}")
                relative = f"{prefix}/{name}" if prefix else name
                if len(relative.encode("utf-8", "surrogateescape")) >= MAX_PATH_BYTES:
                    raise DebError(f"overlong extracted member path: {relative}")
                member_count += 1
                if member_count > MAX_DATA_MEMBERS:
                    raise DebError("extracted DEB tree has too many members")
                metadata = stat_at(fd, name, relative)
                identity = _stage_identity(metadata)
                entry_identities = frame["entry_identities"]
                assert isinstance(entry_identities, dict)
                entry_identities[name] = identity
                mode = metadata.st_mode
                if stat.S_ISDIR(mode):
                    if metadata.st_nlink < 2 or metadata.st_mode & 0o7777 not in (0o755, 0o777):
                        raise DebError(f"unsafe extracted directory: {relative}")
                    try:
                        child_fd = os.open(name, directory_flags, dir_fd=fd)
                    except OSError as exc:
                        raise DebError(f"extracted directory changed while being verified: {relative}") from exc
                    open_fds.add(child_fd)
                    child_opened = os.fstat(child_fd)
                    if identity_changed(identity, child_opened):
                        raise DebError(f"extracted directory changed while being verified: {relative}")
                    actual.append(TreeRecord(relative, "d", metadata.st_mode & 0o7777, 0, ""))
                    stack.append({
                        "fd": child_fd,
                        "prefix": relative,
                        "identity": identity,
                        "parent_fd": fd,
                        "parent_name": name,
                        "parent_identity": identity,
                        "names": list_names(child_fd, relative),
                        "index": 0,
                        "entry_identities": {},
                    })
                    continue
                if stat.S_ISREG(mode):
                    if metadata.st_nlink != 1:
                        raise DebError(f"hard-linked extracted file: {relative}")
                    if metadata.st_mode & 0o7777 not in (0o644, 0o755, 0o777):
                        raise DebError(f"unsafe extracted file mode: {relative}")
                    if metadata.st_size < 0 or metadata.st_size > MAX_MEMBER_BYTES:
                        raise DebError(f"extracted file exceeds size bound: {relative}")
                    total += metadata.st_size
                    if total > MAX_DATA_BYTES:
                        raise DebError("extracted DEB tree exceeds aggregate size bound")
                    try:
                        file_fd = os.open(name, file_flags, dir_fd=fd)
                    except OSError as exc:
                        raise DebError(f"extracted file changed while being verified: {relative}") from exc
                    try:
                        opened = os.fstat(file_fd)
                        if identity_changed(identity, opened):
                            raise DebError(f"extracted file changed while being verified: {relative}")
                        digest = _hash_stage_fd(
                            file_fd,
                            metadata.st_size,
                            deadline,
                            relative,
                            identity,
                        )
                        named_after = stat_at(fd, name, relative)
                        if identity_changed(identity, named_after):
                            raise DebError(f"extracted file changed while being verified: {relative}")
                    finally:
                        close_fd(file_fd)
                    actual.append(TreeRecord(
                        relative,
                        "f",
                        metadata.st_mode & 0o7777,
                        metadata.st_size,
                        digest,
                    ))
                    continue
                if stat.S_ISLNK(mode):
                    try:
                        target = os.readlink(name, dir_fd=fd)
                    except OSError as exc:
                        raise DebError(f"cannot read extracted symlink: {relative}") from exc
                    if len(target.encode("utf-8", "surrogateescape")) > MAX_SYMLINK_BYTES or not _safe_link(relative, target, package):
                        raise DebError(f"unsafe extracted symlink: {relative} -> {target!r}")
                    named_after = stat_at(fd, name, relative)
                    if identity_changed(identity, named_after):
                        raise DebError(f"extracted symlink changed while being verified: {relative}")
                    actual.append(TreeRecord(relative, "l", metadata.st_mode & 0o7777, 0, target))
                    continue
                raise DebError(f"unsupported extracted member type: {relative}")

            # The frame has consumed its initial name snapshot.  Re-check the
            # directory fd and every name before accepting the frame.  This
            # catches additions/removals and descendant entry replacement that
            # occurred while a child was being processed.
            frame_identity = frame["identity"]
            assert isinstance(frame_identity, tuple)
            current_directory = os.fstat(fd)
            if identity_changed(frame_identity, current_directory):
                raise DebError(f"extracted directory changed while being verified: {prefix or '.'}")
            current_names = list_names(fd, prefix or ".")
            if current_names != names:
                raise DebError(f"extracted directory contents changed while being verified: {prefix or '.'}")
            entry_identities = frame["entry_identities"]
            assert isinstance(entry_identities, dict)
            for name, expected_identity in entry_identities.items():
                if time.monotonic() >= deadline:
                    raise DebError("timed out verifying extracted DEB tree")
                current = stat_at(fd, name, f"{prefix}/{name}" if prefix else name)
                if identity_changed(expected_identity, current):
                    raise DebError(
                        f"extracted member changed while being verified: "
                        f"{prefix}/{name}" if prefix else f"extracted member changed while being verified: {name}"
                    )
            parent_fd = frame["parent_fd"]
            parent_name = frame["parent_name"]
            parent_identity = frame["parent_identity"]
            close_fd(fd)
            open_fds.remove(fd)
            stack.pop()
            if parent_fd is not None:
                assert isinstance(parent_name, str)
                assert isinstance(parent_identity, tuple)
                parent_current = stat_at(parent_fd, parent_name, parent_name)
                if identity_changed(parent_identity, parent_current):
                    raise DebError(
                        f"extracted directory changed while being verified: {parent_name}"
                    )
        final_root = stage.lstat()
        if identity_changed(root_identity, final_root):
            raise DebError("DEB extraction stage root changed during verification")
        actual.insert(0, TreeRecord("", "d", root_opened.st_mode & 0o7777, 0, ""))
    finally:
        for fd in list(open_fds):
            try:
                os.close(fd)
            except OSError:
                pass
    expected_sorted = sorted(expected, key=lambda item: item.path)
    actual_sorted = sorted(actual, key=lambda item: item.path)
    if actual_sorted != expected_sorted:
        expected_map = {record.path: record for record in expected_sorted}
        actual_map = {record.path: record for record in actual_sorted}
        missing = sorted(set(expected_map) - set(actual_map))
        extra = sorted(set(actual_map) - set(expected_map))
        changed = sorted(
            path for path in set(expected_map) & set(actual_map)
            if expected_map[path] != actual_map[path]
        )
        raise DebError(
            "extracted DEB tree differs from data contract; "
            f"missing={missing[:4]!r} extra={extra[:4]!r} changed={changed[:4]!r}"
        )
    return actual_sorted


def _extract_data(fd: int, stage: pathlib.Path) -> None:
    try:
        before = stage.lstat()
    except OSError as exc:
        raise DebError(f"cannot stat DEB extraction destination: {stage}") from exc
    if not stat.S_ISDIR(before.st_mode):
        raise DebError("DEB extraction destination must be a real directory")
    try:
        with os.scandir(stage) as entries:
            if next(entries, None) is not None:
                raise DebError("DEB extraction destination must be empty")
    except OSError as exc:
        raise DebError(f"cannot inspect DEB extraction destination: {stage}") from exc
    command = [
        "dpkg-deb",
        "--extract",
        f"/proc/self/fd/{fd}",
        str(stage),
    ]
    with _BoundedProcess(
        command,
        "data extraction",
        MAX_EXTRACT_STDOUT_BYTES,
        pass_fds=(fd,),
    ) as output:
        stdout = output.read()
        output.finish()
    if stdout:
        raise DebError("dpkg-deb emitted unexpected extraction stdout")
    after = stage.lstat()
    if (
        not stat.S_ISDIR(after.st_mode)
        or (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
    ):
        raise DebError("DEB extraction destination changed during extraction")


def verify(
    path: pathlib.Path,
    package: str,
    stage: pathlib.Path | None = None,
    *,
    extract: bool = False,
) -> str:
    if package not in CONTRACTS:
        raise DebError(f"unsupported imported package contract: {package}")
    if extract and stage is None:
        raise DebError("DEB extraction requires a destination stage")
    contract = CONTRACTS[package]
    if contract.filename and path.name != contract.filename:
        raise DebError(
            f"DEB filename mismatch for {package}: expected {contract.filename}, got {path.name}"
        )
    fd, before = _open_deb(path)
    try:
        parse_ar(fd, before)
        digest = _hash_fd(fd, before.st_size)
        if contract.deb_sha256 and digest != contract.deb_sha256:
            raise DebError(
                f"DEB digest mismatch for {package}: expected {contract.deb_sha256}, got {digest}"
            )
        _parse_control(
            _dpkg_tar_bytes(fd, "--ctrl-tarfile", "control archive", MAX_CONTROL_BYTES),
            package,
        )
        expected = _verify_data(fd, package)
        data_digest = _manifest_sha256(expected)
        if contract.data_manifest_sha256 and data_digest != contract.data_manifest_sha256:
            raise DebError(
                f"data tree digest mismatch for {package}: expected {contract.data_manifest_sha256}, got {data_digest}"
            )
        if extract:
            assert stage is not None
            _extract_data(fd, stage)
        if stage is not None:
            _verify_stage(stage, package, expected)
        after = os.fstat(fd)
        final_digest = _hash_fd(fd, after.st_size)
        identity_before = (
            before.st_dev, before.st_ino, before.st_mode,
            before.st_size, before.st_mtime_ns,
        )
        identity_after = (
            after.st_dev, after.st_ino, after.st_mode,
            after.st_size, after.st_mtime_ns,
        )
        if identity_before != identity_after or final_digest != digest:
            raise DebError("authenticated DEB fd changed while it was being verified")
        return digest
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, choices=sorted(CONTRACTS))
    parser.add_argument("deb", type=pathlib.Path)
    stage_group = parser.add_mutually_exclusive_group()
    stage_group.add_argument("--stage", type=pathlib.Path)
    stage_group.add_argument("--extract", type=pathlib.Path)
    parser.add_argument("--print-sha256", action="store_true")
    args = parser.parse_args()
    termination_signals = (signal.SIGTERM, signal.SIGHUP)
    previous_handlers = {
        signum: signal.getsignal(signum) for signum in termination_signals
    }
    for signum in termination_signals:
        signal.signal(signum, _raise_termination)
    try:
        try:
            stage = args.extract if args.extract is not None else args.stage
            digest = verify(
                args.deb,
                args.package,
                stage,
                extract=args.extract is not None,
            )
        except (DebError, OSError, ValueError) as exc:
            print(f"DEB rejected: {exc}", file=os.sys.stderr)
            return 1
        except TerminationRequested as exc:
            print(f"DEB verification interrupted by signal {exc.signum}", file=os.sys.stderr)
            return 128 + exc.signum
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    if args.print_sha256:
        print(digest)
    else:
        print(f"DEB verified: {args.package}: {args.deb}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
