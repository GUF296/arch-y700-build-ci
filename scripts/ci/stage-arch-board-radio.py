"""Preserve the June TB321FU radio payload under the tested kernel's firmware override directory.

Invoked only on an isolated, already byte- and tree-verified DEB extraction. Arch's
linux-firmware package, the running system and its generic firmware names are never edited.
"""
from contextlib import ExitStack
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

RELEASE="7.1.1-g5df8e852ea72"
DAILY="9b45ab04d455cfcc24ed40779e9522930543330151c254e87a2aee7f381db5bc"
W="ath12k/WCN7850/hw2.0/"
# Source name, size and SHA-256. Only the two raw firmware images have to be
# decompressed: Linux searches all uncompressed candidates before trying .zst.
DIRECT=(
    (W+"board-2.bin",202148,"c896bc7782e252aa915849d5c9c47d109ecfe9f0fc5650fe771f7ba8f8eb77fb"),
    ("qca/hmtbtfw20.tlv",265528,"b4e7f61e7dd090e56811860a7781ff3b0ce8e87cc0480feaab34bf4f614308c5"),
    ("qca/hmtnv20.b10f",9540,"594885553fad67dfa4ea24f254f0760da284acc18dc9d190e175594651bbad1c"),
    ("qca/hmtnv20.b112",9540,"594885553fad67dfa4ea24f254f0760da284acc18dc9d190e175594651bbad1c"),
    ("qca/hmtnv20.bin",9492,"4e6f5fb6a17eaf219be1c2ce6c9f8829ea4d079ca28496c1729f7ee62b052c17"),
)
ZSTD=(
    (W+"amss.bin.zst",2879342,"8ee4da36cc820396a29f68d38632f47af7a2f6db142fa509a0091d542cb40e1f",
     6078528,"8bc1952148d73c98dd620921e435668ec205b2548f1edfb86f8b8452b0807007"),
    (W+"m3.bin.zst",150435,"603cb5f7a6d70ed23d6511038dfa9144c7992065d7c6c50d530985f4bacc5d10",
     299660,"ff40c57556c2fac552ac192c6e2ad59689fd8f50c9f9bcc997d13623c2bcee86"),
)


def need(ok,why):
    if not ok:
        raise ValueError(why)


def checked_file(p,size,digest):
    st=p.lstat()
    need(stat.S_ISREG(st.st_mode) and st.st_nlink==1 and st.st_size==size and p.parent.resolve(strict=True)==p.parent,
         "unexpected staged radio source type or size: "+p.name)
    data=p.read_bytes()
    need(len(data)==size and hashlib.sha256(data).hexdigest()==digest,"staged radio source differs: "+p.name)
    return data


def transform(fw,direct,compressed):
    updates=fw/"updates"
    need(fw.is_dir() and fw.resolve(strict=True)==fw and not os.path.lexists(updates),"unexpected staged firmware root or updates tree")
    # Refuse any inconsistent file before changing the input tree. All members
    # are public firmware and their entire compressed source is authenticated.
    with tempfile.TemporaryDirectory(prefix=".tb321fu-radio-",dir=fw) as work:
        private=Path(work)/"updates"
        for row in (*direct,*compressed):
            name,oldsize,oldhash=row[:3]
            data=checked_file(fw/name,oldsize,oldhash)
            if len(row)==5:
                need(name.endswith(".zst"),"not the expected compressed member")
                size,digest=row[3:]
                data=subprocess.run(["/usr/bin/zstd","-d","-q","--memory=32MB","-c"],input=data,
                                    capture_output=True,check=True,timeout=45).stdout
                need(len(data)==size and hashlib.sha256(data).hexdigest()==digest,"wrong decompressed radio member: "+name)
                name=name[:-4]
            dest=private/RELEASE/name
            dest.parent.mkdir(parents=True,exist_ok=True)
            with dest.open("xb") as f:
                f.write(data)
            dest.chmod(0o644)
        # mktemp's 0700 parent is outside the packaged directory. Package-visible
        # directories must be normal traversable firmware paths even with a strict umask.
        for p in [private,*(p for p in private.rglob("*") if p.is_dir())]:
            p.chmod(0o755)
        private.rename(updates)
    for row in (*direct,*compressed):
        (fw/row[0]).unlink()  # staged package only; Arch stock remains the owner of every generic path


def stage(root,release,source_sha):
    if (release,source_sha)!=(RELEASE,DAILY):
        return False
    need(root.is_dir() and not root.is_symlink(),"not a real DEB extraction root")
    transform(root.resolve(strict=True)/"usr/lib/firmware",DIRECT,ZSTD)
    return True


def verify_api1(root,release,source_sha):
    need((release,source_sha)==(RELEASE,DAILY),"wrong kernel/source at final radio check")
    need(stat.S_ISDIR(root.lstat().st_mode),"not a real final rootfs directory")
    root=root.resolve(strict=True)
    # ath12k tries firmware-2.bin first, including compressed forms, before it
    # falls back to the API1 amss/m3 names. Inspect the final root after all
    # packages and overlays; do not follow rootfs links into the build host.
    for prefix in (("updates",release),("updates",),(release,),()):
        p=root
        for component in ("usr","lib","firmware",*prefix,"ath12k","WCN7850","hw2.0"):
            p=p/component
            try:
                mode=p.lstat().st_mode
            except FileNotFoundError:
                if component in ("usr","lib","firmware"):
                    raise ValueError("missing final firmware root: "+component) from None
                break
            need(stat.S_ISDIR(mode),"unsupported final radio directory link or type: "+str(p.relative_to(root)))
        else:
            for suffix in ("",".zst",".xz"):
                path=p/("firmware-2.bin"+suffix)
                try:
                    path.lstat()
                except FileNotFoundError:
                    continue
                raise ValueError("new WCN7850 firmware API 2 candidate /"+str(path.relative_to(root))+
                                 "; reassess the Arch firmware update against the tested June API 1 radio profile")


def verify_outputs(root,release,expected):
    # Read only the pinned, public firmware paths. Anchor each open to its
    # already-open directory so an image symlink cannot redirect it elsewhere.
    dirs=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
    for name,size,digest in expected:
        components=("usr","lib","firmware","updates",release,*Path(name).parts)
        with ExitStack() as stack:
            parent=os.open(root,dirs);stack.callback(os.close,parent)
            for part in components[:-1]:
                parent=os.open(part,dirs,dir_fd=parent);stack.callback(os.close,parent)
            leaf=components[-1]
            st=os.stat(leaf,dir_fd=parent,follow_symlinks=False)
            need(stat.S_ISREG(st.st_mode) and stat.S_IMODE(st.st_mode)==0o644 and st.st_size==size,
                 "unexpected final radio file type, mode or size: "+name)
            fd=os.open(leaf,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW,dir_fd=parent)
            with os.fdopen(fd,"rb") as f:
                check=os.fstat(f.fileno())
                need((check.st_dev,check.st_ino,check.st_mode,check.st_size)==(st.st_dev,st.st_ino,st.st_mode,size),
                     "final radio file changed before reading: "+name)
                h=hashlib.sha256();remaining=size
                while remaining:
                    part=f.read(min(256*1024,remaining))
                    need(part,"short final radio file: "+name)
                    remaining-=len(part);h.update(part)
                need(not f.read(1) and h.hexdigest()==digest,"final radio digest differs: "+name)


if __name__=="__main__":
    if len(sys.argv)==5 and sys.argv[1]=="--final":
        verify_api1(Path(sys.argv[2]),sys.argv[3],sys.argv[4])
        verify_outputs(Path(sys.argv[2]),sys.argv[3],
                       (*DIRECT,*((path.removesuffix(".zst"),size,digest) for path,_,_,size,digest in ZSTD)))
    elif len(sys.argv)==4:
        if stage(Path(sys.argv[1]),sys.argv[2],sys.argv[3]):
            print(DAILY)  # the caller runs the final API-selection check only for a successfully staged match
    else:
        raise SystemExit("usage: stage-arch-board-radio.py [--final] ROOT KERNEL_RELEASE VERIFIED_DEB_SHA256")
