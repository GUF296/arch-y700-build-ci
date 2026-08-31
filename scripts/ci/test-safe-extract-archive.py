#!/usr/bin/env python3
"""Regression tests for extraction containment and resource budgets."""

from __future__ import annotations

import importlib.util
import io
import os
import pathlib
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile


def run(helper: pathlib.Path, archive: pathlib.Path, destination: pathlib.Path, **limits: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(limits)
    return subprocess.run(
        [sys.executable, str(helper), str(archive), str(destination)],
        check=False,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def require_rejected(result: subprocess.CompletedProcess[str], reason: str) -> None:
    if result.returncode == 0:
        raise SystemExit(f"unsafe archive was accepted: {reason}")


def require_preflight_rejected(helper: pathlib.Path, archive: pathlib.Path, reason: str) -> None:
    """Exercise the bounded validator without allowing ZipFile construction."""
    spec = importlib.util.spec_from_file_location("safe_extract_fixture", helper)
    if spec is None or spec.loader is None:
        raise SystemExit("unable to import safe extractor for preflight fixture")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.MAX_MEMBERS = 2
    try:
        with archive.open("rb") as handle:
            module.validate_zip_directory_budget(handle, archive.stat().st_size)
    except (ValueError, zipfile.BadZipFile):
        return
    raise SystemExit(f"unsafe archive passed ZIP preflight: {reason}")


def require_preflight_accepted(helper: pathlib.Path, archive: pathlib.Path, reason: str) -> None:
    spec = importlib.util.spec_from_file_location("safe_extract_fixture_accept", helper)
    if spec is None or spec.loader is None:
        raise SystemExit("unable to import safe extractor for ZIP64 fixture")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.MAX_MEMBERS = 2
    try:
        with archive.open("rb") as handle:
            module.validate_zip_directory_budget(handle, archive.stat().st_size)
    except (ValueError, zipfile.BadZipFile) as error:
        raise SystemExit(f"valid archive failed ZIP preflight ({reason}): {error}") from error


class ShortReadHandle(io.BytesIO):
    """Model a legal file read that returns fewer bytes than requested."""

    def read(self, size: int = -1) -> bytes:
        if size < 0:
            return super().read(size)
        return super().read(min(size, 3))


def main() -> None:
    helper = pathlib.Path(__file__).with_name("safe-extract-archive.py")
    helper_source = helper.read_text()
    if "for member in handle:" not in helper_source or "handle.getmembers()" in helper_source:
        raise SystemExit("tar validation must stream headers before enforcing MAX_MEMBERS")
    if helper_source.index(
        "validate_zip_directory_budget(archive_file, archive_bytes)"
    ) > helper_source.index(
        "with zipfile.ZipFile(archive_file)"
    ):
        raise SystemExit("ZIP metadata budget is checked after ZipFile construction")
    if "os.open(archive_input, flags)" not in helper_source or "O_NOFOLLOW" not in helper_source:
        raise SystemExit("archive extraction is not bound to one non-following descriptor")
    with tempfile.TemporaryDirectory(prefix="tb321fu-extract-test.") as raw:
        root = pathlib.Path(raw)

        good = root / "good.zip"
        with zipfile.ZipFile(good, "w") as archive:
            archive.writestr("payload/file.txt", "known-good\n")
        good_bytes = good.read_bytes()
        spec = importlib.util.spec_from_file_location("safe_extract_short_read", helper)
        if spec is None or spec.loader is None:
            raise SystemExit("unable to import safe extractor for short-read fixture")
        short_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(short_module)
        short_handle = ShortReadHandle(good_bytes)
        short_offset = short_module._find_zip_eocd(short_handle, len(good_bytes))
        if short_offset <= 0:
            raise SystemExit("short-read EOCD search returned an invalid offset")
        if short_module._read_at(short_handle, len(good_bytes), short_offset, 4) != b"PK\x05\x06":
            raise SystemExit("short-read metadata read returned the wrong bytes")
        (
            _signature,
            _disk_number,
            _directory_disk,
            _entries_this_disk,
            entries_total,
            directory_size,
            directory_offset,
            _comment_size,
        ) = struct.unpack_from("<4sHHHHIIH", good_bytes, short_offset)
        short_module._count_zip_central_directory(
            short_handle,
            len(good_bytes),
            directory_offset,
            directory_size,
            entries_total,
        )
        result = run(helper, good, root / "good-out")
        if result.returncode != 0:
            raise SystemExit(result.stderr)
        if (root / "good-out/payload/file.txt").read_text() != "known-good\n":
            raise SystemExit("valid ZIP payload changed")

        # A pathname replacement after O_NOFOLLOW open must not change the
        # inode consumed by format preflight or extraction.
        swap_original = root / "swap.zip"
        swap_replacement = root / "swap-replacement.zip"
        with zipfile.ZipFile(swap_original, "w") as archive:
            archive.writestr("payload/identity.txt", "opened inode\n")
        with zipfile.ZipFile(swap_replacement, "w") as archive:
            archive.writestr("payload/identity.txt", "replacement path\n")
        spec = importlib.util.spec_from_file_location("safe_extract_path_swap", helper)
        if spec is None or spec.loader is None:
            raise SystemExit("unable to import safe extractor for path-swap fixture")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real_open = module.os.open
        swapped = False

        def swap_after_open(path, flags, *args):
            nonlocal swapped
            descriptor = real_open(path, flags, *args)
            if pathlib.Path(path) == swap_original:
                os.replace(swap_replacement, swap_original)
                swapped = True
            return descriptor

        old_argv = module.sys.argv
        module.os.open = swap_after_open
        module.sys.argv = [str(helper), str(swap_original), str(root / "swap-out")]
        try:
            if module.main() != 0:
                raise SystemExit("path-swap fixture did not complete")
        finally:
            module.os.open = real_open
            module.sys.argv = old_argv
        if not swapped:
            raise SystemExit("path-swap fixture did not replace the archive pathname")
        if (root / "swap-out/payload/identity.txt").read_text() != "opened inode\n":
            raise SystemExit("archive pathname replacement changed extracted bytes")

        tar_swap_original = root / "swap.tar"
        tar_swap_replacement = root / "swap-replacement.tar"
        for path, payload in (
            (tar_swap_original, b"opened tar inode\n"),
            (tar_swap_replacement, b"replacement tar path\n"),
        ):
            with tarfile.open(path, "w") as archive:
                info = tarfile.TarInfo("payload/identity.txt")
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
        tar_swapped = False

        def swap_tar_after_open(path, flags, *args):
            nonlocal tar_swapped
            descriptor = real_open(path, flags, *args)
            if pathlib.Path(path) == tar_swap_original:
                os.replace(tar_swap_replacement, tar_swap_original)
                tar_swapped = True
            return descriptor

        module.os.open = swap_tar_after_open
        module.sys.argv = [str(helper), str(tar_swap_original), str(root / "tar-swap-out")]
        try:
            if module.main() != 0:
                raise SystemExit("tar path-swap fixture did not complete")
        finally:
            module.os.open = real_open
            module.sys.argv = old_argv
        if not tar_swapped:
            raise SystemExit("tar path-swap fixture did not replace the archive pathname")
        if (root / "tar-swap-out/payload/identity.txt").read_text() != "opened tar inode\n":
            raise SystemExit("tar pathname replacement changed extracted bytes")

        destination_link = root / "destination-link"
        destination_link.symlink_to(root / "outside-destination", target_is_directory=True)
        require_rejected(
            run(helper, good, destination_link),
            "destination root symlink",
        )
        if (root / "outside-destination").exists():
            raise SystemExit("destination symlink was followed")

        outside = root / "outside"
        outside.mkdir()
        destination = root / "symlink-out"
        destination.mkdir()
        (destination / "escape").symlink_to(outside, target_is_directory=True)
        hostile = root / "hostile-parent.zip"
        with zipfile.ZipFile(hostile, "w") as archive:
            archive.writestr("escape/created/file.txt", "must-not-exist")
        require_rejected(run(helper, hostile, destination), "pre-existing escaping symlink")
        if (outside / "created").exists():
            raise SystemExit("extractor created an external directory before containment validation")

        symlink_target_out = root / "symlink-target-out"
        symlink_target_out.mkdir()
        symlink_target_escape = symlink_target_out / "escape"
        symlink_target_escape.mkdir()
        symlink_target_destination = root / "symlink-target-destination"
        symlink_target_destination.mkdir()
        (symlink_target_destination / "escape").symlink_to(
            symlink_target_escape,
            target_is_directory=True,
        )
        symlink_target_archive = root / "hostile-link-target.zip"
        with zipfile.ZipFile(symlink_target_archive, "w") as archive:
            info = zipfile.ZipInfo("link")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            archive.writestr(info, "escape/created")
        require_rejected(
            run(helper, symlink_target_archive, symlink_target_destination),
            "ZIP symlink target through a pre-existing escaping symlink",
        )
        if (symlink_target_escape / "created").exists() or (
            symlink_target_destination / "link"
        ).is_symlink():
            raise SystemExit("ZIP symlink target escaped through a pre-existing symlink")

        outside_alias = root / "outside-alias.txt"
        outside_alias.write_text("outside must remain unchanged\n")
        zip_alias_out = root / "zip-alias-out"
        (zip_alias_out / "payload").mkdir(parents=True)
        os.link(outside_alias, zip_alias_out / "payload/file.txt")
        require_rejected(
            run(helper, good, zip_alias_out),
            "pre-existing ZIP destination hardlink alias",
        )
        if outside_alias.read_text() != "outside must remain unchanged\n":
            raise SystemExit("ZIP extraction modified a pre-existing hardlink alias")

        control_name = root / "control-name.zip"
        with zipfile.ZipFile(control_name, "w") as archive:
            archive.writestr("safe\nINJECTED=value", "must-not-be-exported")
        require_rejected(
            run(helper, control_name, root / "control-name-out"),
            "archive member control character",
        )

        control_target = root / "control-target.zip"
        with zipfile.ZipFile(control_target, "w") as archive:
            info = zipfile.ZipInfo("safe-link")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            archive.writestr(info, "target\r\n")
        require_rejected(
            run(helper, control_target, root / "control-target-out"),
            "archive link target control character",
        )

        many = root / "many.zip"
        with zipfile.ZipFile(many, "w") as archive:
            for index in range(3):
                archive.writestr(f"{index}.txt", "x")
        require_rejected(
            run(helper, many, root / "many-out", SAFE_EXTRACT_MAX_MEMBERS="2"),
            "member limit",
        )

        many_tar = root / "many.tar"
        with tarfile.open(many_tar, "w") as archive:
            for index in range(3):
                info = tarfile.TarInfo(f"member-{index}")
                info.size = 1
                archive.addfile(info, io.BytesIO(b"x"))
        require_rejected(
            run(helper, many_tar, root / "many-tar-out", SAFE_EXTRACT_MAX_MEMBERS="2"),
            "streamed tar member limit",
        )

        bounded_longname = root / "bounded-gnu-longname.tar"
        bounded_name = "payload/" + "x" * 120
        with tarfile.open(bounded_longname, "w", format=tarfile.GNU_FORMAT) as archive:
            info = tarfile.TarInfo(bounded_name)
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
        bounded_result = run(helper, bounded_longname, root / "bounded-gnu-longname-out")
        if bounded_result.returncode != 0:
            raise SystemExit(
                "bounded GNU longname fixture failed: " + bounded_result.stderr
            )
        if (root / "bounded-gnu-longname-out" / bounded_name).read_bytes() != b"x":
            raise SystemExit("bounded GNU longname payload changed")
        oversized_extension_result = run(
            helper,
            bounded_longname,
            root / "oversized-gnu-extension-out",
            SAFE_EXTRACT_MAX_EXTENSION_BYTES="64",
        )
        require_rejected(
            oversized_extension_result, "oversized GNU longname extension record"
        )
        if "extension record exceeds" not in oversized_extension_result.stderr:
            raise SystemExit(
                "oversized GNU extension was not rejected before expansion: "
                + oversized_extension_result.stderr
            )

        oversized_component = root / "oversized-component.tar"
        with tarfile.open(oversized_component, "w", format=tarfile.GNU_FORMAT) as archive:
            info = tarfile.TarInfo("payload/" + "x" * 256)
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
        require_rejected(
            run(helper, oversized_component, root / "oversized-component-out"),
            "TAR path component byte limit",
        )

        oversized_link = root / "oversized-link-target.tar"
        with tarfile.open(oversized_link, "w", format=tarfile.GNU_FORMAT) as archive:
            info = tarfile.TarInfo("payload/link")
            info.type = tarfile.SYMTYPE
            info.linkname = "x" * 4097
            archive.addfile(info)
        require_rejected(
            run(helper, oversized_link, root / "oversized-link-target-out"),
            "TAR link target byte limit",
        )

        overdeep_link = root / "overdeep-link-target.tar"
        with tarfile.open(overdeep_link, "w", format=tarfile.GNU_FORMAT) as archive:
            info = tarfile.TarInfo("/".join(["d"] * 127 + ["link"]))
            info.type = tarfile.SYMTYPE
            info.linkname = "target/child"
            archive.addfile(info)
        require_rejected(
            run(helper, overdeep_link, root / "overdeep-link-target-out"),
            "combined TAR link path depth",
        )

        compatible_pax = root / "compatible-pax.tar"
        with tarfile.open(compatible_pax, "w", format=tarfile.PAX_FORMAT) as archive:
            info = tarfile.TarInfo("payload/pax-file")
            info.size = 1
            info.pax_headers = {"comment": "bounded metadata"}
            archive.addfile(info, io.BytesIO(b"p"))
        pax_result = run(helper, compatible_pax, root / "compatible-pax-out")
        if pax_result.returncode != 0:
            raise SystemExit("bounded compatible PAX fixture failed: " + pax_result.stderr)
        if (root / "compatible-pax-out/payload/pax-file").read_bytes() != b"p":
            raise SystemExit("bounded PAX payload changed")

        old_sparse = root / "old-gnu-sparse.tar"
        sparse = tarfile.TarInfo("payload/sparse")
        sparse.type = tarfile.GNUTYPE_SPARSE
        sparse.size = 1
        sparse._sparse_structs = ([(0, 1)], False, 1)
        with tarfile.open(old_sparse, "w", format=tarfile.GNU_FORMAT) as archive:
            archive.addfile(sparse, io.BytesIO(b"s"))
        require_rejected(
            run(helper, old_sparse, root / "old-gnu-sparse-out"),
            "GNU sparse extension",
        )

        pax_sparse = root / "pax-sparse.tar"
        with tarfile.open(pax_sparse, "w", format=tarfile.PAX_FORMAT) as archive:
            info = tarfile.TarInfo("payload/pax-sparse")
            info.size = 1
            info.pax_headers = {"GNU.sparse.map": "0,1"}
            archive.addfile(info, io.BytesIO(b"s"))
        require_rejected(
            run(helper, pax_sparse, root / "pax-sparse-out"),
            "PAX sparse metadata",
        )

        compressed_cap = root / "compressed-cap.zip"
        with zipfile.ZipFile(compressed_cap, "w") as archive:
            archive.writestr("payload", "x")
        require_rejected(
            run(
                helper,
                compressed_cap,
                root / "compressed-cap-out",
                SAFE_EXTRACT_MAX_ARCHIVE_BYTES="1",
            ),
            "compressed archive byte limit",
        )

        # A tiny archive whose EOCD claims an oversized entry count must be
        # rejected by the bounded preflight before ZipFile builds its member
        # table.  This keeps the test small while exercising the hostile
        # central-directory boundary.
        declared_many = root / "declared-many.zip"
        with zipfile.ZipFile(declared_many, "w") as archive:
            archive.writestr("one.txt", "x")
        encoded = bytearray(declared_many.read_bytes())
        end = encoded.rfind(b"PK\x05\x06")
        if end < 0:
            raise SystemExit("test ZIP has no EOCD")
        encoded[end + 10 : end + 12] = (3).to_bytes(2, "little")
        declared_many.write_bytes(encoded)
        require_rejected(
            run(
                helper,
                declared_many,
                root / "declared-many-out",
                SAFE_EXTRACT_MAX_MEMBERS="2",
            ),
            "preflight central-directory member count",
        )

        # A forged final EOCD can point at a second central directory while
        # claiming a small member count.  The old rfind/count-only preflight
        # accepted this and ZipFile then materialized all ten records.
        forged_eocd = root / "forged-eocd.zip"
        with zipfile.ZipFile(forged_eocd, "w") as archive:
            for index in range(10):
                archive.writestr(f"member-{index}.txt", "x")
        encoded = bytearray(forged_eocd.read_bytes())
        end = encoded.rfind(b"PK\x05\x06")
        if end < 0:
            raise SystemExit("forged-EOCD fixture has no original EOCD")
        directory_size = int.from_bytes(encoded[end + 12 : end + 16], "little")
        directory_offset = int.from_bytes(encoded[end + 16 : end + 20], "little")
        central = encoded[directory_offset : directory_offset + directory_size]
        forged = bytearray(encoded[end : end + 22])
        forged[8:10] = (1).to_bytes(2, "little")
        forged[10:12] = (1).to_bytes(2, "little")
        forged_eocd.write_bytes(encoded + central + forged)
        with zipfile.ZipFile(forged_eocd) as archive:
            if len(archive.infolist()) != 10:
                raise SystemExit("forged EOCD fixture did not expose the hidden records")
        require_preflight_rejected(
            helper,
            forged_eocd,
            "forged final EOCD count before ZipFile materialization",
        )

        # A central-directory signature in the EOCD comment creates two
        # EOF-plausible records.  Treat the archive as ambiguous instead of
        # allowing the last byte pattern to select attacker-controlled fields.
        ambiguous_comment = root / "ambiguous-eocd-comment.zip"
        fake_comment_eocd = bytearray(22)
        fake_comment_eocd[:4] = b"PK\x05\x06"
        with zipfile.ZipFile(ambiguous_comment, "w") as archive:
            archive.writestr("payload", "x")
            archive.comment = bytes(fake_comment_eocd)
        require_preflight_rejected(
            helper,
            ambiguous_comment,
            "ambiguous EOCD signature in archive comment",
        )

        # Validate the ZIP64 path without allocating a multi-gigabyte archive:
        # reuse a tiny local/central payload and replace its classic tail with
        # a standards-compliant ZIP64 EOCD + locator + saturated EOCD.
        zip64 = root / "minimal-zip64.zip"
        with zipfile.ZipFile(root / "zip64-source.zip", "w") as archive:
            archive.writestr("payload", "x")
        source = (root / "zip64-source.zip").read_bytes()
        source_end = source.rfind(b"PK\x05\x06")
        source_size = int.from_bytes(source[source_end + 12 : source_end + 16], "little")
        source_offset = int.from_bytes(source[source_end + 16 : source_end + 20], "little")
        payload = source[:source_end]
        zip64_offset = len(payload)
        zip64_record = struct.pack(
            "<4sQHHIIQQQQ",
            b"PK\x06\x06",
            44,
            45,
            45,
            0,
            0,
            1,
            1,
            source_size,
            source_offset,
        )
        locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, zip64_offset, 1)
        saturated_eocd = struct.pack(
            "<4sHHHHIIH",
            b"PK\x05\x06",
            0,
            0,
            0xFFFF,
            0xFFFF,
            0xFFFFFFFF,
            0xFFFFFFFF,
            0,
        )
        zip64.write_bytes(payload + zip64_record + locator + saturated_eocd)
        require_preflight_accepted(
            helper,
            zip64,
            "minimal ZIP64 fixture",
        )
        zip64_result = run(helper, zip64, root / "zip64-out")
        if zip64_result.returncode != 0:
            raise SystemExit(
                f"valid ZIP64 archive failed full extraction: {zip64_result.stderr}"
            )
        if (root / "zip64-out/payload").read_text() != "x":
            raise SystemExit("valid ZIP64 payload changed during extraction")

        # Prefixes are legal for self-extracting ZIPs.  Verify both the classic
        # offset adjustment and the fixed-size ZIP64 fallback used by the
        # standard-library extractor.
        prefixed = root / "prefixed.zip"
        prefixed.write_bytes(b"TB321FU-STUB\0" + good_bytes)
        require_preflight_accepted(helper, prefixed, "prefixed classic ZIP")
        prefixed_result = run(helper, prefixed, root / "prefixed-out")
        if prefixed_result.returncode != 0:
            raise SystemExit(
                f"valid prefixed ZIP failed full extraction: {prefixed_result.stderr}"
            )
        if (root / "prefixed-out/payload/file.txt").read_text() != "known-good\n":
            raise SystemExit("valid prefixed ZIP payload changed during extraction")

        prefixed_zip64 = root / "prefixed-zip64.zip"
        prefix = b"TB321FU-ZIP64-STUB\0"
        prefixed_payload = prefix + payload
        prefixed_zip64_record = struct.pack(
            "<4sQHHIIQQQQ",
            b"PK\x06\x06",
            44,
            45,
            45,
            0,
            0,
            1,
            1,
            source_size,
            source_offset,
        )
        prefixed_zip64_locator = struct.pack(
            "<4sIQI", b"PK\x06\x07", 0, zip64_offset, 1
        )
        prefixed_zip64.write_bytes(
            prefixed_payload
            + prefixed_zip64_record
            + prefixed_zip64_locator
            + saturated_eocd
        )
        require_preflight_accepted(helper, prefixed_zip64, "prefixed fixed ZIP64")
        prefixed_zip64_result = run(
            helper, prefixed_zip64, root / "prefixed-zip64-out"
        )
        if prefixed_zip64_result.returncode != 0:
            raise SystemExit(
                "valid prefixed ZIP64 failed full extraction: "
                f"{prefixed_zip64_result.stderr}"
            )
        if (root / "prefixed-zip64-out/payload").read_text() != "x":
            raise SystemExit("valid prefixed ZIP64 payload changed during extraction")

        # CPython cannot resolve an extensible ZIP64 record when a prefix shifts
        # the locator's logical offset.  Reject it during preflight instead of
        # reporting success and failing later in ZipFile construction.
        prefixed_extensible = root / "prefixed-extensible-zip64.zip"
        prefixed_extensible_record = struct.pack(
            "<4sQHHIIQQQQ",
            b"PK\x06\x06",
            52,
            45,
            45,
            0,
            0,
            1,
            1,
            source_size,
            source_offset,
        ) + b"EXTEND!!"
        prefixed_extensible.write_bytes(
            prefixed_payload
            + prefixed_extensible_record
            + prefixed_zip64_locator
            + saturated_eocd
        )
        require_preflight_rejected(
            helper,
            prefixed_extensible,
            "unsupported prefixed extensible ZIP64",
        )

        require_rejected(
            run(
                helper,
                good,
                root / "archive-bytes-out",
                SAFE_EXTRACT_MAX_ARCHIVE_BYTES=str(good.stat().st_size - 1),
            ),
            "compressed archive byte limit",
        )
        forged_zip64 = root / "forged-zip64-count.zip"
        forged_zip64_bytes = bytearray(zip64.read_bytes())
        forged_zip64_bytes[zip64_offset + 24 : zip64_offset + 32] = (3).to_bytes(8, "little")
        forged_zip64_bytes[zip64_offset + 32 : zip64_offset + 40] = (3).to_bytes(8, "little")
        forged_zip64.write_bytes(forged_zip64_bytes)
        require_preflight_rejected(
            helper,
            forged_zip64,
            "forged ZIP64 member count",
        )
        malformed_zip64 = root / "malformed-zip64-size.zip"
        malformed_zip64_bytes = bytearray(zip64.read_bytes())
        malformed_zip64_bytes[zip64_offset + 4 : zip64_offset + 12] = (2**64 - 1).to_bytes(
            8, "little"
        )
        malformed_zip64.write_bytes(malformed_zip64_bytes)
        require_preflight_rejected(
            helper,
            malformed_zip64,
            "oversized ZIP64 record must be bounded before reading",
        )

        hardlinks = root / "hardlinks.tar"
        with tarfile.open(hardlinks, "w") as archive:
            data = b"canonical\n"
            regular = tarfile.TarInfo("payload/original")
            regular.size = len(data)
            archive.addfile(regular, io.BytesIO(data))
            first = tarfile.TarInfo("payload/first-link")
            first.type = tarfile.LNKTYPE
            first.linkname = "payload/original"
            archive.addfile(first)
            second = tarfile.TarInfo("payload/second-link")
            second.type = tarfile.LNKTYPE
            second.linkname = "payload/first-link"
            archive.addfile(second)
        require_rejected(
            run(helper, hardlinks, root / "hardlinks-out"),
            "contained tar hardlink chain",
        )

        tar_alias = root / "alias.tar"
        with tarfile.open(tar_alias, "w") as archive:
            data = b"archive replacement\n"
            member = tarfile.TarInfo("payload/file.txt")
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        tar_alias_out = root / "tar-alias-out"
        (tar_alias_out / "payload").mkdir(parents=True)
        os.link(outside_alias, tar_alias_out / "payload/file.txt")
        require_rejected(
            run(helper, tar_alias, tar_alias_out),
            "pre-existing tar destination hardlink alias",
        )
        if outside_alias.read_text() != "outside must remain unchanged\n":
            raise SystemExit("tar extraction modified a pre-existing hardlink alias")

        large_tar = root / "large.tar"
        with tarfile.open(large_tar, "w") as archive:
            data = b"x" * 32
            info = tarfile.TarInfo("large.bin")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        require_rejected(
            run(
                helper,
                large_tar,
                root / "large-out",
                SAFE_EXTRACT_MAX_FILE_BYTES="16",
                SAFE_EXTRACT_MAX_TOTAL_BYTES="16",
            ),
            "tar file/total size limit",
        )

        # Tar extraction must reject traversal before writing anywhere outside
        # the destination, just like the ZIP path. This models the base Arch
        # rootfs input now routed through ci_extract_archive.
        traversal_tar = root / "traversal.tar"
        with tarfile.open(traversal_tar, "w") as archive:
            data = b"must-not-escape"
            info = tarfile.TarInfo("../outside.txt")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        require_rejected(
            run(helper, traversal_tar, root / "traversal-out"),
            "tar parent traversal",
        )
        if (root / "outside.txt").exists():
            raise SystemExit("tar traversal wrote outside the extraction root")

        ratio = root / "ratio.zip"
        with zipfile.ZipFile(ratio, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("zeros.bin", bytes(1024 * 1024))
        require_rejected(
            run(helper, ratio, root / "ratio-out", SAFE_EXTRACT_MAX_COMPRESSION_RATIO="2"),
            "compression ratio limit",
        )

    print("safe archive extraction regressions: PASS")


if __name__ == "__main__":
    main()
