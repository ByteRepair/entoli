# What is bundled, and what it was checked to be. Bumping any of these is the
# whole of an update: the CI cache is keyed on this file, so the next run
# rebuilds.
#
# These are security-relevant: git, curl and OpenSSL are ours to rebuild when
# one of them has a CVE, since nothing on the device updates them for us.

GIT_VERSION=2.47.1
GIT_URL="https://mirrors.edge.kernel.org/pub/software/scm/git/git-$GIT_VERSION.tar.gz"
GIT_SHA256=f4c4e98667800585d218dfdf415eb72f73baa7abcac4569e2ce497970f8d6665

CURL_VERSION=8.21.0
CURL_URL="https://github.com/curl/curl/releases/download/curl-8_21_0/curl-$CURL_VERSION.tar.gz"
CURL_SHA256=d9b327997999045a24cda50f3983e69e51c516bd8be6ef9842fc7f99135e33bb

OPENSSL_VERSION=4.0.1
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SHA256=2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09

# Termux's fork rather than proot-me's: it carries the Android work — the
# ashmem/memfd extension, --link2symlink, --kill-on-exit — and is the version
# every Linux-on-Android install already runs. GPL-2.0-or-later, which our
# AGPL-3.0 takes. There are no releases, only tags, so this is the tarball
# GitHub generates for one.
PROOT_VERSION=5.1.107.91
PROOT_URL="https://github.com/termux/proot/archive/refs/tags/v$PROOT_VERSION.tar.gz"
PROOT_SHA256=80118aca363757bb2ff212ac04f12600c893c6a84aea3cf9434311cd3dafb951

# proot's only dependency, and the one thing it links that Android does not
# ship. Built static from `talloc.c` alone — see build.sh.
TALLOC_VERSION=2.5.0
TALLOC_URL="https://download.samba.org/pub/talloc/talloc-$TALLOC_VERSION.tar.gz"
TALLOC_SHA256=912afa237510ae542a7733998eb18a12bcda35ab6729c8e2ddb43e8d0ebab007
