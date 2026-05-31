#!/usr/bin/env bash
set -euo pipefail

ALPINE_VERSION="3.20"
ALPINE_ARCH="aarch64"
IMG_SIZE="4G"
OUT="ilinux-alpine-${ALPINE_ARCH}.qcow2"
WORK="$(mktemp -d)"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"
PRESET_PACKAGES="nodejs npm git python3 py3-pip openssh bash util-linux"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) ALPINE_VERSION="$2"; shift 2 ;;
    --arch)    ALPINE_ARCH="$2"; shift 2 ;;
    --size)    IMG_SIZE="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

BRANCH="v${ALPINE_VERSION}"
MINIROOTFS_BASE="${MIRROR}/${BRANCH}/releases/${ALPINE_ARCH}"

echo ">> Building iLinux guest image"
echo "   Alpine ${ALPINE_VERSION} (${ALPINE_ARCH}), size ${IMG_SIZE}, out ${OUT}"

echo ">> Resolving latest minirootfs filename"
LATEST_YAML="${MINIROOTFS_BASE}/latest-releases.yaml"
ROOTFS_FILE="$(curl -fsSL "$LATEST_YAML" \
  | awk '/minirootfs/{f=1} f&&/file:/{print $2; exit}')"

if [[ -z "${ROOTFS_FILE:-}" ]]; then
  echo "!! Could not resolve minirootfs filename" >&2
  exit 1
fi

echo ">> Downloading ${ROOTFS_FILE}"
curl -fsSL -o "${WORK}/rootfs.tar.gz" "${MINIROOTFS_BASE}/${ROOTFS_FILE}"
curl -fsSL -o "${WORK}/rootfs.tar.gz.sha256" "${MINIROOTFS_BASE}/${ROOTFS_FILE}.sha256" || true

if [[ -f "${WORK}/rootfs.tar.gz.sha256" ]]; then
  echo ">> Verifying checksum"
  EXPECTED=$(awk '{print $1}' "${WORK}/rootfs.tar.gz.sha256")
  ACTUAL=$(sha256sum "${WORK}/rootfs.tar.gz" | awk '{print $1}')
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo "!! checksum FAILED" >&2
    exit 1
  fi
  echo ">> Checksum OK"
fi
  
else
  echo "!! No sha256 found; refusing to continue" >&2
  exit 1
fi

echo ">> Creating raw image"
RAW="${WORK}/disk.raw"
qemu-img create -f raw "$RAW" "$IMG_SIZE" >/dev/null
mkfs.ext4 -q -L ilinux-root "$RAW"

MNT="${WORK}/mnt"
mkdir -p "$MNT"
mount -o loop "$RAW" "$MNT"

echo ">> Unpacking rootfs"
tar -xzf "${WORK}/rootfs.tar.gz" -C "$MNT"

install -D -m 0755 \
  "$(dirname "$0")/../packages/ilinux-guest-agent/ilinux-agent.py" \
  "$MNT/usr/local/bin/ilinux-agent"

install -D -m 0755 \
  "$(dirname "$0")/../packages/ilinux-guest-agent/ilinux-agent.openrc" \
  "$MNT/etc/init.d/ilinux-agent"

echo ">> Configuring inside chroot"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
mount --bind /proc "$MNT/proc"
mount --bind /sys  "$MNT/sys"
mount --bind /dev  "$MNT/dev"

chroot "$MNT" /bin/sh -eux <<CHROOT
cat > /etc/apk/repositories <<REPOS
${MIRROR}/${BRANCH}/main
${MIRROR}/${BRANCH}/community
REPOS
apk update
apk add --no-cache python3 ${PRESET_PACKAGES}
cat > /etc/motd <<MOTD
  iLinux - Alpine ${ALPINE_VERSION} tuned for iPhone
  Agent status: rc-service ilinux-agent status
  Sensors: /run/ilinux/sensors.json
MOTD
rc-update add ilinux-agent default
adduser -D -s /bin/bash ilinux || true
echo "ilinux:ilinux" | chpasswd
CHROOT

umount "$MNT/proc" "$MNT/sys" "$MNT/dev"
umount "$MNT"

echo ">> Converting to qcow2"
qemu-img convert -f raw -O qcow2 "$RAW" "$OUT"
qemu-img info "$OUT"
echo ">> Done: $OUT"
