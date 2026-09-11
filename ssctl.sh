#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' '[错误] 需要 python3；本项目不会自动执行远程安装脚本。' >&2
    exit 1
fi

exec python3 "${SCRIPT_DIR}/lib/ssctl.py" "$@"
