# What is bundled, and what it was checked to be. Bumping any of these is the
# whole of an update: the CI cache is keyed on this file, so the next run
# rebuilds.
#
# git, curl and OpenSSL were here too, until Alpine's `apk` answered for them.
# See "Bundled tools" in lib/data/local/CLAUDE.md.

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

# llama.cpp, which is the whole of running a model on the device: its server
# speaks the same `/chat/completions` shape as every hosted provider, so a model
# on the phone reaches the agent through the client that was already there.
#
# Security-relevant like the three above and more so: it parses GGUF files
# fetched off the internet, in a process of this app's own.
#
# A release tag rather than a branch, and the tarball GitHub generates for one —
# the same bargain proot makes above.
LLAMA_CPP_VERSION=b10509
LLAMA_CPP_URL="https://github.com/ggml-org/llama.cpp/archive/refs/tags/$LLAMA_CPP_VERSION.tar.gz"
LLAMA_CPP_SHA256=63eb7bb55a46051ca523a670621cfaa6f4a1b3ea78e1cfc34a45c0af5139df0e

# The one thing the Vulkan GPU backend's cmake wants that neither the NDK nor
# llama.cpp carries: `find_package(SPIRV-Headers CONFIG REQUIRED)` before it
# builds a line. Header-only — build.sh installs it for its cmake config and
# the `spirv.hpp` the backend includes, and compiles none of it. GitHub's tag
# tarball, pinned like the rest.
SPIRV_HEADERS_VERSION=vulkan-sdk-1.4.321.0
SPIRV_HEADERS_URL="https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/$SPIRV_HEADERS_VERSION.tar.gz"
SPIRV_HEADERS_SHA256=5bbea925663d4cd2bab23efad53874f2718248a73dcaf9dd21dff8cb48e602fc

# The Vulkan headers the backend compiles against. The NDK sysroot ships the C
# ones but not `vulkan.hpp`, the C++ bindings ggml-vulkan includes — so the full
# set comes from here, and only the loader (`libvulkan.so`) is still the NDK's.
# Same SDK tag as SPIRV-Headers above, so the two move together. Header-only:
# build.sh points the compiler at `include/` and unpacks nothing else.
VULKAN_HEADERS_VERSION=vulkan-sdk-1.4.321.0
VULKAN_HEADERS_URL="https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/$VULKAN_HEADERS_VERSION.tar.gz"
VULKAN_HEADERS_SHA256=17f8ff30fd79fb7531efcb7c78c02c17a595208d482a150f06836b0ca97ef8f2

# The Hexagon SDK, which the NPU backend is built against. Fetched by
# tool/android/setup.sh; build.sh uses it if it is there.
#
# The one entry here that is not the upstream project's own tarball. Qualcomm
# ships this through an installer that wants a package manager on the host, so
# this is the Community Edition repackaged by the maintainer of llama.cpp's
# Hexagon backend — the same artifact llama.cpp's own CI builds in. Nobody
# signs it, which is what the sha256 below is for.
HEXAGON_SDK_VERSION=6.6.0.0
HEXAGON_SDK_URL="https://github.com/snapdragon-toolchain/hexagon-sdk/releases/download/v$HEXAGON_SDK_VERSION/hexagon-sdk-v$HEXAGON_SDK_VERSION-amd64-lnx.tar.xz"
HEXAGON_SDK_SHA256=4a916e42c1dab9efdf2e58773f901ea780fa43c907bf054ab76572a3b3d942f4
