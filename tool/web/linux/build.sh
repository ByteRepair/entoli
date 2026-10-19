#!/usr/bin/env bash
# Builds the browser's Linux into web/linux/image/ (or the directory given):
# the v86 emulator, its BIOS, an i386 Alpine kernel and initramfs, and the root
# disk cut into zstd chunks the page fetches as the guest reads them. Needs
# podman or docker and a network; everything else runs in containers.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/versions.sh"
out=${1:-$here/../../../web/linux/image}
engine=${CONTAINER_ENGINE:-$(command -v podman || command -v docker)}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tag="entoli-web-linux:$ALPINE"
"$engine" build --platform linux/386 --build-arg "ALPINE=$ALPINE" \
	-t "$tag" -f "$here/Containerfile" "$here"
cid=$("$engine" create --platform linux/386 "$tag" /bin/true)
"$engine" export "$cid" >"$work/rootfs.tar"
"$engine" rm "$cid" >/dev/null

# In a container so the unpacked files are root's, which is what mke2fs
# records them as.
"$engine" run --rm --platform linux/386 -v "$work:/work:Z" \
	-e "CHUNK=$CHUNK_BYTES" -e "V86_VERSION=$V86_VERSION" \
	-e "V86_INTEGRITY=$V86_INTEGRITY" -e "V86_COMMIT=$V86_COMMIT" \
	-e "SEABIOS_SHA256=$SEABIOS_SHA256" -e "VGABIOS_SHA256=$VGABIOS_SHA256" \
	-e "ALPINE=$ALPINE" \
	"docker.io/library/alpine:$ALPINE" sh -euc '
	apk add --no-cache e2fsprogs zstd curl openssl coreutils >/dev/null
	fs=/root/fs
	mkdir "$fs"
	tar -xpf /work/rootfs.tar -C "$fs" --numeric-owner
	release=$(cat "$fs/etc/entoli-kernel")
	mkdir /work/out
	cp "$fs/boot/vmlinuz-virt" /work/out/kernel
	cp "$fs/boot/initramfs-virt" /work/out/initrd
	rm -rf "$fs"/boot/* "$fs/.dockerenv" "$fs/run/.containerenv"
	# What the container runtime wrote into these describes the build host.
	printf "127.0.0.1\tlocalhost entoli\n::1\tlocalhost entoli\n" >"$fs/etc/hosts"
	echo entoli >"$fs/etc/hostname"
	: >"$fs/etc/resolv.conf"
	chroot "$fs" /sbin/apk info -v 2>/dev/null | sort >/work/out/packages.txt || true

	# Room past what is installed is where the guest writes, held in the
	# page'"'"'s memory; free blocks are zeros, a few bytes a chunk once packed.
	used=$(du -sm "$fs" | cut -f1)
	mib=$((used * 12 / 10 + 1024))
	mke2fs -q -t ext4 -O ^has_journal -m 0 -L entoli \
		-E lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0 \
		-d "$fs" /work/disk.img "${mib}M"
	mkdir /work/out/disk
	cd /work/out/disk
	split -b "$CHUNK" -a 6 -d /work/disk.img part.
	for part in part.*; do
		start=$(( $(echo "${part#part.}" | sed "s/^0*//;s/^$/0/") * CHUNK ))
		zstd -q -12 --rm "$part" -o "disk-$start-$((start + CHUNK)).img.zst"
	done
	bytes=$((mib * 1024 * 1024))

	cd /work/out
	curl -fsSL -o v86.tgz "https://registry.npmjs.org/v86/-/v86-$V86_VERSION.tgz"
	got="sha512-$(openssl dgst -sha512 -binary v86.tgz | base64 -w0)"
	[ "$got" = "$V86_INTEGRITY" ] || { echo "v86 $V86_VERSION: $got" >&2; exit 1; }
	tar -xzf v86.tgz package/build/libv86.js package/build/v86.wasm package/LICENSE
	mv package/build/libv86.js package/build/v86.wasm .
	mv package/LICENSE LICENSE.v86
	rm -rf package v86.tgz
	for bios in seabios vgabios; do
		curl -fsSL -o "$bios.bin" \
			"https://raw.githubusercontent.com/copy/v86/$V86_COMMIT/bios/$bios.bin"
	done
	echo "$SEABIOS_SHA256  seabios.bin" | sha256sum -c --status
	echo "$VGABIOS_SHA256  vgabios.bin" | sha256sum -c --status

	# Named for what is in it: Pages caches for ten minutes, and chunks under
	# a fixed name would be read half from one deploy and half from the next.
	id=$(cat kernel initrd /work/disk.img | sha256sum | cut -c1-16)
	mkdir "$id"
	for f in *; do [ "$f" = "$id" ] || mv "$f" "$id/"; done
	cat >manifest.json <<EOF
{
  "base": "$id/",
  "alpine": "$ALPINE",
  "arch": "i386",
  "kernel": "$release",
  "v86": "$V86_VERSION",
  "disk": {"bytes": $bytes, "chunk": $CHUNK}
}
EOF
	cat >"$id/NOTICE.txt" <<EOF
The browser Linux is made of other projects'"'"' work, redistributed unmodified:

v86 $V86_VERSION (BSD-2-Clause, LICENSE.v86): https://github.com/copy/v86/tree/$V86_COMMIT
SeaBIOS and the VGA BIOS (LGPL-3.0), as built by v86: same commit, bios/
Alpine Linux $ALPINE, i386 (packages.txt lists each package and version);
its sources, licences included: https://gitlab.alpinelinux.org/alpine/aports/-/tree/v$ALPINE
EOF
'

rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -r "$work/out" "$out"
echo "Built $(du -sh "$out" | cut -f1) into $out"
