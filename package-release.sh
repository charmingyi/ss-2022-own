#!/usr/bin/env bash
# Package already-built cores for an immutable GitHub Release asset.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export TZ=UTC LANG=C LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RELEASE_TAG=${SSOWN_RELEASE_TAG:-v0.1.0}
ARCH=${SSOWN_RELEASE_ARCH:-amd64}
LIBC=${SSOWN_RELEASE_LIBC:-glibc}
DIST_ROOT=${SSOWN_DIST_ROOT:-"${SCRIPT_DIR}/dist"}
OUT_ROOT=${SSOWN_RELEASE_ROOT:-"${SCRIPT_DIR}/release"}

fatal() { printf '[release][error] %s\n' "$*" >&2; exit 1; }
for command in jq sha256sum tar gzip file readelf; do
    command -v "$command" >/dev/null 2>&1 || fatal "缺少命令：$command"
done
case "$ARCH" in amd64) ;; *) fatal '当前发布脚本只打包 amd64；设置 SSOWN_RELEASE_ARCH=amd64。' ;; esac
case "$LIBC" in glibc|musl) ;; *) fatal '预编译发布的 libc 必须是 glibc 或 musl。' ;; esac

ss_binary="${DIST_ROOT}/ssserver-${ARCH}-${LIBC}"
xray_binary="${DIST_ROOT}/xray-${ARCH}-static"
build_manifest="${DIST_ROOT}/manifest-${ARCH}-${LIBC}.json"
for path in "$ss_binary" "$xray_binary" "$build_manifest"; do
    [[ -f "$path" && ! -L "$path" ]] || fatal "缺少构建产物或清单：$path"
done

release_name="ss-2022-own-linux-${ARCH}-${LIBC}"
stage_root="${OUT_ROOT}/stage"
stage_dir="${stage_root}/${release_name}"
asset="${OUT_ROOT}/${release_name}.tar.gz"
rm -rf "$OUT_ROOT"
mkdir -p "$stage_dir"
chmod 700 "$OUT_ROOT" "$stage_root"
install -m 0755 "$ss_binary" "$stage_dir/ssserver"
install -m 0755 "$xray_binary" "$stage_dir/xray"

ss_hash=$(sha256sum "$stage_dir/ssserver" | awk '{print $1}')
xray_hash=$(sha256sum "$stage_dir/xray" | awk '{print $1}')
manifest_tmp="$stage_dir/.manifest.json.new.$$"
jq -n --slurpfile source "$build_manifest" \
    --arg release "$RELEASE_TAG" --arg arch "$ARCH" --arg libc "$LIBC" \
    --arg ss_hash "$ss_hash" --arg xray_hash "$xray_hash" \
    '{project:"ss-2022-own",release:$release,target:{os:"linux",arch:$arch,libc:$libc},source:$source[0].source,toolchain:$source[0].toolchain,artifacts:{ssserver:{file:"ssserver",sha256:$ss_hash},xray:{file:"xray",sha256:$xray_hash}}}' \
    > "$manifest_tmp"
chmod 0644 "$manifest_tmp"
mv -f -- "$manifest_tmp" "$stage_dir/manifest.json"

sha256sum "$stage_dir/ssserver" "$stage_dir/xray" > "$stage_dir/SHA256SUMS"
chmod 0644 "$stage_dir/manifest.json" "$stage_dir/SHA256SUMS"
# Normalize order, ownership and timestamps; gzip -n removes its timestamp.
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -cf - -C "$stage_root" "$release_name" | gzip -n -9 > "$asset"
chmod 0644 "$asset"

printf 'asset=%s\n' "$asset"
printf 'sha256='; sha256sum "$asset" | awk '{print $1}'
printf 'size='; stat -c '%s' "$asset"
printf 'manifest=%s\n' "$stage_dir/manifest.json"
file "$asset"
