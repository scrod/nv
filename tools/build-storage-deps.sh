#!/bin/bash
# Build the pinned SQLCipher dependency locally; no global installation.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
dest="${NV_SQLCIPHER_DEST:-$repo/NVStorage/.deps/sqlcipher}"
sanitize=''
case "${NV_SQLCIPHER_SANITIZERS:-}" in
    '') ;;
    address|address,undefined) sanitize="-g -fno-omit-frame-pointer -fsanitize=$NV_SQLCIPHER_SANITIZERS" ;;
    *) echo 'Supported sanitizer profiles: address or address,undefined' >&2; exit 1 ;;
esac
revision=c4b275a47932888216bade83aff2bbc73df0ff85
mkdir -p "$dest"
if [[ ! -d "$dest/source/.git" ]]; then
    git clone --no-hardlinks "${NV_SQLCIPHER_SOURCE:-https://github.com/sqlcipher/sqlcipher.git}" "$dest/source"
fi
git -C "$dest/source" checkout --detach "$revision"
test "$(git -C "$dest/source" rev-parse HEAD)" = "$revision"
git -C "$dest/source" diff --exit-code
git -C "$dest/source" diff --cached --exit-code
case "$(uname -s)" in
    Darwin) crypto='-DSQLCIPHER_CRYPTO_CC'; platform='-mmacosx-version-min=11.5'; libs='-framework Security -framework CoreFoundation' ;;
    Linux) crypto='-DSQLCIPHER_CRYPTO_OPENSSL'; platform=''; libs='-lcrypto -ldl -lpthread -lm' ;;
    *) echo 'Unsupported SQLCipher build platform' >&2; exit 1 ;;
esac
mkdir -p "$dest/build" "$dest/lib/pkgconfig" "$dest/include"
cd "$dest/build"
CFLAGS="-O2 $sanitize $platform -DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown $crypto" \
LDFLAGS="$sanitize" \
    ../source/configure --disable-tcl --disable-shared --disable-load-extension --with-tempstore=always
make -j4 libsqlite3.a
cp libsqlite3.a "$dest/lib/libsqlcipher.a"
cp sqlite3.h "$dest/include/"
# Dependency metadata is a build artifact, not a second project manifest.
printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\nName: sqlcipher\nDescription: pinned NV SQLCipher\nVersion: 4.19.0\nLibs: -L${libdir} -lsqlcipher %s\nCflags: -I${includedir}\n' "$dest" "$libs" > "$dest/lib/pkgconfig/sqlcipher.pc"
echo "SQLCipher ready. PKG_CONFIG_PATH=$dest/lib/pkgconfig"
