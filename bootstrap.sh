#!/usr/bin/env bash
# One-click entry point for a pinned raw-file checkout (no git required).
# It never pipes a fetched third-party body to a shell and never runs a third-party script.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

REF=${SSOWN_REF:-main}
INSTALL_DIR=${SSOWN_SOURCE_DIR:-/usr/local/share/ss-2022-own}
RAW_BASE=${SSOWN_RAW_BASE:-https://raw.githubusercontent.com/charmingyi/ss-2022-own/${REF}}
RELEASE_TAG="v0.1.0"
RELEASE_ASSET_AMD64_GLIBC="ss-2022-own-linux-amd64-glibc.tar.gz"
RELEASE_ASSET_AMD64_MUSL="ss-2022-own-linux-amd64-musl.tar.gz"
# SHA-256 values of the immutable v0.1.0 archives published by this repository.
RELEASE_SHA256_AMD64_GLIBC="6ee27771389b8bafc31329671ff0bd705fb47fd0cce33930ca211a077a9f5d21"
RELEASE_SHA256_AMD64_MUSL="20dc8536307cb5e825e50f279807d1820876960707a73db8ca29decdf4ee8ca8"

# Hashes of the small, reviewed manager surface fetched from this exact REF.
# The binary Release is checked separately above and never comes from main.
SOURCE_SHA256_SSCTL="507d2a924f36a22f66d85a97dc52c3d4eb3f0ff1572b126d5a166dbb0d87b9ff"
SOURCE_SHA256_MENU="5a69d980b30235a483d11af5c0de918d1bbdd8c92a9c43cdef984de636355ca9"
SOURCE_SHA256_SS2022="23db0a29c71235ba9d44f45303ff506c325aed0c40cb1c3c8deb7d67d1ed94ea"
SOURCE_SHA256_PY="896ee400603ddf892488dce7d0c2502c0f5a9c48a7066ab1acd4937c69714711"
SOURCE_SHA256_BUILD="8d84dd0207b84bce833333589287618ca271ee5a0df90007e76811f8874572da"
SOURCE_SHA256_PATCH="9a9b9c6720429c0d3809eacd6b226ed167b49cdacd9392ae5d32acf3115d2792"
RUN_MENU=1
MODE=release

usage() {
    cat <<'EOF'
用法：
  bootstrap.sh [--release|--build] [--no-menu]

默认使用已发布的、带固定 SHA-256 的预编译核心；不需要 Go/Rust。
  --release                下载并校验预编译 Release（默认）
  --build                  在本机从固定源码重新编译后部署
  --no-menu                安装/部署后退出，不进入交互菜单

环境变量：
  SSOWN_REF          分支、tag 或 40 位提交号；生产环境建议使用 40 位提交号
  SSOWN_RAW_BASE     受控镜像的 raw 基地址（默认本项目 GitHub raw 地址）
  SSOWN_SOURCE_DIR   本地安装目录（默认 /usr/local/share/ss-2022-own）
  SSOWN_BUILD_LIBC   --build 时选择 glibc 或 musl（默认按系统：Alpine=musl）

生产环境建议把 bootstrap URL 与 SSOWN_REF 都固定到同一个已审计提交。
EOF
}

while (($#)); do
    case "$1" in
        --release) MODE=release; shift ;;
        --build) MODE=build; shift ;;
        --no-menu) RUN_MENU=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[错误] 未知参数：%s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "$RAW_BASE" == https://raw.githubusercontent.com/charmingyi/ss-2022-own/* ]] || {
    printf '%s\n' '[错误] 只接受本项目 GitHub raw 基地址。' >&2
    exit 1
}
if [[ "$REF" == *..* || "$REF" == /* || "$REF" == */ || "$REF" == *//* ]]; then
    printf '%s\n' '[错误] SSOWN_REF 含有不安全的路径片段。' >&2
    exit 1
fi
[[ "$REF" =~ ^[A-Za-z0-9._/-]+$|^[0-9a-fA-F]{40}$ ]] || {
    printf '%s\n' '[错误] SSOWN_REF 含有不允许的字符。' >&2
    exit 1
}

runtime_libc=glibc
release_asset=""
release_sha=""
if grep -Eq '^ID=alpine$|^ID_LIKE=.*alpine' /etc/os-release 2>/dev/null; then
    runtime_libc=musl
fi
if [[ "$MODE" == release ]]; then
    if [[ "$runtime_libc" == musl ]]; then
        release_asset="$RELEASE_ASSET_AMD64_MUSL"
        release_sha="$RELEASE_SHA256_AMD64_MUSL"
    else
        release_asset="$RELEASE_ASSET_AMD64_GLIBC"
        release_sha="$RELEASE_SHA256_AMD64_GLIBC"
    fi
    [[ "$release_sha" != "__RELEASE_SHA256_TBD__" && "$release_sha" != "__RELEASE_SHA256_MUSL_TBD__" ]] || {
        printf '%s\n' '[错误] 当前仓库的目标架构 Release 哈希尚未配置，请更新到正式发布提交。' >&2
        exit 1
    }
fi

for command in curl sha256sum python3; do
    command -v "$command" >/dev/null 2>&1 || { printf '[错误] 预编译/管理器安装需要 %s。\n' "$command" >&2; exit 1; }
done
if [[ "$(id -u)" -ne 0 ]]; then
    printf '%s\n' '[错误] 安装到 /usr/local/share 需要 root。' >&2
    exit 1
fi

TMP_DIR=$(mktemp -d -t ssown-bootstrap.XXXXXX)
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

fetch_checked_file() {
    local relative=$1 expected=$2 safe_name
    safe_name=${relative//\//__}
    FETCHED_FILE="$TMP_DIR/$safe_name"
    printf '[bootstrap] 获取并校验管理文件：%s\n' "$relative"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 15 --max-time 300 \
        "$RAW_BASE/$relative" -o "$FETCHED_FILE"
    printf '%s  %s\n' "$expected" "$FETCHED_FILE" | sha256sum -c - >&2
    [[ -s "$FETCHED_FILE" ]] || { printf '[错误] 下载文件为空：%s\n' "$relative" >&2; exit 1; }
}

fetch_checked_file ssctl.sh "$SOURCE_SHA256_SSCTL"
ssctl_file="$FETCHED_FILE"
fetch_checked_file menu.sh "$SOURCE_SHA256_MENU"
menu_file="$FETCHED_FILE"
fetch_checked_file ss-2022.sh "$SOURCE_SHA256_SS2022"
ss2022_file="$FETCHED_FILE"
fetch_checked_file lib/ssctl.py "$SOURCE_SHA256_PY"
python_file="$FETCHED_FILE"
fetch_checked_file build-core.sh "$SOURCE_SHA256_BUILD"
build_file="$FETCHED_FILE"
fetch_checked_file patches/shadowsocks-rust-build-time.patch "$SOURCE_SHA256_PATCH"
patch_file="$FETCHED_FILE"

install -d -m 0755 "$INSTALL_DIR"
# Copy only verified regular files; no remote file is executed before hashes pass.
install -m 0755 "$ssctl_file" "$INSTALL_DIR/ssctl.sh"
install -m 0755 "$menu_file" "$INSTALL_DIR/menu.sh"
install -m 0755 "$ss2022_file" "$INSTALL_DIR/ss-2022.sh"
install -m 0755 "$build_file" "$INSTALL_DIR/build-core.sh"
install -d -m 0755 "$INSTALL_DIR/lib" "$INSTALL_DIR/patches"
install -m 0644 "$python_file" "$INSTALL_DIR/lib/ssctl.py"
install -m 0644 "$patch_file" "$INSTALL_DIR/patches/shadowsocks-rust-build-time.patch"

if [[ "$MODE" == release ]]; then
    release_arch=$(uname -m)
    case "$release_arch" in
        x86_64|amd64) release_arch=amd64 ;;
        *) printf '[错误] 当前预编译 Release 暂未提供架构：%s；请使用 --build 或等待对应 Release。\n' "$release_arch" >&2; exit 1 ;;
    esac
    archive="$TMP_DIR/$release_asset"
    release_url="https://github.com/charmingyi/ss-2022-own/releases/download/${RELEASE_TAG}/${release_asset}"
    printf '[bootstrap] 下载并校验预编译核心：%s/%s\n' "$RELEASE_TAG" "$runtime_libc"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 15 --max-time 600 "$release_url" -o "$archive"
    printf '%s  %s\n' "$release_sha" "$archive" | sha256sum -c -
    package_root=$(python3 - "$archive" "$TMP_DIR/package" "$release_arch" "$runtime_libc" <<'PY'
import hashlib
import json
import pathlib
import posixpath
import sys
import tarfile

archive, destination, expected_arch, expected_libc = sys.argv[1:]
destination = pathlib.Path(destination)
destination.mkdir(mode=0o700)
with tarfile.open(archive, "r:gz") as tf:
    members = tf.getmembers()
    top_levels = set()
    for member in members:
        name = member.name
        if name.startswith("/") or "\x00" in name:
            raise SystemExit(f"拒绝不安全归档成员: {name!r}")
        normalized = posixpath.normpath(name)
        if normalized == ".." or normalized.startswith("../"):
            raise SystemExit(f"拒绝路径穿越归档成员: {name!r}")
        if member.issym() or member.islnk() or not (member.isdir() or member.isreg()):
            raise SystemExit(f"拒绝归档链接或特殊文件: {name!r}")
        top_levels.add(normalized.split("/", 1)[0])
    if len(top_levels) != 1:
        raise SystemExit("归档必须只有一个顶层目录")
    tf.extractall(destination)

root = destination / next(iter(top_levels))
required = {"ssserver", "xray", "manifest.json", "SHA256SUMS"}
if {p.name for p in root.iterdir()} < required:
    raise SystemExit("Release 归档缺少核心或清单文件")
for name in required:
    path = root / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"拒绝非普通 Release 文件: {path}")

manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
if manifest.get("project") != "ss-2022-own" or manifest.get("target", {}).get("arch") != expected_arch:
    raise SystemExit("Release manifest 项目或架构不匹配")
if manifest.get("target", {}).get("libc") != expected_libc:
    raise SystemExit("Release manifest libc 不匹配")

checks = {}
for line in (root / "SHA256SUMS").read_text(encoding="ascii").splitlines():
    digest, name = line.split(None, 1)
    checks[name.lstrip("*")] = digest
for name in ("ssserver", "xray"):
    h = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if checks.get(name) != h or manifest["artifacts"][name]["sha256"] != h:
        raise SystemExit(f"Release 内部哈希不匹配: {name}")
    (root / name).chmod(0o755)
print(root)
PY
)
    "$INSTALL_DIR/ssctl.sh" deploy --ss "$package_root/ssserver" --xray "$package_root/xray"
    printf '%s\n' '[bootstrap] 预编译核心已校验并部署；未在服务器编译。'
else
    build_arch=$(uname -m)
    case "$build_arch" in
        x86_64|amd64) build_arch=amd64 ;;
        aarch64|arm64) build_arch=arm64 ;;
        *) printf '[错误] 不支持的本机架构：%s\n' "$build_arch" >&2; exit 1 ;;
    esac
    build_libc=${SSOWN_BUILD_LIBC:-$runtime_libc}
    [[ "$build_libc" == glibc || "$build_libc" == musl ]] || {
        printf '[错误] SSOWN_BUILD_LIBC 必须是 glibc 或 musl。\n' >&2
        exit 1
    }
    printf '[bootstrap] 开始本地源码构建（%s/%s）。\n' "$build_arch" "$build_libc"
    "$INSTALL_DIR/build-core.sh" --core all --arch "$build_arch" --libc "$build_libc"
    "$INSTALL_DIR/ssctl.sh" deploy \
        --ss "$INSTALL_DIR/dist/ssserver-${build_arch}-${build_libc}" \
        --xray "$INSTALL_DIR/dist/xray-${build_arch}-static"
    printf '%s\n' '[bootstrap] 本地构建核心已部署。'
fi

install -d -m 0755 /usr/local/bin
install_global_link() {
    local target="$INSTALL_DIR/$1"
    local link="/usr/local/bin/$2"
    if [[ -L "$link" && "$(readlink -- "$link")" == "$target" ]]; then
        return 0
    fi
    if [[ -e "$link" || -L "$link" ]]; then
        printf '[警告] 已存在非本项目命令，保留不覆盖：%s\n' "$link" >&2
        return 0
    fi
    ln -s -- "$target" "$link"
}
install_global_link menu.sh menu
install_global_link ss-2022.sh ss-2022

if ((RUN_MENU == 1)); then
    exec "$INSTALL_DIR/menu.sh"
fi
