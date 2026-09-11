#!/usr/bin/env bash
# Shell menu facade modeled after the upstream one-click/menu UX.
# The backend remains our local ssctl.py; no third-party menu is executed.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REMOTE_REF=${SSOWN_REF:-main}
[[ "$REMOTE_REF" =~ ^[A-Za-z0-9._/-]+$|^[0-9a-fA-F]{40}$ ]] || {
    printf '%s\n' '[错误] SSOWN_REF 含有不允许的字符。' >&2
    exit 1
}
[[ "$REMOTE_REF" != *..* && "$REMOTE_REF" != /* && "$REMOTE_REF" != */ && "$REMOTE_REF" != *//* ]] || {
    printf '%s\n' '[错误] SSOWN_REF 含有不安全的路径片段。' >&2
    exit 1
}
REPO_RAW_BASE=${SSOWN_RAW_BASE:-https://raw.githubusercontent.com/charmingyi/ss-2022-own/${REMOTE_REF}}

if [[ ! -f "$SCRIPT_DIR/ssctl.sh" || ! -f "$SCRIPT_DIR/lib/ssctl.py" ]]; then
    command -v curl >/dev/null 2>&1 || { printf '%s\n' '[错误] 远程一键模式需要 curl。' >&2; exit 1; }
    # A streamed menu has no local backend. Bootstrap installs the verified
    # precompiled core and then re-enters this local menu facade.
    exec bash <(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$REPO_RAW_BASE/bootstrap.sh") --release
fi

SSCTL="$SCRIPT_DIR/ssctl.sh"
readonly GREEN='\033[0;32m'
readonly CYAN='\033[0;36m'
readonly RED='\033[0;31m'
readonly RESET='\033[0m'

pause_menu() {
    [[ -t 0 ]] || return 0
    read -r -p '按回车返回主菜单...' _ || true
}

show_menu() {
    clear 2>/dev/null || true
    printf '%b\n' "${GREEN}============================================${RESET}"
    printf '%b\n' "${GREEN}       ss-2022-own 统一管理菜单${RESET}"
    printf '%b\n' "${GREEN}============================================${RESET}"
    "$SSCTL" status || true
    printf '%b\n' "${CYAN}--------------------------------------------${RESET}"
    printf '%s\n' ' 1. Shadowsocks 2022 安装管理'
    printf '%s\n' ' 2. VLESS Reality 安装管理'
    printf '%s\n' ' 3. VLESS Encryption 安装管理'
    printf '%s\n' ' 4. 节点管理（查看/删除）'
    printf '%s\n' ' 5. 服务管理（启停/重启）'
    printf '%s\n' ' 6. 配置与分享'
    printf '%s\n' ' 7. 运行日志'
    printf '%s\n' ' 8. 防火墙管理（显式操作）'
    printf '%s\n' ' 9. 核心管理/版本/校验'
    printf '%s\n' '10. 卸载节点'
    printf '%s\n' ' 0. 退出'
    printf '%b\n' "${CYAN}--------------------------------------------${RESET}"
}

main() {
    [[ "$(id -u)" -eq 0 ]] || { printf '%s\n' '[错误] 请以 root 运行菜单。' >&2; exit 1; }
    while true; do
        show_menu
        read -r -p '请输入选项 [0-10]: ' choice || exit 0
        case "$choice" in
            1) "$SSCTL" menu --section ss; pause_menu ;;
            2) "$SSCTL" menu --section reality; pause_menu ;;
            3) "$SSCTL" menu --section encryption; pause_menu ;;
            4) "$SSCTL" menu --section nodes; pause_menu ;;
            5) "$SSCTL" menu --section services; pause_menu ;;
            6) "$SSCTL" menu --section config; pause_menu ;;
            7) "$SSCTL" logs all || true; pause_menu ;;
            8) "$SSCTL" menu --section firewall; pause_menu ;;
            9) "$SSCTL" menu --section core; pause_menu ;;
            10) "$SSCTL" menu --section remove; pause_menu ;;
            0) printf '%s\n' '感谢使用，再见！'; exit 0 ;;
            *) printf '%b\n' "${RED}[错误] 请输入 0-10。${RESET}"; pause_menu ;;
        esac
    done
}

main "$@"
