# What the browser's Linux is built from. Sourced by build.sh.

# The guest: the same Alpine release the native platforms install, in the
# architecture v86 emulates.
ALPINE=3.24.1

# The emulator, from npm, checked against the registry's integrity string. The
# BIOS images are not in the package, so they come from the repository at the
# commit the package was built from (its version's +g suffix).
V86_VERSION=0.5.462
V86_INTEGRITY=sha512-aKPX7DdzqAKFRv2omDkqSju0uEzlOxzo+II82J5UT7+tZNsboA6kyaNq9NKAnxvo9hzpJ8dQj7vcvcz0J7I2QA==
V86_COMMIT=5f9a90f2be01243dd0ea4fe014cce12686cf3ced
SEABIOS_SHA256=73e3f359102e3a9982c35fce98eb7cd08f18303ac7f1ba6ebfbe6cdc1c244d98
VGABIOS_SHA256=a4bc0d80cc3ca028c73dafa8fee396b8d054ce87ebd8abfbd31b06b437607880

# How the disk is cut for the browser to fetch: what a read pulls in at least.
CHUNK_BYTES=1048576
