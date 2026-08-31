#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 ROOTFS" >&2
  exit 2
fi

rootfs=${1%/}
[ -n "$rootfs" ] || rootfs=/

if [ ! -d "$rootfs" ]; then
  echo "rootfs does not exist: $rootfs" >&2
  exit 1
fi

base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
overlay=$base/rootfs-overlay
checksums=$base/SHA256SUMS

[ -d "$overlay/opt/libcamera-y700" ] || {
  echo "camera overlay missing opt/libcamera-y700" >&2
  exit 1
}
[ -f "$checksums" ] || {
  echo "camera overlay missing SHA256SUMS" >&2
  exit 1
}

(cd "$base/rootfs-overlay" && sha256sum -c "$checksums" >/dev/null)

mkdir -p "$rootfs"
(cd "$overlay" && tar cf - .) | (cd "$rootfs" && tar xpf -)

plugin=$rootfs/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
cam=$rootfs/opt/libcamera-y700/bin/cam
soft_ipa=$rootfs/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so
soft_proxy=$rootfs/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy
gst_plugin=$rootfs/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so
gst_system_plugin=$rootfs/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so

[ -x "$cam" ] || { echo "camera overlay missing executable /opt/libcamera-y700/bin/cam" >&2; exit 1; }
[ -f "$soft_ipa" ] || { echo "camera overlay missing ipa_soft_simple.so" >&2; exit 1; }
[ -x "$soft_proxy" ] || { echo "camera overlay missing executable soft_ipa_proxy" >&2; exit 1; }
[ -f "$gst_plugin" ] || { echo "camera overlay missing GStreamer libcamera plugin" >&2; exit 1; }
[ -L "$gst_system_plugin" ] || { echo "camera overlay missing system GStreamer libcamera plugin entry" >&2; exit 1; }
[ "$(readlink "$gst_system_plugin")" = "/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so" ] || { echo "camera overlay system GStreamer plugin entry points at wrong target" >&2; exit 1; }
[ -f "$plugin" ] || { echo "camera overlay missing PipeWire SPA libcamera plugin" >&2; exit 1; }
[ -f "$rootfs/opt/libcamera-y700/share/libcamera/ipa/simple/gc13a0.yaml" ] || { echo "camera overlay missing gc13a0 tuning" >&2; exit 1; }
[ -f "$rootfs/opt/libcamera-y700/share/libcamera/ipa/simple/sc202cs.yaml" ] || { echo "camera overlay missing sc202cs tuning" >&2; exit 1; }
[ -f "$rootfs/opt/libcamera-y700/share/libcamera/ipa/simple/sc820cs.yaml" ] || { echo "camera overlay missing sc820cs tuning" >&2; exit 1; }
[ -f "$rootfs/etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf" ] || { echo "camera overlay missing PipeWire namespace drop-in" >&2; exit 1; }
[ -f "$rootfs/etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf" ] || { echo "camera overlay missing PipeWire libcamera paths drop-in" >&2; exit 1; }
[ -f "$rootfs/etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf" ] || { echo "camera overlay missing WirePlumber libcamera paths drop-in" >&2; exit 1; }
[ -f "$rootfs/etc/udev/rules.d/70-y700-camera-dma-heap.rules" ] || { echo "camera overlay missing DMA heap udev rule" >&2; exit 1; }
[ -f "$rootfs/etc/ld.so.conf.d/y700-libcamera.conf" ] || { echo "camera overlay missing libcamera ldconfig path" >&2; exit 1; }

for binary in \
  "$cam" \
  "$rootfs/opt/libcamera-y700/bin/libcamera-bug-report" \
  "$soft_proxy" \
  "$rootfs/usr/local/bin/y700-camera-env" \
  "$rootfs/usr/local/bin/y700-camera-cam" \
  "$rootfs/usr/local/bin/y700-camera-preview"; do
  [ -e "$binary" ] && chmod 0755 "$binary"
done

find "$rootfs/opt/libcamera-y700" "$rootfs/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera" \
  -type f -name '*.so*' -exec chmod 0644 {} +

if [ "$(id -u)" -eq 0 ]; then
  chown -R 0:0 "$rootfs/opt/libcamera-y700" \
    "$rootfs/usr/local/bin/y700-camera-env" \
    "$rootfs/usr/local/bin/y700-camera-cam" \
    "$rootfs/usr/local/bin/y700-camera-preview" \
    "$rootfs/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" \
    "$rootfs/etc/systemd/user/pipewire.service.d" \
    "$rootfs/etc/systemd/user/wireplumber.service.d" \
    "$rootfs/etc/udev/rules.d/70-y700-camera-dma-heap.rules" \
    "$rootfs/etc/ld.so.conf.d/y700-libcamera.conf"
fi

# Fail the build if the rejected test app-chain leaks back in. Do not scrub
# binaries here; the payload is the live-verified backup content.
if strings "$plugin" "$cam" "$soft_ipa" "$soft_proxy" "$gst_plugin" \
  | grep -F 'libcamera-y700-test' >/dev/null; then
  echo "camera payload still references rejected libcamera-y700-test app-chain" >&2
  exit 1
fi

# These belonged to earlier live experiments. The clean daily camera plugin
# keeps display rotation state internally and must not depend on them.
rm -f \
  "$rootfs/etc/udev/rules.d/70-y700-dma-heap.rules" \
  "$rootfs/etc/y700-camera-display-transform-mode" \
  "$rootfs/etc/y700-camera-display-rotation-base" \
  "$rootfs/etc/systemd/user/y700-display-rotation-update.path" \
  "$rootfs/etc/systemd/user/y700-display-rotation-update.service" \
  "$rootfs/etc/systemd/user/y700-display-rotation-dbus.service" \
  "$rootfs/etc/systemd/user/y700-display-rotation-sync.service" \
  "$rootfs/usr/local/libexec/y700-display-rotation-update" \
  "$rootfs/usr/local/libexec/y700-display-rotation-dbus" \
  "$rootfs/usr/local/bin/y700-display-rotation-sync" \
  "$rootfs/run/y700-camera-display-rotation"

echo "installed Y700 camera overlay into $rootfs"
