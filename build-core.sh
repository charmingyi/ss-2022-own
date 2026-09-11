#!/usr/bin/env bash
# Build only pinned upstream cores from source.  No remote script is executed.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export TZ=UTC LANG=C LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD_ROOT=${SSOWN_BUILD_ROOT:-"${SCRIPT_DIR}/.build"}
DIST_ROOT=${SSOWN_DIST_ROOT:-"${SCRIPT_DIR}/dist"}
[[ "$BUILD_ROOT" = /* ]] || BUILD_ROOT="${SCRIPT_DIR}/${BUILD_ROOT}"
[[ "$DIST_ROOT" = /* ]] || DIST_ROOT="${SCRIPT_DIR}/${DIST_ROOT}"
SOURCE_ROOT="${BUILD_ROOT}/sources"

# These versions were selected deliberately:
# - shadowsocks-rust v1.24.0: AEAD-2022 support, build-time 0.1.3, signed tag.
# - Xray v25.9.11: includes VLESS Encryption PR #5067 and REALITY.
SS_VERSION="1.24.0"
SS_COMMIT="7ee1aa9223ed8f4d34734aac919036c8ad4502c2"
SS_ARCHIVE_SHA256="a89865d1c5203de1b732017dd032e85f943d1592e8d3152eb7d2c4f3fca387bf"
SS_SOURCE_URL="https://codeload.github.com/shadowsocks/shadowsocks-rust/tar.gz/refs/tags/v${SS_VERSION}"
SS_SOURCE_DATE_EPOCH="1765409939"
SS_BUILD_TIME="2025-12-10T23:38:59.000000000+00:00"
SS_PATCH_FILE="${SCRIPT_DIR}/patches/shadowsocks-rust-build-time.patch"
SS_PATCH_SHA256="9a9b9c6720429c0d3809eacd6b226ed167b49cdacd9392ae5d32acf3115d2792"

XRAY_VERSION="25.9.11"
XRAY_COMMIT="3edfb0e33557330ac721862adb2e4be89ee7412a"
XRAY_ARCHIVE_SHA256="9bccd2681183698bf860b1af5407f97b4b60090324aa3ef1546e446612d44e1f"
XRAY_SOURCE_URL="https://codeload.github.com/XTLS/Xray-core/tar.gz/refs/tags/v${XRAY_VERSION}"
XRAY_SOURCE_DATE_EPOCH="1757504827"

CORE="all"
ARCH="native"
LIBC="musl"
OFFLINE=0

# Do not let a caller's ambient build flags or toolchain auto-switch alter the
# binary.  Dependency caches remain usable, but their lock/sum checks stay on.
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS RUSTC_WRAPPER GOFLAGS GOEXPERIMENT RUSTC_BOOTSTRAP GONOSUMDB GOPRIVATE CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS || true
export CARGO_BUILD_JOBS=1
export GOENV=off
export GOWORK=off

log() { printf '[build] %s\n' "$*" >&2; }
fatal() { printf '[build][error] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法：
  ./build-core.sh [选项]

选项：
  --core ss|xray|all       构建哪个核心（默认 all）
  --arch native|amd64|arm64
                           目标架构（默认 native）
  --libc musl|glibc       SS 的链接目标；musl 默认静态，glibc 需对应交叉工具链
  --offline                只使用本地依赖缓存，不访问依赖镜像
  -h, --help               显示帮助

产物写入 dist/，之后可用：
  ./ssctl.sh deploy --ss dist/ssserver-<arch>-<libc> --xray dist/xray-<arch>-static
EOF
}

while (($#)); do
    case "$1" in
        --core) [[ $# -ge 2 ]] || fatal '--core 缺少值'; CORE=$2; shift 2 ;;
        --arch) [[ $# -ge 2 ]] || fatal '--arch 缺少值'; ARCH=$2; shift 2 ;;
        --libc) [[ $# -ge 2 ]] || fatal '--libc 缺少值'; LIBC=$2; shift 2 ;;
        --offline) OFFLINE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fatal "未知参数：$1" ;;
    esac
done

case "$CORE" in ss|xray|all) ;; *) fatal "--core 必须是 ss、xray 或 all" ;; esac
case "$ARCH" in native) ;; amd64|x86_64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; *) fatal "--arch 必须是 native、amd64 或 arm64" ;; esac
case "$LIBC" in musl|glibc) ;; *) fatal "--libc 必须是 musl 或 glibc" ;; esac

if [[ "$ARCH" == native ]]; then
    case "$(uname -m)" in
        x86_64|amd64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) fatal "无法从 uname -m 推断目标架构：$(uname -m)" ;;
    esac
fi

case "$ARCH" in
    amd64)
        GOARCH=amd64
        if [[ "$LIBC" == musl ]]; then
            RUST_TARGET=x86_64-unknown-linux-musl
            LINKER=musl-gcc
        else
            RUST_TARGET=x86_64-unknown-linux-gnu
            LINKER=gcc
        fi
        ;;
    arm64)
        GOARCH=arm64
        if [[ "$LIBC" == musl ]]; then
            RUST_TARGET=aarch64-unknown-linux-musl
            LINKER=aarch64-linux-musl-gcc
        else
            RUST_TARGET=aarch64-unknown-linux-gnu
            LINKER=aarch64-linux-gnu-gcc
        fi
        ;;
esac

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "缺少命令 $1；请按 docs/BUILD.md 安装构建依赖。"
}
for command in curl sha256sum tar jq file readelf; do require_command "$command"; done

version_at_least() {
    local actual=$1 minimum=$2
    [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

rust_toolchain_version='not-used'
go_toolchain_version='not-used'
ss_patch_actual='not-used'
ss_build_time='not-used'

if [[ "$CORE" == ss || "$CORE" == all ]]; then
    require_command cargo
    require_command rustc
    rust_toolchain_version=$(rustc --version)
    rust_version=$(awk '{print $2}' <<<"$rust_toolchain_version")
    version_at_least "$rust_version" "1.88.0" || fatal "Rust $rust_version 低于 v1.24.0 的 MSRV 1.88.0。"
    require_command "$LINKER"
    require_command patch
    [[ -f "$SS_PATCH_FILE" ]] || fatal "缺少固定的可复现性补丁：$SS_PATCH_FILE"
    ss_patch_actual=$(sha256sum "$SS_PATCH_FILE" | awk '{print $1}')
    [[ "$ss_patch_actual" == "$SS_PATCH_SHA256" ]] || \
        fatal "可复现性补丁哈希不匹配：$SS_PATCH_FILE"
    if [[ "$LIBC" == musl ]]; then
        command -v rustup >/dev/null 2>&1 || fatal "musl 构建需要 rustup 管理的 ${RUST_TARGET} target。"
        installed_targets=$(rustup target list --installed 2>/dev/null || true)
        grep -Eq "^${RUST_TARGET}([[:space:]]|$)" <<<"$installed_targets" || \
            fatal "未安装 Rust target ${RUST_TARGET}；请先执行 rustup target add ${RUST_TARGET}。"
    fi
fi

if [[ "$CORE" == xray || "$CORE" == all ]]; then
    require_command go
    go_toolchain_version=$(go version)
    go_version=$(awk '{print $3}' <<<"$go_toolchain_version" | sed 's/^go//')
    version_at_least "$go_version" "1.25.0" || fatal "Go $go_version 低于 Xray v25.9.11 的 go 1.25 要求。"
fi

mkdir -p "$SOURCE_ROOT" "$DIST_ROOT"
chmod 700 "$BUILD_ROOT" "$SOURCE_ROOT" "$DIST_ROOT"

validate_archive() {
    local archive=$1 entries bad_types entry
    entries=$(tar -tzf "$archive") || fatal "无法读取源归档：$archive"
    [[ -n "$entries" ]] || fatal "源归档为空：$archive"
    while IFS= read -r entry; do
        case "$entry" in
            /*|../*|*/../*|*/..|..|*\\\\*) fatal "拒绝不安全归档成员：$entry" ;;
        esac
    done <<< "$entries"
    bad_types=$(tar -tvzf "$archive" | awk '{t=substr($1,1,1); if (t=="l" || t=="h" || t=="b" || t=="c" || t=="p" || t=="s") print $1}' || true)
    [[ -z "$bad_types" ]] || fatal "拒绝归档中的链接或特殊文件：$archive"
}

fetch_source() {
    local name=$1 version=$2 url=$3 expected_sha=$4 source_date=$5
    local archive="${SOURCE_ROOT}/${name}-${version}.tar.gz"
    local source_dir="${SOURCE_ROOT}/${name}-${version}"
    if [[ ! -f "$archive" ]]; then
        ((OFFLINE == 1)) && fatal "--offline 下缺少源归档：$archive"
        log "下载固定版本源归档：${name} v${version}"
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$archive"
    fi
    # Re-verify and re-extract on every invocation so a modified cache tree is
    # never silently compiled.  The archive hash is the immutable input.
    printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum -c - >&2
    validate_archive "$archive"
    rm -rf "$source_dir"
    tar --extract --gzip --file "$archive" --directory "$SOURCE_ROOT" --no-same-owner --no-same-permissions
    [[ -d "$source_dir" ]] || fatal "归档解压后目录名不符合预期：$source_dir"
    # The archive is a GitHub snapshot of the signed tag commit.  Keep the
    # exact commit in the manifest and make the epoch explicit for builds.
    printf '%s\n' "$source_date" > "$source_dir/.ssown-source-date-epoch"
    printf '%s\n' "$source_dir"
}

verify_binary() {
    local path=$1
    [[ -x "$path" ]] || fatal "构建产物不可执行：$path"
    file "$path"
    if [[ "$LIBC" == musl ]]; then
        local program_headers dynamic_section
        program_headers=$(readelf -lW "$path" 2>/dev/null || true)
        dynamic_section=$(readelf -dW "$path" 2>/dev/null || true)
        if grep -q 'INTERP' <<<"$program_headers"; then
            fatal "musl/static 产物带动态 ELF interpreter：$path"
        fi
        if grep -q 'NEEDED' <<<"$dynamic_section"; then
            fatal "musl/static 产物仍依赖外部共享库：$path"
        fi
    else
        local highest_glibc
        highest_glibc=$(readelf --version-info --wide "$path" 2>/dev/null \
            | grep -oE 'GLIBC_[0-9]+(\\.[0-9]+)+' | sort -Vu | tail -n1 || true)
        if [[ -n "$highest_glibc" ]] && [[ "$(printf '%s\\n%s\\n' "$highest_glibc" 'GLIBC_2.36' | sort -V | tail -n1)" != 'GLIBC_2.36' ]]; then
            fatal "glibc 产物需要 ${highest_glibc}，超过兼容下限 GLIBC_2.36：$path"
        fi
    fi
}

build_ss() {
    local source_dir
    source_dir=$(fetch_source shadowsocks-rust "$SS_VERSION" "$SS_SOURCE_URL" "$SS_ARCHIVE_SHA256" "$SS_SOURCE_DATE_EPOCH")
    local output="${DIST_ROOT}/ssserver-${ARCH}-${LIBC}"
    log "编译 Shadowsocks Rust ${SS_VERSION} -> ${output}"
    pushd "$source_dir" >/dev/null
    patch --forward --batch --fuzz=0 -p1 < "$SS_PATCH_FILE" >/dev/null
    export SOURCE_DATE_EPOCH="$SS_SOURCE_DATE_EPOCH"
    ss_build_time="$SS_BUILD_TIME"
    export SSOWN_BUILD_TIME="$ss_build_time"
    export CARGO_TERM_COLOR=never
    cargo_home_for_remap=${CARGO_HOME:-${HOME}/.cargo}
    rust_target_env=$(printf '%s' "$RUST_TARGET" | tr '[:lower:]-' '[:upper:]_')
    export CC="$LINKER"
    export "CC_${rust_target_env}=$LINKER"
    export "CARGO_TARGET_${rust_target_env}_LINKER=$LINKER"
    export RUSTFLAGS="--remap-path-prefix=${source_dir}=/usr/src/shadowsocks --remap-path-prefix=${cargo_home_for_remap}=/usr/local/cargo -C debuginfo=0 -C link-arg=-Wl,--build-id=none"
    if [[ "$LIBC" == musl ]]; then
        export RUSTFLAGS="${RUSTFLAGS} -C linker=${LINKER} -C target-feature=+crt-static -C relocation-model=static -C link-arg=-static"
    fi
    cargo_args=(build --locked --release --no-default-features --features 'server,logging,multi-threaded,aead-cipher,aead-cipher-2022' --bin ssserver --target "$RUST_TARGET")
    ((OFFLINE == 1)) && cargo_args+=(--offline)
    cargo "${cargo_args[@]}"
    popd >/dev/null
    cp -f "$source_dir/target/${RUST_TARGET}/release/ssserver" "$output"
    chmod 755 "$output"
    verify_binary "$output"
    SS_OUTPUT="$output"
}

build_xray() {
    local source_dir
    source_dir=$(fetch_source Xray-core "$XRAY_VERSION" "$XRAY_SOURCE_URL" "$XRAY_ARCHIVE_SHA256" "$XRAY_SOURCE_DATE_EPOCH")
    local output="${DIST_ROOT}/xray-${ARCH}-static"
    log "编译 Xray ${XRAY_VERSION} -> ${output}"
    pushd "$source_dir" >/dev/null
    export CGO_ENABLED=0
    export GOOS=linux
    export GOARCH="$GOARCH"
    if [[ "$GOARCH" == amd64 ]]; then
        export GOAMD64=v1
    else
        export GOARM64=v8.0
    fi
    export GOTOOLCHAIN=local
    export GOWORK=off
    export SOURCE_DATE_EPOCH="$XRAY_SOURCE_DATE_EPOCH"
    if ((OFFLINE == 1)); then
        export GOPROXY=off
        export GOSUMDB=off
    fi
    go mod download
    go mod verify
    go_ldflags="-X github.com/xtls/xray-core/core.build=${APP_BUILD_LABEL:-ss-2022-own-${XRAY_VERSION}-${XRAY_COMMIT:0:12}} -s -w -buildid="
    go build -mod=readonly -pgo=off -trimpath -buildvcs=false -gcflags='all=-l=4' -ldflags="$go_ldflags" -o "$output" ./main
    popd >/dev/null
    chmod 755 "$output"
    verify_binary "$output"
    XRAY_OUTPUT="$output"
}

SS_OUTPUT=""
XRAY_OUTPUT=""
[[ "$CORE" == ss || "$CORE" == all ]] && build_ss
[[ "$CORE" == xray || "$CORE" == all ]] && build_xray

manifest="${DIST_ROOT}/manifest-${ARCH}-${LIBC}.json"
ss_artifact='{"path":null,"sha256":null}'
xray_artifact='{"path":null,"sha256":null}'
if [[ -n "$SS_OUTPUT" ]]; then
    ss_hash=$(sha256sum "$SS_OUTPUT" | awk '{print $1}')
    ss_artifact=$(jq -cn --arg path "$SS_OUTPUT" --arg hash "$ss_hash" '{path:$path,sha256:$hash}')
fi
if [[ -n "$XRAY_OUTPUT" ]]; then
    xray_hash=$(sha256sum "$XRAY_OUTPUT" | awk '{print $1}')
    xray_artifact=$(jq -cn --arg path "$XRAY_OUTPUT" --arg hash "$xray_hash" '{path:$path,sha256:$hash}')
fi
manifest_tmp="${manifest}.new.$$"
jq -n \
    --arg ss_version "$SS_VERSION" --arg ss_commit "$SS_COMMIT" --arg ss_archive "$SS_ARCHIVE_SHA256" \
    --arg ss_patch "$ss_patch_actual" --arg ss_build_time "$ss_build_time" --arg xray_version "$XRAY_VERSION" \
    --arg xray_commit "$XRAY_COMMIT" --arg xray_archive "$XRAY_ARCHIVE_SHA256" \
    --arg arch "$ARCH" --arg libc "$LIBC" --arg rust "$rust_toolchain_version" --arg go "$go_toolchain_version" \
    --argjson ss_epoch "$SS_SOURCE_DATE_EPOCH" --argjson xray_epoch "$XRAY_SOURCE_DATE_EPOCH" \
    --argjson ss_artifact "$ss_artifact" --argjson xray_artifact "$xray_artifact" \
    '{project:"ss-2022-own",source:{"shadowsocks-rust":{version:$ss_version,commit:$ss_commit,archive_sha256:$ss_archive,source_date_epoch:$ss_epoch,reproducibility_patch:{file:"patches/shadowsocks-rust-build-time.patch",sha256:$ss_patch,build_time:$ss_build_time}},"xray-core":{version:$xray_version,commit:$xray_commit,archive_sha256:$xray_archive,source_date_epoch:$xray_epoch}},target:{arch:$arch,libc:$libc,xray_cgo:0},toolchain:{rustc:$rust,go:$go},artifacts:{ssserver:$ss_artifact,xray:$xray_artifact}}' \
    > "$manifest_tmp"
chmod 0600 "$manifest_tmp"
mv -f -- "$manifest_tmp" "$manifest"

log "完成。产物清单：${manifest}"
[[ -n "$SS_OUTPUT" ]] && log "SS: $SS_OUTPUT"
[[ -n "$XRAY_OUTPUT" ]] && log "Xray: $XRAY_OUTPUT"
log '下一步：运行 ./ssctl.sh deploy --ss <ss产物> --xray <xray产物>，再创建节点。'
