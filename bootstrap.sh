#!/usr/bin/env bash
# One-click entry point for a pinned repository checkout.
# It never pipes a fetched third-party body to a shell and never runs a third-party script.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

REPO_URL=${SSOWN_REPO_URL:-https://github.com/CHANGE_ME/ss-2022-own.git}
REF=${SSOWN_REF:-main}
INSTALL_DIR=${SSOWN_SOURCE_DIR:-/usr/local/share/ss-2022-own}
RUN_MENU=1
BUILD=0

usage() {
    cat <<'EOF'
用法：
  bootstrap.sh [--no-menu] [--build]

环境变量：
  SSOWN_REPO_URL     发布后的 GitHub 仓库 URL（默认值需要替换）
  SSOWN_REF          分支、tag 或 40 位提交号；生产环境建议使用 40 位提交号
  SSOWN_SOURCE_DIR   本地安装目录（默认 /usr/local/share/ss-2022-own）
  SSOWN_BUILD_LIBC   --build 时选择 glibc 或 musl（默认 glibc）

示例（把 <commit> 换成已审计提交）：
  curl --fail --proto '=https' --tlsv1.2 -fsSL \
    https://raw.githubusercontent.com/<owner>/<repo>/<commit>/bootstrap.sh \
    | SSOWN_REF=<commit> bash
EOF
}

while (($#)); do
    case "$1" in
        --no-menu) RUN_MENU=0; shift ;;
        --build) BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[错误] 未知参数：%s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "$REPO_URL" == *CHANGE_ME* ]]; then
    printf '%s\n' '[错误] 请设置 SSOWN_REPO_URL，或先在发布前替换 bootstrap.sh 中的占位符。' >&2
    exit 1
fi
[[ "$REPO_URL" == https://github.com/* ]] || {
    printf '%s\n' '[错误] 只接受 https://github.com/ 下的仓库地址。' >&2
    exit 1
}
[[ "$REF" =~ ^[A-Za-z0-9._/-]+$|^[0-9a-fA-F]{40}$ ]] || {
    printf '%s\n' '[错误] SSOWN_REF 含有不允许的字符。' >&2
    exit 1
}

command -v git >/dev/null 2>&1 || { printf '%s\n' '[错误] 需要 git。' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '%s\n' '[错误] 需要 python3。' >&2; exit 1; }

TMP_DIR=$(mktemp -d -t ssown-bootstrap.XXXXXX)
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

printf '[bootstrap] 获取固定仓库引用：%s\n' "$REF"
git -C "$TMP_DIR" init --quiet
git -C "$TMP_DIR" remote add origin "$REPO_URL"
git -C "$TMP_DIR" fetch --quiet --depth 1 origin "$REF"
git -C "$TMP_DIR" checkout --quiet --detach FETCH_HEAD

if [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
    actual=$(git -C "$TMP_DIR" rev-parse HEAD)
    [[ "$actual" == "$REF" ]] || {
        printf '[错误] 远端返回提交 %s，而不是要求的 %s。\n' "$actual" "$REF" >&2
        exit 1
    }
fi

for required in ssctl.sh lib/ssctl.py build-core.sh; do
    [[ -f "$TMP_DIR/$required" && ! -L "$TMP_DIR/$required" ]] || {
        printf '[错误] 仓库缺少或拒绝符号链接：%s\n' "$required" >&2
        exit 1
    }
done

if [[ "$(id -u)" -ne 0 ]]; then
    printf '%s\n' '[错误] 安装到 /usr/local/share 需要 root。' >&2
    exit 1
fi

install -d -m 0755 "$INSTALL_DIR"
# Copy only reviewed regular files; no remote file is executed before this check.
install -m 0755 "$TMP_DIR/ssctl.sh" "$INSTALL_DIR/ssctl.sh"
install -m 0755 "$TMP_DIR/build-core.sh" "$INSTALL_DIR/build-core.sh"
install -d -m 0755 "$INSTALL_DIR/lib"
install -m 0644 "$TMP_DIR/lib/ssctl.py" "$INSTALL_DIR/lib/ssctl.py"

printf '[bootstrap] 已安装到：%s\n' "$INSTALL_DIR"
if ((BUILD == 1)); then
    build_arch=$(uname -m)
    case "$build_arch" in
        x86_64|amd64) build_arch=amd64 ;;
        aarch64|arm64) build_arch=arm64 ;;
        *) printf '[错误] 不支持的本机架构：%s\n' "$build_arch" >&2; exit 1 ;;
    esac
    build_libc=${SSOWN_BUILD_LIBC:-glibc}
    [[ "$build_libc" == glibc || "$build_libc" == musl ]] || {
        printf '[错误] SSOWN_BUILD_LIBC 必须是 glibc 或 musl。\n' >&2
        exit 1
    }
    printf '[bootstrap] 开始本地源码构建（%s/%s）；只会使用 build-core.sh 中固定的源归档和校验值。\n' "$build_arch" "$build_libc"
    "$INSTALL_DIR/build-core.sh" --core all --arch "$build_arch" --libc "$build_libc"
    "$INSTALL_DIR/ssctl.sh" deploy \
        --ss "$INSTALL_DIR/dist/ssserver-${build_arch}-${build_libc}" \
        --xray "$INSTALL_DIR/dist/xray-${build_arch}-static"
    printf '%s\n' '[bootstrap] 核心已部署；现在进入管理菜单。'
fi

if ((RUN_MENU == 1)); then
    exec "$INSTALL_DIR/ssctl.sh" menu
fi
