# Y700 Camera Rootfs Overlay

This overlay captures the Lenovo Y700 TB321FU daily camera stack verified on Ubuntu 26.04. It includes the known-good `/opt/libcamera-y700` app-chain, PipeWire SPA plugin, IPA/tuning files, PipeWire/WirePlumber environment drop-ins, and DMA heap udev rule restored from the 2026-06-22 live rootfs backup.

## Install Into A Mounted Rootfs

```sh
sudo ./install.sh /path/to/rootfs
```

Use `/` as the target only when intentionally applying it to a live system.

## Contents

- `rootfs-overlay/opt/libcamera-y700`: verified libcamera app-chain, IPA proxy, SoftISP IPA, and Y700 tuning files.
- `rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so`: verified `spa-libcamera` plugin, SHA256 `25e951d022816b999f51d85e285f548b79d865db0c3959019bcc08981261665c`.
- `rootfs-overlay/etc/systemd/user/pipewire.service.d`: PipeWire namespace and libcamera path drop-ins.
- `rootfs-overlay/etc/systemd/user/wireplumber.service.d`: WirePlumber libcamera path drop-in.
- `rootfs-overlay/etc/udev/rules.d/70-y700-camera-dma-heap.rules`: DMA heap access for camera users.
- `source/libcamera-source.cpp.clean-minimal-daily`: full patched source used to build the plugin.
- `source/y700-camera-daily-minimal-upstream-1.6.2.patch`: minimal patch against upstream PipeWire 1.6.2.

## Runtime Model

- Applies only to Y700 built-in cameras detected by libcamera IDs containing `/base/soc@0/cci@ac15000` or `/base/soc@0/cci@ac16000`.
- Preserves libcamera's original camera orientation transform.
- Caches KScreen rotation internally on first camera frame.
- While camera is active, watches `/home/y700/.config` with nonblocking inotify and only re-queries KScreen for `kwinoutputconfig.json` events.
- Does not use `/run/user/1000/y700-display-rotation`, `/etc/y700-camera-display-transform-mode`, or an external systemd updater.

## Verified Tags

- `normal`: rear main/macro `rotate-90`, front `rotate-270`.
- `left`: all three `rotate-180`.
- `inverted`: rear main/macro `rotate-270`, front `rotate-90`.
- `right`: all three `rotate-0`.

Snapshot physical testing after restoring the 2026-06-22 backup payload confirmed that color output and camera rotation are correct. The rootfs build uses this overlay payload directly and must not unpack the older `opt/libcamera-y700-test` app-chain tarball. The installer validates hashes and fails on the rejected test app-chain path; it does not rewrite or scrub binaries.
