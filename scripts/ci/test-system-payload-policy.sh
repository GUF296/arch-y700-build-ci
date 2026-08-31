#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/system-payload-policy.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-arch-payload-policy-test.XXXXXX")
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT

root="$tmp/root"
outside="$tmp/outside"
install -d -m 0755 "$outside"
printf 'outside\n' > "$outside/world-writable"
chmod 0777 "$outside/world-writable"
install -d -m 0777 \
  "$root/etc/systemd/system" \
  "$root/usr/lib/firmware" \
  "$root/usr/lib/aarch64-linux-gnu" \
  "$root/usr/libexec/tb321fu-haptics" \
  "$root/usr/local/bin" \
  "$root/opt/libcamera-y700/bin" \
  "$root/opt/libcamera-y700/libexec/libcamera"
ln -s "$outside" "$root/lib"
printf 'unit\n' > "$root/etc/systemd/system/fixture.service"
printf 'firmware\n' > "$root/usr/lib/firmware/fixture.bin"
printf 'library\n' > "$root/usr/lib/aarch64-linux-gnu/libfixture.so"
printf '#!/bin/sh\nexit 0\n' > "$root/usr/libexec/tb321fu-haptics/bind-aw86937"
for executable in \
  "$root/opt/libcamera-y700/bin/cam" \
  "$root/opt/libcamera-y700/bin/libcamera-bug-report" \
  "$root/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy" \
  "$root/usr/local/bin/y700-camera-env" \
  "$root/usr/local/bin/y700-camera-cam" \
  "$root/usr/local/bin/y700-camera-preview"; do
  printf '#!/bin/sh\nexit 0\n' > "$executable"
done
chmod 0777 "$root/etc/systemd/system/fixture.service" \
  "$root/usr/lib/firmware/fixture.bin" \
  "$root/usr/lib/aarch64-linux-gnu/libfixture.so"
chmod 0644 "$root/usr/libexec/tb321fu-haptics/bind-aw86937" \
  "$root/opt/libcamera-y700/bin/cam" \
  "$root/opt/libcamera-y700/bin/libcamera-bug-report" \
  "$root/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy" \
  "$root/usr/local/bin/y700-camera-env" \
  "$root/usr/local/bin/y700-camera-cam" \
  "$root/usr/local/bin/y700-camera-preview"

ci_normalize_system_payload_modes "$root"
ci_assert_normalized_system_payload_modes "$root"
if [ "$EUID" -eq 0 ]; then
  # Simulate a user-owned checkout copied into a package stage, then require
  # production normalization to restore root ownership without following the
  # symlink at /lib.
  chown -R 1000:1000 -- "$root"
  ci_normalize_system_payload_ownership "$root"
  ci_assert_system_payload_root_owned "$root"

  # Ownership checks must be about the symlink inode, not the target it
  # names.  A hostile non-root link to a root-owned file must fail closed.
  printf 'root target\n' > "$root/owner-target"
  chown 0:0 "$root/owner-target"
  ln -s owner-target "$root/owner-link"
  chown -h 1000:1000 "$root/owner-link"
  if (ci_assert_system_payload_root_owned "$root") >/dev/null 2>&1; then
    echo 'non-root-owned symlink was accepted by the ownership assertion' >&2
    exit 1
  fi
  [ "$(ci_lstat_owner "$root/owner-target")" = 0:0 ]
  rm -f "$root/owner-link" "$root/owner-target"
  ci_assert_system_payload_root_owned "$root"
fi
ci_assert_privileged_payload_security "$root" \
  usr/libexec/tb321fu-haptics/bind-aw86937 \
  opt/libcamera-y700/bin/cam \
  opt/libcamera-y700/bin/libcamera-bug-report \
  opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy \
  usr/local/bin/y700-camera-env \
  usr/local/bin/y700-camera-cam \
  usr/local/bin/y700-camera-preview
[ "$(stat -c '%a' "$root/etc/systemd/system/fixture.service")" = 644 ]
[ "$(stat -c '%a' "$root/usr/lib/firmware/fixture.bin")" = 644 ]
[ "$(stat -c '%a' "$root/usr/lib/aarch64-linux-gnu/libfixture.so")" = 644 ]
[ "$(stat -c '%a' "$root/usr/libexec/tb321fu-haptics/bind-aw86937")" = 755 ]
[ "$(stat -c '%a' "$root/opt/libcamera-y700/bin/cam")" = 755 ]
[ "$(stat -c '%a' "$outside/world-writable")" = 777 ]

chmod 0777 "$root/usr/lib/firmware/fixture.bin"
if (ci_assert_privileged_payload_security "$root" >/dev/null 2>&1); then
  echo '0777 imported payload was accepted' >&2
  exit 1
fi
chmod 0644 "$root/usr/lib/firmware/fixture.bin"
if (ci_assert_privileged_payload_security "$root" etc/systemd/system/fixture.service >/dev/null 2>&1); then
  echo 'non-executable required payload was accepted' >&2
  exit 1
fi

# A hard link can point at an inode shared with a path outside the package
# stage.  The policy must reject it before any ownership or mode mutation.
printf 'shared inode\n' > "$outside/shared-inode"
ln "$outside/shared-inode" "$root/usr/lib/firmware/shared-inode"
if (ci_assert_no_hardlinked_system_payload "$root" >/dev/null 2>&1); then
  echo 'hard-linked payload was accepted' >&2
  exit 1
fi
if (ci_assert_normalized_system_payload_modes "$root" >/dev/null 2>&1); then
  echo 'hard-linked payload passed the normalized-mode assertion' >&2
  exit 1
fi

grep -F 'ci_normalize_system_payload_modes "$stage"' \
  "$SCRIPT_DIR/build-arch-rootfs-image.sh" >/dev/null
grep -F 'ci_normalize_system_payload_ownership "$stage"' \
  "$SCRIPT_DIR/build-arch-rootfs-image.sh" >/dev/null
grep -F 'ci_assert_privileged_payload_security "$rootfs_dir"' \
  "$SCRIPT_DIR/build-arch-rootfs-image.sh" >/dev/null

echo 'SYSTEM_PAYLOAD_POLICY=PASS'
