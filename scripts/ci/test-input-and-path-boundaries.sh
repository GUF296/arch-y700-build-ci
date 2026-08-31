#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

builder="$SCRIPT_DIR/build-grub-image.sh"
apply_config="$SCRIPT_DIR/apply-workflow-config.sh"
workflow="$SCRIPT_DIR/../../.github/workflows/build-rootfs-and-grub.yml"
actionlint="$SCRIPT_DIR/run-actionlint.sh"
reserved_default='/reserved-memory/qdss@82800000 /reserved-memory/splash-region /reserved-memory/trust-ui-vm@f3800000 /reserved-memory/oem-vm@f7c00000'

grep -Fq 'unsupported .tar.zst device overlay (no bounded decoder)' \
  "$SCRIPT_DIR/build-arch-rootfs-image.sh"
if [ "$(grep -Fc -- "-name '*.tar.zst'" "$SCRIPT_DIR/build-arch-rootfs-image.sh")" -ne 1 ]; then
  echo 'Arch rootfs builder still advertises .tar.zst as an extractable device overlay' >&2
  exit 1
fi

grep -Fq 'aarch64|arm64' "$actionlint" || {
  echo 'Arch actionlint helper has no ARM64 asset selection' >&2
  exit 1
}
grep -Fq 'archive="actionlint_${version}_linux_arm64.tar.gz"' "$actionlint" || {
  echo 'Arch actionlint helper does not pin the ARM64 archive' >&2
  exit 1
}
grep -Fq '401942f9c24ed71e4fe71b76c7d638f66d8633575c4016efd2977ce7c28317d0' "$actionlint" || {
  echo 'Arch actionlint helper does not pin the reviewed ARM64 digest' >&2
  exit 1
}

# The reserved-memory policy is a boot-domain value.  Keep its default and
# sudo boundary explicit so a caller override cannot silently disappear before
# the GRUB builder.
grep -Fq -- "Y700_DIRECT_BOOT_RESERVED_MEMORY=$reserved_default" "$workflow" || {
  echo 'workflow boot.env is missing the canonical reserved-memory default' >&2
  exit 1
}
grep -Fq -- 'GRUB_TIMEOUT,Y700_DIRECT_BOOT_EFI_NAME,Y700_DIRECT_BOOT_RESERVED_MEMORY,Y700_GRUB_BUILD_DIR' "$workflow" || {
  echo 'GRUB sudo preserve-env list drops Y700_DIRECT_BOOT_RESERVED_MEMORY' >&2
  exit 1
}
grep -Fq -- 'reserved_memory=$Y700_DIRECT_BOOT_RESERVED_MEMORY' "$builder" || {
  echo 'GRUB BOOT-INFO metadata omits reserved-memory provenance' >&2
  exit 1
}

# Mirror path components are consumed by pacman, so only the constrained URL
# alphabet is accepted before the literal $arch/$repo placeholders.
ci_validate_arch_mirror 'https://ca.us.mirror.archlinuxarm.org/$arch/$repo'
ci_validate_arch_mirror 'https://mirror.example/releases/v1/$arch/$repo'
for hostile_mirror in \
  'https://mirror.example/path with-space/$arch/$repo' \
  'https://mirror.example/path;Server=evil/$arch/$repo' \
  'https://mirror.example/../$arch/$repo' \
  'https://mirror.example/%2e%2e/$arch/$repo' \
  'https://mirror.example/$(touch-pwned)/$arch/$repo' \
  'https://mirror.example/path=$arch/$repo'; do
  if (ci_validate_arch_mirror "$hostile_mirror") >/dev/null 2>&1; then
    echo "accepted hostile ARCH_MIRROR: $hostile_mirror" >&2
    exit 1
  fi
done

# Bash arithmetic must treat validated decimal strings as base ten; leading
# zeros must not be parsed as invalid octal (08/09).
for jobs in 08 09 010 64; do
  printf 'TB321FU_GPU_SENSOR_BUILD_JOBS=%s\n' "$jobs" > "$scratch/rootfs.env"
  GITHUB_ENV="$scratch/jobs.github.env" bash "$apply_config" "$scratch/rootfs.env"
  grep -Fq -- "TB321FU_GPU_SENSOR_BUILD_JOBS<<" "$scratch/jobs.github.env" || {
    echo "decimal GPU job input was not exported: $jobs" >&2
    exit 1
  }
done
for jobs in 00 65 0000000; do
  printf 'TB321FU_GPU_SENSOR_BUILD_JOBS=%s\n' "$jobs" > "$scratch/rootfs.env"
  if GITHUB_ENV="$scratch/jobs.github.env" bash "$apply_config" "$scratch/rootfs.env" >/dev/null 2>&1; then
    echo "out-of-range GPU job input was accepted: $jobs" >&2
    exit 1
  fi
done

# Exercise random GITHUB_ENV delimiter collision handling with a deterministic
# fixture provider, including bounded failure without a partial write.
delimiter_bin="$scratch/delimiter-bin"
mkdir -p "$delimiter_bin"
cat > "$delimiter_bin/od" <<'OD_FIXTURE'
#!/usr/bin/env bash
count=$(cat "${OD_COUNT_FILE:?}" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$OD_COUNT_FILE"
if [ "${OD_MODE:-retry}" = always ] || [ "$count" -eq 1 ]; then
  printf '%s\n' "$(printf '00%.0s' {1..32})"
else
  printf '%s\n' "$(printf '11%.0s' {1..32})"
fi
OD_FIXTURE
chmod 0755 "$delimiter_bin/od"
collision_value="TB321FU_ENV_KERNEL_VERSION_$(printf '00%.0s' {1..32})"
printf 'KERNEL_VERSION=%s\n' "$collision_value" > "$scratch/rootfs.env"
printf '0\n' > "$scratch/od-count"
OD_COUNT_FILE="$scratch/od-count" OD_MODE=retry PATH="$delimiter_bin:/usr/bin:/bin" \
  GITHUB_ENV="$scratch/delimiter-retry.env" bash "$apply_config" "$scratch/rootfs.env"
retry_delimiter="TB321FU_ENV_KERNEL_VERSION_$(printf '11%.0s' {1..32})"
grep -Fq -- "$retry_delimiter" "$scratch/delimiter-retry.env"
grep -Fq -- "$collision_value" "$scratch/delimiter-retry.env"
: > "$scratch/od-count"
if OD_COUNT_FILE="$scratch/od-count" OD_MODE=always PATH="$delimiter_bin:/usr/bin:/bin" \
  GITHUB_ENV="$scratch/delimiter-exhausted.env" bash "$apply_config" "$scratch/rootfs.env" \
  >/dev/null 2>&1; then
  echo 'workflow config accepted a value colliding with every delimiter' >&2
  exit 1
fi
[ ! -s "$scratch/delimiter-exhausted.env" ]

# Validate that a boot-domain override is exported intact, and that malformed
# path records fail before anything is written to GITHUB_ENV.
custom_reserved='/reserved-memory/custom@1 /reserved-memory/another-region'
printf 'Y700_DIRECT_BOOT_RESERVED_MEMORY=%s\n' "$custom_reserved" > "$scratch/boot.env"
GITHUB_ENV="$scratch/boot.github.env" bash "$apply_config" "$scratch/boot.env"
grep -Fq -- "$custom_reserved" "$scratch/boot.github.env" || {
  echo 'reserved-memory override was not exported through workflow config' >&2
  exit 1
}
printf 'Y700_DIRECT_BOOT_RESERVED_MEMORY=/reserved-memory/../escape\n' > "$scratch/invalid-boot.env"
if GITHUB_ENV="$scratch/invalid-boot.github.env" bash "$apply_config" "$scratch/invalid-boot.env" >/dev/null 2>&1; then
  echo 'invalid reserved-memory path was accepted by workflow config' >&2
  exit 1
fi

# A malformed URL must not mask the more fundamental local/remote EFI
# ambiguity.  Stub required host tools so this reaches the input boundary
# without creating an image or invoking any external builder.
fake_grub_bin="$scratch/grub-fake-bin"
mkdir -p "$fake_grub_bin"
for command in mkfs.vfat mcopy mdir mtype; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_grub_bin/$command"
  chmod 0755 "$fake_grub_bin/$command"
done
efi_fixture="$scratch/BOOTAA64.EFI"
: > "$efi_fixture"
set +e
efi_output=$(
  cd "$scratch"
  PATH="$fake_grub_bin:$PATH" \
    OUTPUT_DIR=grub-out OUTPUT_PREFIX=test BOOT_IMAGE_SIZE=16M \
    BOOTAA64_EFI="$efi_fixture" BOOTAA64_EFI_URL=http://invalid.example/efi \
    bash "$builder" 2>&1
)
efi_status=$?
set -e
[ "$efi_status" -ne 0 ] || { echo 'ambiguous BOOTAA64 EFI inputs were accepted' >&2; exit 1; }
grep -Fq -- 'BOOTAA64_EFI and BOOTAA64_EFI_URL are mutually exclusive' <<<"$efi_output" || {
  echo 'BOOTAA64 EFI ambiguity failed at the wrong boundary' >&2
  exit 1
}
if grep -Fq -- 'must use HTTPS' <<<"$efi_output"; then
  echo 'BOOTAA64 EFI URL validation ran before mutual-exclusion check' >&2
  exit 1
fi

qcom_fixture="$scratch/QCOMRAMP.EFI"
: > "$qcom_fixture"
set +e
qcom_output=$(
  cd "$scratch"
  PATH="$fake_grub_bin:$PATH" \
    OUTPUT_DIR=grub-out-qcom OUTPUT_PREFIX=test BOOT_IMAGE_SIZE=16M \
    QCOMRAMP_EFI="$qcom_fixture" QCOMRAMP_EFI_URL=http://invalid.example/efi \
    bash "$builder" 2>&1
)
qcom_status=$?
set -e
[ "$qcom_status" -ne 0 ] || { echo 'ambiguous QCOMRAMP EFI inputs were accepted' >&2; exit 1; }
grep -Fq -- 'QCOMRAMP_EFI and QCOMRAMP_EFI_URL are mutually exclusive' <<<"$qcom_output" || {
  echo 'QCOMRAMP EFI ambiguity failed at the wrong boundary' >&2
  exit 1
}
if grep -Fq -- 'must use HTTPS' <<<"$qcom_output"; then
  echo 'QCOMRAMP EFI URL validation ran before mutual-exclusion check' >&2
  exit 1
fi

expected=$'base\nlibfoo\npkg=1.2-3'
actual=$(ci_normalize_package_list $'base libfoo\npkg=1.2-3')
[ "$actual" = "$expected" ]
for hostile in '--config' 'lib*' '$(touch /tmp/not-run)' 'bad/token'; do
  if (ci_normalize_package_list "$hostile") >/dev/null 2>&1; then
    printf 'accepted hostile package token: %s\n' "$hostile" >&2
    exit 1
  fi
done

touch "$scratch/boot.img" "$scratch/rootfs.img"
ci_require_distinct_paths BOOT "$scratch/boot.img" ROOTFS "$scratch/rootfs.img" OUTPUT "$scratch/disk.img"
if (ci_require_distinct_paths BOOT "$scratch/boot.img" OUTPUT "$scratch/./boot.img") >/dev/null 2>&1; then
  echo 'accepted canonically identical paths' >&2
  exit 1
fi
ln "$scratch/boot.img" "$scratch/boot-hardlink.img"
if (ci_require_distinct_paths BOOT "$scratch/boot.img" OUTPUT "$scratch/boot-hardlink.img") >/dev/null 2>&1; then
  echo 'accepted hard-linked paths' >&2
  exit 1
fi

mkdir -p "$scratch/cleanup/.arch-rootfs-build.target/child"
cleanup_target=$(realpath -e "$scratch/cleanup/.arch-rootfs-build.target")
cleanup_findmnt_bin="$scratch/cleanup-findmnt-bin"
install -D -m 0755 /dev/stdin "$cleanup_findmnt_bin/findmnt" <<'CLEANUP_FINDMNT'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${FAKE_MOUNTS:-}" ]; then
  printf '{"filesystems":[{"target":"%s"}]}\n' "$FAKE_MOUNTS"
else
  printf '{"filesystems":[]}\n'
fi
CLEANUP_FINDMNT
PATH="$cleanup_findmnt_bin:$PATH"
export PATH FAKE_MOUNTS
FAKE_MOUNTS=$cleanup_target
if ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .arch-rootfs-build. >/dev/null 2>&1; then
  echo 'deleted a target that is itself a mount root' >&2
  exit 1
fi
test -d "$cleanup_target"
FAKE_MOUNTS=$cleanup_target/child
if ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .arch-rootfs-build. >/dev/null 2>&1; then
  echo 'deleted a target containing a descendant mount' >&2
  exit 1
fi
FAKE_MOUNTS=
ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .arch-rootfs-build.
test ! -e "$cleanup_target"

# Cleanup must fail closed when the expected parent has been replaced by a
# symlink. The outside tree is a canary proving no target was followed.
cleanup_parent_real="$scratch/cleanup-parent-real"
cleanup_parent_link="$scratch/cleanup-parent-link"
cleanup_outside="$scratch/cleanup-outside"
mkdir -p "$cleanup_parent_real/.arch-rootfs-build.parent" "$cleanup_outside"
printf 'keep\n' > "$cleanup_outside/sentinel"
ln -s "$cleanup_parent_real" "$cleanup_parent_link"
if ci_safe_rmtree "$cleanup_parent_link/.arch-rootfs-build.parent" \
    "$cleanup_parent_link" .arch-rootfs-build. >/dev/null 2>&1; then
  echo 'cleanup followed a parent directory symlink' >&2
  exit 1
fi
[ -d "$cleanup_parent_real/.arch-rootfs-build.parent" ] || {
  echo 'parent symlink fixture removed the real target' >&2
  exit 1
}
[ -f "$cleanup_outside/sentinel" ] || {
  echo 'parent symlink cleanup touched the outside canary' >&2
  exit 1
}

# A symlink in a candidate ancestor is rejected even when the lexical leaf
# name matches the cleanup prefix.
cleanup_ancestor_real="$scratch/cleanup-ancestor-real"
cleanup_ancestor_link="$scratch/cleanup-ancestor-link"
mkdir -p "$cleanup_ancestor_real" "$cleanup_outside/.arch-rootfs-build.ancestor"
ln -s "$cleanup_outside" "$cleanup_ancestor_link"
if ci_safe_rmtree "$cleanup_ancestor_link/.arch-rootfs-build.ancestor" \
    "$scratch" .arch-rootfs-build. >/dev/null 2>&1; then
  echo 'cleanup followed a candidate symlink ancestor' >&2
  exit 1
fi
[ -d "$cleanup_outside/.arch-rootfs-build.ancestor" ] || {
  echo 'candidate ancestor symlink cleanup removed the outside target' >&2
  exit 1
}

# Dangling candidate symlinks are not treated as absent directories.
dangling_candidate="$scratch/.arch-rootfs-build.dangling"
ln -s "$cleanup_outside/missing-target" "$dangling_candidate"
if ci_safe_rmtree "$dangling_candidate" "$scratch" .arch-rootfs-build. >/dev/null 2>&1; then
  echo 'cleanup accepted a dangling candidate symlink' >&2
  exit 1
fi
[ -L "$dangling_candidate" ] || {
  echo 'dangling candidate symlink was removed' >&2
  exit 1
}
[ -f "$cleanup_outside/sentinel" ] || {
  echo 'dangling candidate cleanup touched the outside canary' >&2
  exit 1
}

echo 'PASS input and filesystem path boundaries'
