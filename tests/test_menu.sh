#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(mktemp -d -t ssown-menu-test.XXXXXX)
trap 'rm -rf -- "$ROOT"' EXIT

export SSOWN_ROOT="$ROOT"
export SSOWN_NO_SYSTEMD=1

output=$(printf '0\n' | "$PROJECT_DIR/ssctl.sh" menu)
for expected in \
  '安装/覆盖 Shadowsocks 2022' \
  '安装/覆盖 VLESS Reality' \
  '安装/覆盖 VLESS Encryption' \
  '节点管理（查看/删除）' \
  '服务管理（启停/重启）' \
  '防火墙管理（显式操作）' \
  '核心管理/版本/校验' \
  '卸载节点'; do
    grep -Fq "$expected" <<<"$output" || {
        printf 'menu item missing: %s\n' "$expected" >&2
        exit 1
    }
done

nested=$(printf '4\n0\n0\n' | "$PROJECT_DIR/ssctl.sh" menu)
grep -Fq '=== 节点管理 ===' <<<"$nested"

printf '%s\n' 'menu tests: OK'
