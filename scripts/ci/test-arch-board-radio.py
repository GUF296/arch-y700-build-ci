"""Offline normal-path fixtures; not a firmware/hardware test."""
import hashlib
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

P=Path(__file__).resolve().parent
M=runpy.run_path(str(P/"stage-arch-board-radio.py"))
sha=lambda data:hashlib.sha256(data).hexdigest()


class Radio(unittest.TestCase):
    def test_final_board_bytes_modes_and_paths(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);rel=M["RELEASE"];folder=root/"usr/lib/firmware/updates"/rel/"qca"
            folder.mkdir(parents=True)
            first=folder/"first";other=folder/"second";data=b"test-radio"
            spec=[("qca/first",len(data),sha(data)),("qca/second",len(data),sha(data))]
            def check(): M["verify_outputs"](root,rel,spec)
            for f in (first,other):f.write_bytes(data);f.chmod(0o644)
            check()
            first.unlink()
            with self.assertRaises(FileNotFoundError):check()
            first.write_bytes(b"x"*len(data));first.chmod(0o644)
            with self.assertRaisesRegex(ValueError,"digest differs"):check()
            first.write_bytes(data[:-1])
            with self.assertRaisesRegex(ValueError,"size"):check()
            first.write_bytes(data);first.chmod(0o600)
            with self.assertRaisesRegex(ValueError,"mode"):check()
            first.unlink();first.symlink_to(other.name)
            with self.assertRaisesRegex(ValueError,"type"):check()
            first.unlink();first.write_bytes(data);first.chmod(0o644)
            saved=folder.with_name("saved-qca");folder.rename(saved);folder.symlink_to(saved.name)
            with self.assertRaises(OSError):check()
            folder.unlink();saved.rename(folder);check()

    def test_final_api_selection(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);fw=root/"usr/lib/firmware";hw=Path(M["W"])
            rel=M["RELEASE"];digest=M["DAILY"]
            fw.mkdir(parents=True)
            M["verify_api1"](root,rel,digest)
            other=fw/"updates"/"unrelated-release"/hw/"firmware-2.bin"
            other.parent.mkdir(parents=True);other.touch()
            M["verify_api1"](root,rel,digest)
            for prefix in (Path("updates")/rel,Path("updates"),Path(rel),Path(".")):
                place=fw/prefix/hw;place.mkdir(parents=True)
                for suffix in ("",".zst",".xz"):
                    with self.subTest(prefix=prefix,suffix=suffix):
                        path=place/("firmware-2.bin"+suffix);path.touch()
                        with self.assertRaisesRegex(ValueError,"reassess the Arch firmware update"):
                            M["verify_api1"](root,rel,digest)
                        path.unlink()
            M["verify_api1"](root,rel,digest)
            with self.assertRaisesRegex(ValueError,"wrong kernel/source"):
                M["verify_api1"](root,"future",digest)

    def test_release_and_verified_source_only(self):
        path=Path("/no-such-test-root")
        self.assertFalse(M["stage"](path,"some-other-kernel",M["DAILY"]))
        self.assertFalse(M["stage"](path,M["RELEASE"],"0"*64))
        self.assertEqual(len(M["DIRECT"]),5)
        self.assertEqual([p[0] for p in M["ZSTD"]],[M["W"]+"amss.bin.zst",M["W"]+"m3.bin.zst"])

    def test_move_decode_and_keep_unrelated_names(self):
        with tempfile.TemporaryDirectory() as td:
            fw=Path(td)
            direct=fw/"qca/hmtnv20.b112";direct.parent.mkdir()
            direct.write_bytes(b"board-nvm")
            raw=b"test-radio-image"*24
            packed=subprocess.check_output(["/usr/bin/zstd","-q","-c"],input=raw)
            compressed=fw/(M["W"]+"amss.bin.zst");compressed.parent.mkdir(parents=True)
            compressed.write_bytes(packed)
            keep=fw/"qca/hmtnv20_Kirby_prc.bin";keep.write_bytes(b"other June selection")
            spec=[("qca/hmtnv20.b112",9,sha(direct.read_bytes()))]
            zs=[(M["W"]+"amss.bin.zst",len(packed),sha(packed),len(raw),sha(raw))]
            with self.assertRaisesRegex(ValueError,"wrong decompressed"):
                M["transform"](fw,spec,[(*zs[0][:-1],"0"*64)])
            self.assertTrue(direct.is_file() and compressed.is_file() and not (fw/"updates").exists())
            M["transform"](fw,spec,zs)
            upd=fw/"updates"/M["RELEASE"]
            self.assertEqual((upd/"qca/hmtnv20.b112").read_bytes(),b"board-nvm")
            self.assertEqual((upd/M["W"]/"amss.bin").read_bytes(),raw)
            self.assertEqual((upd/M["W"]/"amss.bin").stat().st_mode&0o7777,0o644)
            self.assertFalse(os.path.lexists(direct) or os.path.lexists(compressed))
            self.assertEqual(keep.read_bytes(),b"other June selection")
            with self.assertRaisesRegex(ValueError,"updates tree"):
                M["transform"](fw,spec,zs)


if __name__=="__main__":
    unittest.main()
