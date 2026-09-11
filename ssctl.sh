#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -f "${SCRIPT_DIR}/lib/ssctl.sh" ]]; then
    printf '%s\n' '[错误] 找不到 Bash 管理后端 lib/ssctl.sh。' >&2
    exit 1
fi

exec bash "${SCRIPT_DIR}/lib/ssctl.sh" "$@"
