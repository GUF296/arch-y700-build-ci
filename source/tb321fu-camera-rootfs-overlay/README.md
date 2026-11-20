# Y700 Camera Rootfs Overlay

This overlay captures the Lenovo Y700 TB321FU daily camera stack verified on Ubuntu 26.04. It includes the known-good `/opt/libcamera-y700` app-chain, PipeWire SPA plugin, IPA/tuning files, PipeWire/WirePlumber environment drop-ins, and DMA heap udev rule restored from the 2026-06-22 live rootfs backup.

## Install Into A Mounted Rootfs

This manual entry installs the unchanged **historical recovery baseline**, not
the source-built remediation profile used by the default Arch image builder.

```sh
sudo ./install.sh /path/to/rootfs
```

Use `/` as the target only when intentionally applying it to a live system.
Python 3 is required. Keep `tools/` and `OVERLAY-MANIFEST.tsv` with this directory;
the directory remains independently copyable and does not require a parent
repository checkout. The bundled verifier authenticates all 56 payload entries
before a descriptor-relative snapshot and same-filesystem journaled install.
Failures restore replaced files, directory modes and the same legacy entries
removed by the old installer. Extra members, changed modes/hashes, hard links
and target symlink parents are rejected before unsafe writes.

This is the explicit manual overlay/recovery entry. The normal Arch image
builder keeps its pacman-owned camera package path, but now materializes the
source-built `remediation-profile/` over a verified private copy of this baseline
before the existing Arch path adaptation and native package assembly. Only
eight approved compiled/signature files are replaced; baseline tuning, services,
wrappers and links are not rewritten during materialization. Explicit
`CAMERA_STACK_ARCHIVE` / `CAMERA_STACK_DIR` historical overrides retain their
old contract and are recorded as `baseline-override`, not remediation delivery.

## Contents

- `rootfs-overlay/opt/libcamera-y700`: verified libcamera app-chain, IPA proxy, SoftISP IPA, and Y700 tuning files.
- `rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so`: verified `spa-libcamera` plugin, SHA256 `25e951d022816b999f51d85e285f548b79d865db0c3959019bcc08981261665c`.
- `rootfs-overlay/etc/systemd/user/pipewire.service.d`: PipeWire namespace and libcamera path drop-ins.
- `rootfs-overlay/etc/systemd/user/wireplumber.service.d`: WirePlumber libcamera path drop-in.
- `rootfs-overlay/etc/udev/rules.d/70-y700-camera-dma-heap.rules`: DMA heap access for camera users.
- `source/libcamera-source.cpp.clean-minimal-daily`: the same effective SPA source as the verified Ubuntu producer. The remediation profile rejects a mismatch with this file; the historical recovery binary remains unchanged.
- `remediation-profile/`: closed archive of eight source-built replacements plus exact package, source and build provenance. It contains no source/build tree or signing private key.
- `tools/`: bundled baseline manifest verifier and rollback-capable installer retained for standalone recovery.
- `OVERLAY-MANIFEST.tsv`: closed path/type/mode/size/hash/link contract for the unchanged runtime payload.
- `source/y700-camera-daily-minimal-upstream-1.6.2.patch`: minimal patch against upstream PipeWire 1.6.2.

## Remediation Runtime Model

- Applies only to Y700 built-in cameras detected by libcamera IDs containing `/base/soc@0/cci@ac15000` or `/base/soc@0/cci@ac16000`.
- Preserves libcamera's original camera orientation transform.
- Keeps rotation state and inotify ownership per camera node.
- Resolves the active user's configuration via XDG/HOME/passwd, without a fixed username or UID; KScreen queries have bounded output and a deadline.
- Does not use `/run/user/1000/y700-display-rotation`, `/etc/y700-camera-display-transform-mode`, or an external systemd updater.

## Verified Tags

The following physical observations apply to the historical Ubuntu baseline,
not to newly rebuilt camera libraries or a new Arch image. Standalone install,
repeat install, rejection-before-write and rollback are exercised by
`bash scripts/ci/test-camera-overlay-installer.sh`; those checks do not test
physical camera operation.

- `normal`: rear main/macro `rotate-90`, front `rotate-270`.
- `left`: all three `rotate-180`.
- `inverted`: rear main/macro `rotate-270`, front `rotate-90`.
- `right`: all three `rotate-0`.

Snapshot physical testing after restoring the 2026-06-22 backup payload confirmed baseline color output and rotation. Those observations do not approve the rebuilt profile or a new Arch image. The rejected `opt/libcamera-y700-test` app-chain remains forbidden. No camera application is started by the new target-loader dependency gate.

## Producer And Profile Updates

The canonical complete source/build path is the companion Ubuntu producer:
`scripts/ci/build-tb321fu-camera-stack-deb.sh`, its full libcamera source archive,
and its closed runtime/environment inputs. The profile records their exact
digests and the actual package/report identities. The operator importer checks
source consistency and all package members; it does not independently prove
compiler execution or authenticate a remote CI run. Obtain the producer output
from a separately authenticated run before approving an update.

Use `scripts/ci/import-camera-remediation-profile.py` with a trusted producer
checkout, actual DEB and report, and a new output path. Existing output is never
overwritten. Review the new profile before replacing a repository-approved one.
`working-tree-snapshot` is explicitly a local candidate, not proof of immutable
published source or hardware acceptance. The current documented restriction on
tagged Arch releases remains in force.

CI runs closed-profile/import hostile tests, real materialization/source parity,
the canonical C++ data-loop regression, and native staging/loader integration
fixtures. Final images additionally check actual target-loader resolution after
pacman ownership/integrity checks. These local fixtures do not substitute for a
real Arch image build or physical camera validation.
