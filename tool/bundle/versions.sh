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
