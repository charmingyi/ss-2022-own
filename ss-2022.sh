#!/usr/bin/env bash
# Compatibility entry point modeled after the upstream ss-2022.sh launcher.
# It delegates to the audited local manager and verified precompiled release.
set -Eeuo pipefail
IFS=$'\n\t'

SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
    SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$SOURCE")" && pwd)
    SOURCE=$(readlink -- "$SOURCE")
    [[ "$SOURCE" = /* ]] || SOURCE="$SOURCE_DIR/$SOURCE"
done
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SOURCE")" && pwd)
REMOTE_REF=${SSOWN_REF:-main}
[[ "$REMOTE_REF" =~ ^[A-Za-z0-9._/-]+$|^[0-9a-fA-F]{40}$ ]] || {
    printf '%s\n' '[错误] SSOWN_REF 含有不允许的字符。' >&2
    exit 1
}
[[ "$REMOTE_REF" != *..* && "$REMOTE_REF" != /* && "$REMOTE_REF" != */ && "$REMOTE_REF" != *//* ]] || {
    printf '%s\n' '[错误] SSOWN_REF 含有不安全的路径片段。' >&2
    exit 1
}
REMOTE_BASE=${SSOWN_RAW_BASE:-https://raw.githubusercontent.com/charmingyi/ss-2022-own/${REMOTE_REF}}

if [[ -f "$SCRIPT_DIR/ssctl.sh" && -f "$SCRIPT_DIR/lib/ssctl.sh" ]]; then
    exec "$SCRIPT_DIR/ssctl.sh" menu --section ss "$@"
fi

command -v curl >/dev/null 2>&1 || { printf '%s\n' '[错误] 一键模式需要 curl。' >&2; exit 1; }
# Keep the familiar bash <(curl ...) invocation shape, but the only fetched
# script is our pinned repository bootstrap, which verifies a Release hash.
exec bash <(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$REMOTE_BASE/bootstrap.sh") --release "$@"
