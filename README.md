# Arch Linux ARM Y700/TB321FU Build CI

Build Arch Linux ARM Plasma rootfs and GRUB images for Lenovo Y700 / TB321FU.

This repository is intentionally separate from the Ubuntu/Kubuntu build. It reuses the verified Y700 boot/kernel/device payload sources, but builds an Arch Linux ARM userspace.

## Current Scope

- Arch Linux ARM `aarch64` rootfs
- KDE Plasma desktop
- SDDM autologin support
- NetworkManager
- PipeWire/WirePlumber audio stack
- Mesa/Freedreno/Vulkan packages
- Fcitx5 Chinese input
- Plasma Keyboard virtual keyboard
- Existing Y700/TB321FU kernel modules, firmware, udev rules and systemd services from the verified device payload archive
- GRUB/FAT image using the existing verified boot template and kernel artifact

Steam, FEX and Proton are not included in this Arch build.

## Desktop Profiles

The workflow input `desktop_profile` controls the KDE package set:

- `minimal`: smaller Plasma desktop baseline
- `standard`: recommended default, includes Plasma plus common KDE daily-use apps
- `full`: includes `kde-applications-meta` in addition to the standard package set

The default is `standard` to avoid an oversized image while still providing a usable desktop.

## Hardware Payload Strategy

Arch cannot install the existing Ubuntu `.deb` packages with `dpkg`, but the payload files inside those packages are still required. The Arch rootfs build extracts the `.deb` data archives directly into the rootfs to preserve:

- `/usr/lib/modules/7.1.1-g5df8e852ea72`
- Qualcomm firmware under `/usr/lib/firmware` and compatibility paths under `/lib/firmware`
- Y700/TB321FU udev rules
- Y700/TB321FU systemd services
- sensor, haptics, camera and audio helper files

The build then runs `depmod -b` for the target kernel and fails if required firmware/modules/services are missing. Imported files are owned by native Arch packages so later `pacman` transactions can verify and restore them. When the optional TB321FU GPU provider is enabled, the stock `ksystemstats` plugin remains present and package-owned; a user-service systemd namespace drop-in hides it only from the statistics daemon, keeping `pacman -Qkk ksystemstats` consistent across upgrades.

Required compatibility files include:

```text
/lib/firmware/qcom/gen70900_aqe.fw
/lib/firmware/qcom/gen70900_sqe.fw
/lib/firmware/qcom/gen70900_zap.mbn
/lib/firmware/qcom/gmu_gen70900.bin
/lib/firmware/qcom/vpu/vpu33_p4.mbn
/lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
/usr/lib/modules/7.1.1-g5df8e852ea72
```

Build metadata, SHA256 files and manifests are emitted as Actions artifacts. They are not placed in the rootfs image root directory.

## Release Assets

Release assets use short names:

- `boot.img.7z`
- `grub.img.7z`
- `rootfs.img.7z.000`
- `rootfs.img.7z.001`
- `SHA256SUMS.txt`

Rootfs archives larger than GitHub's per-asset limit are split. Recombine before extraction:

```sh
cat rootfs.img.7z.* > rootfs.img.7z
```

## Build Inputs

Common workflow inputs:

- `release_tag`: leave empty; tagged Arch releases are currently disabled
- `desktop_profile`: `minimal`, `standard`, or `full`
- `ARCH_MIRROR`: HTTPS Arch Linux ARM rolling mirror URL ending in `/$arch/$repo`; it is used only by artifact-only builds
- `rootfs_image_size`: default `20G`
- `hostname_name`: default `GUF296`
- `default_user_name`: default `GUF296`
- password hashes are supplied only through repository secrets; absent hashes create locked accounts
- `sddm_autologin`: default enabled in the tested release profile

Advanced overrides are available through `rootfs_config` and `boot_config` as `KEY=value` lines.

Arch Linux ARM is a rolling distribution. The `ARCH_ROOTFS_SHA256` value authenticates the selected base tarball, but the mirror URL does not identify repository databases, package versions, signatures, or the dependency closure selected by `pacman -Syu`. The public mirror currently has no reviewed dated snapshot/closure input in this project. Therefore this workflow is intentionally artifact-only: leave `release_tag` empty, and do not treat an Actions artifact as a byte-for-byte reproducible or publishable Arch release. The provenance gate fails closed if a tag is supplied. A tagged release may be enabled only after a reviewed repository snapshot plus complete package/dependency digest manifest is added and bound to the build.

## First Validation Targets

The first device validation should check:

- boot to Plasma Wayland
- touch input
- Wi-Fi and Bluetooth
- `/dev/dri/renderD128` and `vulkaninfo`
- PipeWire audio device visibility
- Fcitx5 Chinese input
- Plasma Keyboard popup
- sensor rotation behavior
- haptics service status
- SSH access
