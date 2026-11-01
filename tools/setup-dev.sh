#!/bin/sh
set -eu

# Build pinned native Linux tools; no Windows executables or router packages.
[ "$(uname -s)" = Linux ] || { printf '%s\n' 'dev-setup: нужен Linux или WSL2' >&2; exit 1; }
sdk=${JZM_DEV_HOME:-$HOME/.local/share/jzm-dev}
compiler=${CC:-cc}
project=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
variant=${1:-openwrt-25.12}
case "$variant" in
    openwrt-24.10) revision=3f64c8089bf3ea4847c96b91df09fbfcaec19e1d;;
    openwrt-25.12) revision=85922056ef7abeace3cca3ab28bc1ac2d88e31b1;;
    upstream) revision=dfc64d41fd720163ac21d9feb9cb224d1a80fd75;;
    *) printf 'dev-setup: неизвестный вариант %s\n' "$variant" >&2; exit 2;;
esac
[ "$#" -le 1 ] || exit 2
for tool in git cmake ninja pkg-config cc; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'dev-setup: нужна команда %s (см. readme.md)\n' "$tool" >&2; exit 1; }
done
prefix=$sdk/$variant
mkdir -p "$prefix" "$sdk/sources"
for component in libubox ubus uci ucode ustream-ssl uclient; do
    case "$component" in
        ustream-ssl) repo=openwrt/ustream-ssl; rev=cea28c5bc43ae80c3531c98f4e4dc67b7dcf0ebb;;
        uclient) repo=openwrt/uclient; rev=88ae8f208dd313f69e268234f7db55956aef1cb9;;
        ubus) repo=openwrt/ubus; rev=db20eff5535fe3126c05dc0edc029caf0e82fe10;;
        libubox) repo=openwrt/libubox; rev=da2d205a5cf3e877c45a2eec488218cbaf452e7d;;
        uci) repo=openwrt/uci; rev=74f6277aabffc943d026f406df57c22595134c42;;
        ucode) repo=ucode-lang/ucode; rev=$revision;;
    esac
    source_dir=$sdk/sources/$component-$rev
    if [ ! -d "$source_dir/.git" ]; then
        git init -q "$source_dir"
        git -C "$source_dir" remote add origin "https://github.com/$repo.git"
    fi
    if ! git -C "$source_dir" cat-file -e "$rev^{commit}" 2>/dev/null; then
        git -C "$source_dir" fetch --depth 1 origin "$rev"
    fi
    git -C "$source_dir" checkout --detach "$rev"
    # glibc 2.43 preserves const in strrchr(); keep older ucode warning-clean too.
    if [ "$component" = ucode ] && [ "$variant" != upstream ]; then
        if git -C "$source_dir" apply --check "$project/tools/ucode-glibc.patch" 2>/dev/null; then
            git -C "$source_dir" apply "$project/tools/ucode-glibc.patch"
        elif ! git -C "$source_dir" apply --reverse --check "$project/tools/ucode-glibc.patch" 2>/dev/null; then
            printf '%s\n' 'dev-setup: несовместимый исходник ucode для glibc patch' >&2
            exit 1
        fi
    fi
    build_dir=$source_dir/build-$variant-$(basename "$compiler")
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" cmake -S "$source_dir" -B "$build_dir" -G Ninja \
        -DCMAKE_C_COMPILER="$compiler" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_INSTALL_RPATH="$prefix/lib" \
        -DOPENSSL=ON -DDIGEST_SUPPORT=ON -DUBUS_SUPPORT=ON -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF -DRESOLV_SUPPORT=OFF -DSOCKET_SUPPORT=OFF
    cmake --build "$build_dir" --target install --parallel 2
done
printf '\nГотово: %s\nДобавьте %s/bin в PATH и выполните just bundle\n' "$variant" "$prefix"
