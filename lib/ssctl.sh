#!/usr/bin/env bash
# ss-2022-own shell backend.
# Bash 4+ only; the public entrypoint invokes this file with bash.
# No network downloader is used here.  Core binaries must already be deployed.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME='ss-2022-own'
APP_VERSION='0.1.0'
SERVICE_USER="${SSOWN_SERVICE_USER:-ssown}"
ROOT_PREFIX="${SSOWN_ROOT:-}"

rooted() {
    if [[ -n "$ROOT_PREFIX" ]]; then
        printf '%s%s' "${ROOT_PREFIX%/}" "$1"
    else
        printf '%s' "$1"
    fi
}

ETC_DIR=$(rooted '/etc/ss-2022-own')
STATE_FILE="$ETC_DIR/state.json"
SS_CONFIG="$ETC_DIR/ss.json"
XRAY_CONFIG="$ETC_DIR/xray.json"
BACKUP_DIR="$ETC_DIR/backup"
CLIENT_DIR="$ETC_DIR/clients"
BIN_DIR=$(rooted '/usr/local/libexec/ss-2022-own')
SS_BIN="${SSOWN_SS_BIN:-$BIN_DIR/ssserver}"
XRAY_BIN="${SSOWN_XRAY_BIN:-$BIN_DIR/xray}"
SYSTEMD_DIR=$(rooted '/etc/systemd/system')
OPENRC_DIR=$(rooted '/etc/init.d')
SS_SERVICE="$SYSTEMD_DIR/ss-2022-own-ss.service"
XRAY_SERVICE="$SYSTEMD_DIR/ss-2022-own-xray.service"
OPENRC_SS_SERVICE="$OPENRC_DIR/ss-2022-own-ss"
OPENRC_XRAY_SERVICE="$OPENRC_DIR/ss-2022-own-xray"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

# Keep this allow-list in lockstep with build-core.sh features.  A case
# statement is used instead of evaluating user input as an array subscript.
ss_method_bytes() {
    case "$1" in
        2022-blake3-aes-128-gcm) printf '16\n' ;;
        2022-blake3-aes-256-gcm) printf '32\n' ;;
        2022-blake3-chacha20-poly1305) printf '32\n' ;;
        2022-blake3-chacha8-poly1305) printf '32\n' ;;
        *) return 1 ;;
    esac
}

error_msg() { printf '%b[错误]%b %s\n' "$RED" "$RESET" "$*" >&2; }
info_msg() { printf '%b[信息]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn_msg() { printf '%b[警告]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { error_msg "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "缺少依赖：$1"; }

usage() {
    cat <<'EOF'
用法：
  ssctl install ss|reality|encryption [选项]
  ssctl deploy [--ss FILE] [--xray FILE]
  ssctl show [--reveal] [--server-address HOST] [--tag TAG]
  ssctl status | core-info | logs [ss|xray|all] [--lines N] | validate
  ssctl service enable|disable|start|stop|restart|status [ss|xray|all]
  ssctl remove [ss|xray|all] [--tag TAG] --yes
  ssctl firewall open|close --port PORT --protocol tcp|udp|both
  ssctl menu [--section all|ss|reality|encryption|nodes|services|config|logs|firewall|core|remove]

核心必须由受控构建或已校验 Release 预先部署。此后端不下载或执行远程脚本。
EOF
}

require_root() {
    if [[ -z "$ROOT_PREFIX" ]] && [[ "$(id -u)" -ne 0 ]]; then
        die '此操作需要 root。'
    fi
}

systemd_available() {
    [[ -z "$ROOT_PREFIX" ]] && have systemctl && [[ -d /run/systemd/system ]]
}

openrc_available() {
    [[ -z "$ROOT_PREFIX" ]] && have rc-service && have rc-update && [[ -x /sbin/openrc-run ]]
}

init_system_name() {
    if systemd_available; then
        printf '%s\n' systemd
    elif openrc_available; then
        printf '%s\n' openrc
    else
        printf '%s\n' none
    fi
}

reject_symlink() {
    [[ ! -L "$1" ]] || die "拒绝符号链接路径：$1"
}

ensure_dir() {
    local path=$1 mode=$2
    [[ ! -L "$path" ]] || die "拒绝符号链接目录：$path"
    mkdir -p -- "$path" || die "无法创建目录：$path"
    chmod "$mode" "$path" || die "无法设置目录权限：$path"
}

ensure_app_dirs() {
    ensure_dir "$ETC_DIR" 0750
    ensure_dir "$BACKUP_DIR" 0700
    ensure_dir "$CLIENT_DIR" 0700
    ensure_dir "$BIN_DIR" 0755
}

atomic_write_text() {
    local path=$1 content=$2 mode=$3 parent tmp
    parent=$(dirname -- "$path")
    mkdir -p -- "$parent" || die "无法创建文件目录：$parent"
    reject_symlink "$path"
    tmp=$(mktemp "$parent/.${path##*/}.XXXXXX") || die "无法创建临时文件：$path"
    if ! printf '%s' "$content" >"$tmp"; then
        rm -f -- "$tmp"
        die "无法写入临时文件：$path"
    fi
    chmod "$mode" "$tmp" || { rm -f -- "$tmp"; die "无法设置临时文件权限：$path"; }
    mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; die "无法原子替换文件：$path"; }
    chmod "$mode" "$path" || die "无法设置文件权限：$path"
}

service_user_ready() {
    [[ -n "$ROOT_PREFIX" ]] && return 0
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        return 0
    fi
    if have useradd; then
        useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER" \
            || die "无法创建系统用户：$SERVICE_USER"
        return 0
    fi
    if have adduser && have addgroup; then
        if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
            addgroup -S "$SERVICE_USER" || die "无法创建系统组：$SERVICE_USER"
        fi
        adduser -S -D -H -h /var/empty -s /sbin/nologin -G "$SERVICE_USER" -g "$SERVICE_USER" "$SERVICE_USER" \
            || die "无法创建 Alpine 系统用户：$SERVICE_USER"
        return 0
    fi
    die "未找到 useradd 或 Alpine adduser/addgroup。"
}

chown_service_file() {
    local path=$1
    [[ -n "$ROOT_PREFIX" ]] && return 0
    chown "root:$SERVICE_USER" "$path" || die "无法设置配置属组：$path"
}

json_write() {
    local path=$1 json=$2 mode=${3:-0640} parent tmp
    parent=$(dirname -- "$path")
    mkdir -p -- "$parent" || die "无法创建文件目录：$parent"
    reject_symlink "$path"
    tmp=$(mktemp "$parent/.${path##*/}.XXXXXX") || die "无法创建 JSON 临时文件：$path"
    if ! printf '%s' "$json" | jq -e . >"$tmp"; then
        rm -f -- "$tmp"
        die "拒绝写入非法 JSON：$path"
    fi
    chmod "$mode" "$tmp" || { rm -f -- "$tmp"; die "无法设置 JSON 临时文件权限：$path"; }
    mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; die "无法原子替换 JSON：$path"; }
    chmod "$mode" "$path" || die "无法设置 JSON 权限：$path"
    chown_service_file "$path"
}

backup_file() {
    local path=$1 stamp destination
    reject_symlink "$path"
    [[ -e "$path" ]] || return 0
    ensure_dir "$BACKUP_DIR" 0700
    stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf 'unknown')
    destination="$BACKUP_DIR/${path##*/}.${stamp}"
    cp -p -- "$path" "$destination" || die "无法备份：$path"
    chmod 0600 "$destination" || die "无法设置备份权限：$destination"
}

initial_state() {
    jq -cn --arg app "$APP_NAME" --arg version "$APP_VERSION" \
        '{schema:1,app:$app,version:$version,nodes:[]}'
}

load_state() {
    if [[ ! -e "$STATE_FILE" ]]; then
        initial_state
        return 0
    fi
    reject_symlink "$STATE_FILE"
    jq -e 'type == "object" and .schema == 1 and (.nodes | type == "array")' "$STATE_FILE" >/dev/null \
        || die "状态文件损坏：$STATE_FILE"
    jq -c . "$STATE_FILE"
}

save_state() {
    local state=$1
    json_write "$STATE_FILE" "$state" 0600
    chmod 0600 "$STATE_FILE" || die "无法设置状态文件权限。"
}

state_upsert_node() {
    local node=$1 state updated
    state=$(load_state)
    updated=$(jq -c --argjson node "$node" \
        '.nodes = ([.nodes[]? | select(.tag != $node.tag)] + [$node])' <<<"$state") \
        || die '无法更新状态文件。'
    save_state "$updated"
}

state_remove_tag() {
    local tag=$1 state updated
    state=$(load_state)
    updated=$(jq -c --arg tag "$tag" '.nodes = [.nodes[]? | select(.tag != $tag)]' <<<"$state") \
        || die '无法更新状态文件。'
    save_state "$updated"
}

state_remove_kind() {
    local kind=$1 state updated
    state=$(load_state)
    updated=$(jq -c --arg kind "$kind" '.nodes = [.nodes[]? | select(.kind != $kind)]' <<<"$state") \
        || die '无法更新状态文件。'
    save_state "$updated"
}

state_remove_vless() {
    local state updated
    state=$(load_state)
    updated=$(jq -c '.nodes = [.nodes[]? | select((.kind // "") | startswith("vless-") | not)]' <<<"$state") \
        || die '无法更新状态文件。'
    save_state "$updated"
}

parse_port() {
    local value=${1:-}
    [[ "$value" =~ ^[0-9]+$ ]] || die "端口必须是数字：$value"
    (( value >= 1 && value <= 65535 )) || die "端口必须在 1-65535：$value"
    printf '%s\n' "$value"
}

parse_listen() {
    local value=${1:-}
    [[ -n "$value" && "$value" != *$'\r'* && "$value" != *$'\n'* ]] \
        || die '监听地址不能为空或包含控制字符。'
    if [[ "$value" == '0.0.0.0' || "$value" == '::' ]]; then
        printf '%s\n' "$value"
        return 0
    fi
    [[ "$value" =~ ^[0-9A-Fa-f:.]+$ && "$value" == *:* ]] || die "监听地址必须是 IP：$value"
    printf '%s\n' "$value"
}

parse_server_address() {
    local value=${1:-}
    [[ "$value" == '<server-address>' ]] && { printf '%s\n' "$value"; return 0; }
    [[ -n "$value" && "$value" != *[[:space:]]* && "$value" != *$'\r'* && "$value" != *$'\n'* \
        && "$value" != */* && "$value" != *\\* && "$value" != *:*:*:*:*:*:*:*:* ]] \
        || die 'server-address 必须是主机名或 IP，不要带端口/协议/路径。'
    if [[ "$value" == *:* ]]; then
        [[ "$value" =~ ^[0-9A-Fa-f:]+$ ]] || die "无效 IPv6 server-address：$value"
    else
        [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$value" != *..* ]] \
            || die "无效 server-address：$value"
    fi
    printf '%s\n' "$value"
}

parse_target() {
    local value=${1:-} host port
    [[ -n "$value" && "$value" != *[[:space:]]* && "$value" != *$'\r'* && "$value" != *$'\n'* \
        && "$value" != */* && "$value" != *\\* ]] || die 'Reality target 必须是 host:port。'
    if [[ "$value" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
        [[ "$host" == *:* ]] || die "IPv6 target 无效：$value"
    elif [[ "$value" =~ ^([^:]+):([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
        [[ "$host" != *:* ]] || die "IPv6 target 请使用 [addr]:port：$value"
    else
        die "无效 Reality target：$value"
    fi
    [[ -n "$host" ]] || die "无效 Reality target：$value"
    parse_port "$port" >/dev/null
    printf '%s\n' "$value"
}

parse_server_name() {
    local value=${1:-}
    [[ -n "$value" && ${#value} -le 253 && "$value" != *[[:space:]]* \
        && "$value" != *$'\r'* && "$value" != *$'\n'* && "$value" != */* && "$value" != *\\* ]] \
        || die "无效 server-name：$value"
    printf '%s\n' "$value"
}

parse_tag() {
    local value=${1:-}
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die "无效 tag：$value"
    printf '%s\n' "$value"
}

parse_uuid() {
    local value=${1:-}
    [[ "$value" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]] \
        || die "必须是合法 UUID：$value"
    printf '%s\n' "${value,,}"
}

raw_b64_length() {
    local value=$1 translated padded tmp length
    [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    translated=${value//-/+}
    translated=${translated//_//}
    padded=$translated
    while (( ${#padded} % 4 != 0 )); do padded+='='; done
    tmp=$(mktemp) || return 1
    if ! printf '%s' "$padded" | base64 -d >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    length=$(wc -c <"$tmp")
    rm -f -- "$tmp"
    printf '%s\n' "$length"
}

validate_raw_b64() {
    local value=$1 expected=$2 label=$3 length
    length=$(raw_b64_length "$value") || die "$label 不是合法无填充 base64url。"
    (( length == expected )) || die "$label 解码后必须是 ${expected} 字节，当前为 ${length}。"
    printf '%s\n' "$value"
}

validate_ss_password() {
    local method=$1 value=$2 expected tmp length
    expected=$(ss_method_bytes "$method") || die "不支持的 Shadowsocks method：$method"
    [[ -n "$value" && "$value" != *$'\r'* && "$value" != *$'\n'* ]] || die 'Shadowsocks 密码不能为空或含控制字符。'
    [[ "$value" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || die 'Shadowsocks 2022 密码必须是标准 base64。'
    tmp=$(mktemp) || die '无法创建密码校验临时文件。'
    if ! printf '%s' "$value" | base64 -d >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        die 'Shadowsocks 密码不是合法标准 base64。'
    fi
    length=$(wc -c <"$tmp")
    rm -f -- "$tmp"
    (( length == expected )) || die "${method} 密码解码后必须是 ${expected} 字节，当前为 ${length}。"
    printf '%s\n' "$value"
}

random_ss_password() {
    local bytes=$1
    head -c "$bytes" /dev/urandom | base64 | tr -d '\r\n' || die '无法生成随机 Shadowsocks 密码。'
    printf '\n'
}

random_hex() {
    local bytes=$1
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n' || die '无法生成随机值。'
}

generate_uuid() {
    local value hex variant
    if [[ -x "$XRAY_BIN" && ! -L "$XRAY_BIN" ]]; then
        value=$("$XRAY_BIN" uuid 2>/dev/null | awk 'NF {print; exit}' || true)
        if [[ "$value" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; then
            printf '%s\n' "${value,,}"
            return 0
        fi
    fi
    hex=$(random_hex 16)
    variant=$(( (16#${hex:16:1} & 3) | 8 ))
    printf '%s-%s-4%s-%x%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "$variant" "${hex:17:3}" "${hex:20:12}"
}

require_binary() {
    local kind=$1 path
    if [[ "$kind" == ss ]]; then path=$SS_BIN; else path=$XRAY_BIN; fi
    [[ -f "$path" && -x "$path" && ! -L "$path" ]] || die "未找到可执行 ${kind} 核心：$path"
    printf '%s\n' "$path"
}

xray_key_pair() {
    local private=${1:-} public=${2:-} output parsed_private parsed_public
    [[ -z "$public" || -n "$private" ]] || die '只提供 public-key 无法恢复私钥。'
    if [[ -n "$private" && -n "$public" ]]; then
        validate_raw_b64 "$private" 32 private-key >/dev/null
        validate_raw_b64 "$public" 32 public-key >/dev/null
        printf '%s\n%s\n' "$private" "$public"
        return 0
    fi
    require_binary xray >/dev/null
    if [[ -n "$private" ]]; then
        output=$("$XRAY_BIN" x25519 -i "$private" 2>&1) || die 'xray x25519 私钥转换失败。'
    else
        output=$("$XRAY_BIN" x25519 2>&1) || die 'xray x25519 生成失败。'
    fi
    parsed_private=$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /^private/ {print $2; exit}')
    parsed_public=$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /^(password|public)/ {print $2; exit}')
    parsed_private=${private:-$parsed_private}
    parsed_public=${public:-$parsed_public}
    [[ -n "$parsed_private" && -n "$parsed_public" ]] || die '无法解析 xray x25519 输出。'
    validate_raw_b64 "$parsed_private" 32 private-key >/dev/null
    validate_raw_b64 "$parsed_public" 32 public-key >/dev/null
    printf '%s\n%s\n' "$parsed_private" "$parsed_public"
}

mlkem_key_pair() {
    local seed=${1:-} client=${2:-} output parsed_seed parsed_client
    [[ -z "$client" || -n "$seed" ]] || die '只提供 ML-KEM Client 无法恢复 Seed。'
    if [[ -n "$seed" && -n "$client" ]]; then
        validate_raw_b64 "$seed" 64 mlkem-seed >/dev/null
        validate_raw_b64 "$client" 1184 mlkem-client >/dev/null
        printf '%s\n%s\n' "$seed" "$client"
        return 0
    fi
    require_binary xray >/dev/null
    output=$("$XRAY_BIN" mlkem768 2>&1) || die 'xray mlkem768 生成失败。'
    parsed_seed=$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) == "seed" {print $2; exit}')
    parsed_client=$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) == "client" {print $2; exit}')
    [[ -n "$parsed_seed" && -n "$parsed_client" ]] || die '无法解析 xray mlkem768 输出。'
    validate_raw_b64 "$parsed_seed" 64 mlkem-seed >/dev/null
    validate_raw_b64 "$parsed_client" 1184 mlkem-client >/dev/null
    printf '%s\n%s\n' "$parsed_seed" "$parsed_client"
}

xray_default_config() {
    cat <<'EOF'
{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}]}
EOF
}

load_xray_config() {
    if [[ ! -e "$XRAY_CONFIG" ]]; then
        xray_default_config
        return 0
    fi
    reject_symlink "$XRAY_CONFIG"
    jq -e 'type == "object" and (.inbounds | type == "array")' "$XRAY_CONFIG" >/dev/null \
        || die "Xray 配置结构损坏：$XRAY_CONFIG"
    jq -c . "$XRAY_CONFIG"
}

xray_upsert_inbound() {
    local config=$1 inbound=$2 tag port collision
    tag=$(jq -r '.tag' <<<"$inbound")
    port=$(jq -r '.port' <<<"$inbound")
    collision=$(jq -r --arg tag "$tag" --argjson port "$port" \
        '[.inbounds[]? | select(.tag != $tag and .port == $port)] | length' <<<"$config")
    (( collision == 0 )) || die "Xray 端口已被其他 inbound 使用：$port"
    jq -c --arg tag "$tag" --argjson inbound "$inbound" \
        '.inbounds = ([.inbounds[]? | select(.tag != $tag)] + [$inbound])' <<<"$config"
}

xray_has_low_port() {
    jq -e '[.inbounds[]?.port | select(type == "number" and . < 1024)] | length > 0' <<<"$1" >/dev/null
}

xray_validate_file() {
    local config_path=$1 output
    require_binary xray >/dev/null
    output=$("$XRAY_BIN" run -test -c "$config_path" 2>&1) || {
        printf '%s\n' "$output" >&2
        die "Xray 配置测试失败：$config_path"
    }
}

xray_validate_candidate() {
    local config=$1 tmp
    ensure_app_dirs
    tmp=$(mktemp "$ETC_DIR/.xray-check.XXXXXX.json") || die '无法创建 Xray 候选配置。'
    chmod 0600 "$tmp"
    if ! printf '%s' "$config" | jq -e . >"$tmp"; then
        rm -f -- "$tmp"
        die 'Xray 候选配置不是合法 JSON。'
    fi
    xray_validate_file "$tmp" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

reality_server_stream() {
    local target=$1 server_name=$2 private_key=$3 short_id=$4
    jq -cn --arg target "$target" --arg server_name "$server_name" --arg private_key "$private_key" --arg short_id "$short_id" \
        '{network:"tcp",security:"reality",tcpSettings:{header:{type:"none"}},realitySettings:{show:false,target:$target,xver:0,serverNames:[$server_name],privateKey:$private_key,shortIds:[$short_id]}}'
}

xray_tcp_stream() {
    jq -cn '{network:"tcp",security:"none",tcpSettings:{header:{type:"none"}}}'
}

make_reality_client() {
    local node=$1 server_address uuid port flow server_name fingerprint public_key short_id spider_x
    server_address=$(jq -r '.server_address' <<<"$node")
    uuid=$(jq -r '.uuid' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    flow=$(jq -r '.flow' <<<"$node")
    server_name=$(jq -r '.server_name' <<<"$node")
    fingerprint=$(jq -r '.fingerprint' <<<"$node")
    public_key=$(jq -r '.public_key' <<<"$node")
    short_id=$(jq -r '.short_id' <<<"$node")
    spider_x=$(jq -r '.spider_x' <<<"$node")
    jq -cn --arg address "$server_address" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" \
        --arg server_name "$server_name" --arg fingerprint "$fingerprint" --arg public_key "$public_key" \
        --arg short_id "$short_id" --arg spider_x "$spider_x" \
        '{log:{loglevel:"warning"},inbounds:[{tag:"socks-in",listen:"127.0.0.1",port:10808,protocol:"socks",settings:{auth:"noauth",udp:true}}],outbounds:[{tag:"proxy",protocol:"vless",settings:{vnext:[{address:$address,port:$port,users:[{id:$uuid,encryption:"none",flow:$flow}]}]},streamSettings:{network:"tcp",security:"reality",tcpSettings:{header:{type:"none"}},realitySettings:{serverName:$server_name,fingerprint:$fingerprint,password:$public_key,shortId:$short_id,spiderX:$spider_x}}},{tag:"direct",protocol:"freedom"}]}'
}

make_encryption_client() {
    local node=$1 server_address uuid port flow encryption
    server_address=$(jq -r '.server_address' <<<"$node")
    uuid=$(jq -r '.uuid' <<<"$node")
    port=$(jq -r '.port' <<<"$node")
    flow=$(jq -r '.flow' <<<"$node")
    encryption=$(jq -r '.client_encryption' <<<"$node")
    jq -cn --arg address "$server_address" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" --arg encryption "$encryption" \
        '{log:{loglevel:"warning"},inbounds:[{tag:"socks-in",listen:"127.0.0.1",port:10808,protocol:"socks",settings:{auth:"noauth",udp:true}}],outbounds:[{tag:"proxy",protocol:"vless",settings:{vnext:[{address:$address,port:$port,users:[{id:$uuid,encryption:$encryption,flow:$flow}]}]},streamSettings:{network:"tcp",security:"none",tcpSettings:{header:{type:"none"}}}},{tag:"direct",protocol:"freedom"}]}'
}

uri_host() {
    local address=$1
    if [[ "$address" == *:* && "$address" != \[*\] ]]; then
        printf '[%s]\n' "$address"
    else
        printf '%s\n' "$address"
    fi
}

url_encode() {
    SSOWN_URI_VALUE=$1 jq -nr '$ENV.SSOWN_URI_VALUE | @uri'
}

make_ss_uri() {
    local node=$1 method password address port tag userinfo
    method=$(jq -r '.method' <<<"$node")
    password=$(jq -r '.password' <<<"$node")
    address=$(uri_host "$(jq -r '.server_address' <<<"$node")")
    port=$(jq -r '.port' <<<"$node")
    tag=$(url_encode "$(jq -r '.tag' <<<"$node")")
    userinfo=$(printf '%s:%s' "$method" "$password" | base64 | tr '+/' '-_' | tr -d '=\r\n')
    printf 'ss://%s@%s:%s?udp=true#%s\n' "$userinfo" "$address" "$port" "$tag"
}

make_vless_uri() {
    local node=$1 kind address port uuid tag query
    kind=$(jq -r '.kind' <<<"$node")
    address=$(uri_host "$(jq -r '.server_address' <<<"$node")")
    port=$(jq -r '.port' <<<"$node")
    uuid=$(jq -r '.uuid' <<<"$node")
    tag=$(url_encode "$(jq -r '.tag' <<<"$node")")
    if [[ "$kind" == vless-reality ]]; then
        query=$(jq -nr \
            --arg flow "$(jq -r '.flow' <<<"$node")" \
            --arg sni "$(jq -r '.server_name' <<<"$node")" \
            --arg fp "$(jq -r '.fingerprint' <<<"$node")" \
            --arg pbk "$(jq -r '.public_key' <<<"$node")" \
            --arg sid "$(jq -r '.short_id' <<<"$node")" \
            --arg spx "$(jq -r '.spider_x' <<<"$node")" \
            '(["encryption=none","security=reality","type=tcp",("flow="+($flow|@uri)),("sni="+($sni|@uri)),("fp="+($fp|@uri)),("pbk="+($pbk|@uri)),("sid="+($sid|@uri)),("spx="+($spx|@uri))] | join("&"))')
    else
        query=$(jq -nr \
            --arg encryption "$(jq -r '.client_encryption' <<<"$node")" \
            --arg flow "$(jq -r '.flow' <<<"$node")" \
            '(["security=none","type=tcp",("encryption="+($encryption|@uri)),("flow="+($flow|@uri))] | join("&"))')
    fi
    printf 'vless://%s@%s:%s?%s#%s\n' "$uuid" "$address" "$port" "$query" "$tag"
}

redact_node() {
    jq -c '
        if has("password") then .password = "<hidden>" else . end |
        if has("private_key") then .private_key = "<hidden>" else . end |
        if has("public_key") then .public_key = "<hidden>" else . end |
        if has("decryption") then .decryption = "<hidden>" else . end |
        if has("client_encryption") then .client_encryption = "<hidden>" else . end
    ' <<<"$1"
}

print_node() {
    local node=$1 reveal=${2:-0} kind
    if (( reveal )); then
        jq . <<<"$node"
        kind=$(jq -r '.kind' <<<"$node")
        if [[ "$kind" == shadowsocks-2022 ]]; then
            printf '分享链接：%s\n' "$(make_ss_uri "$node")"
        else
            printf '分享链接：%s\n' "$(make_vless_uri "$node")"
        fi
    else
        jq . <<<"$(redact_node "$node")"
    fi
}

write_client_file() {
    local tag=$1 client=$2 path="$CLIENT_DIR/${tag}.json"
    backup_file "$path"
    json_write "$path" "$client" 0600
    chmod 0600 "$path" || die "无法设置客户端配置权限：$path"
    printf '%s\n' "$path"
}

configure_bind_capability() {
    local kind=$1 low_port=$2 path
    openrc_available || return 0
    if [[ "$kind" == ss ]]; then path=$SS_BIN; else path=$XRAY_BIN; fi
    [[ -f "$path" && ! -L "$path" ]] || die "无法设置低端口能力：$path"
    if (( low_port )); then
        have setcap || die 'Alpine/OpenRC 低端口服务需要 setcap，请安装 libcap。'
        setcap cap_net_bind_service=+ep "$path" || die "无法设置低端口能力：$path"
    elif have setcap; then
        setcap -r "$path" >/dev/null 2>&1 || true
    fi
}

xray_service_content() {
    local low_port=$1 capability=''
    (( low_port )) && capability='CAP_NET_BIND_SERVICE'
    cat <<EOF
[Unit]
Description=Auditable Xray core for ${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ProtectKernelTunables=yes
ProtectControlGroups=yes
LockPersonality=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=${capability}
AmbientCapabilities=${capability}
UMask=0027
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

ss_service_content() {
    local low_port=$1 capability=''
    (( low_port )) && capability='CAP_NET_BIND_SERVICE'
    cat <<EOF
[Unit]
Description=Auditable Shadowsocks Rust core for ${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${SS_BIN} -c ${SS_CONFIG}
Restart=on-failure
RestartSec=3s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ProtectKernelTunables=yes
ProtectControlGroups=yes
LockPersonality=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=${capability}
AmbientCapabilities=${capability}
UMask=0027
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

openrc_service_content() {
    local kind=$1 command config description
    if [[ "$kind" == ss ]]; then
        command=$SS_BIN
        config=$SS_CONFIG
        description='Auditable Shadowsocks Rust core for ss-2022-own'
    else
        command=$XRAY_BIN
        config=$XRAY_CONFIG
        description='Auditable Xray core for ss-2022-own'
    fi
    cat <<EOF
#!/sbin/openrc-run

description="${description}"
command="${command}"
command_args="-c ${config}"
command_user="${SERVICE_USER}:${SERVICE_USER}"
pidfile="/run/\${RC_SVCNAME}.pid"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=5
respawn_period=60

depend() {
    need net
    after firewall
}
EOF
}

write_runtime_service() {
    local kind=$1 low_port=$2
    configure_bind_capability "$kind" "$low_port"
    if [[ "$kind" == ss ]]; then
        if systemd_available; then
            ensure_dir "$SYSTEMD_DIR" 0755
            atomic_write_text "$SS_SERVICE" "$(ss_service_content "$low_port")" 0644
        elif openrc_available; then
            ensure_dir "$OPENRC_DIR" 0755
            atomic_write_text "$OPENRC_SS_SERVICE" "$(openrc_service_content ss)" 0755
        else
            warn_msg '未检测到 systemd/OpenRC；只写入配置。'
        fi
    else
        if systemd_available; then
            ensure_dir "$SYSTEMD_DIR" 0755
            atomic_write_text "$XRAY_SERVICE" "$(xray_service_content "$low_port")" 0644
        elif openrc_available; then
            ensure_dir "$OPENRC_DIR" 0755
            atomic_write_text "$OPENRC_XRAY_SERVICE" "$(openrc_service_content xray)" 0755
        else
            warn_msg '未检测到 systemd/OpenRC；只写入配置。'
        fi
    fi
}

service_action() {
    local action=$1 name=$2 service=${2%.service} result detail
    if systemd_available; then
        case "$action" in
            disable-now) systemctl disable --now "$name" >/dev/null 2>&1 || true ;;
            is-active) systemctl is-active "$name" >/dev/null 2>&1 ;;
            status) systemctl --no-pager status "$name" ;;
            enable|disable|start|stop|restart) systemctl "$action" "$name" ;;
            *) die "未知服务操作：$action" ;;
        esac
        return $?
    fi
    if openrc_available; then
        case "$action" in
            disable-now)
                rc-service "$service" stop >/dev/null 2>&1 || true
                rc-update del "$service" default >/dev/null 2>&1 || true
                ;;
            is-active) rc-service "$service" status >/dev/null 2>&1 ;;
            status) rc-service "$service" status ;;
            enable) rc-update add "$service" default ;;
            disable) rc-update del "$service" default >/dev/null 2>&1 || true ;;
            start|stop|restart) rc-service "$service" "$action" ;;
            *) die "未知服务操作：$action" ;;
        esac
        return $?
    fi
    warn_msg "未执行服务操作（没有 systemd/OpenRC）：$action $name"
    return 0
}

apply_service() {
    local name=$1 start=$2
    if systemd_available; then
        systemctl daemon-reload
        systemctl enable "$name"
        (( start )) && systemctl restart "$name"
    elif openrc_available; then
        service_action enable "$name"
        (( start )) && service_action restart "$name"
    else
        warn_msg '未检测到服务管理器；请手动启动核心。'
    fi
}

firewall_ufw_active() {
    have ufw || return 1
    ufw status 2>/dev/null | grep -q '^Status: active'
}

firewall_firewalld_active() {
    have firewall-cmd || return 1
    [[ "$(firewall-cmd --state 2>/dev/null || true)" == running ]]
}

firewall_open() {
    local port=$1 protocol=$2 proto
    port=$(parse_port "$port")
    [[ "$protocol" == tcp || "$protocol" == udp || "$protocol" == both ]] || die '防火墙协议必须是 tcp、udp 或 both。'
    if [[ "$protocol" == both ]]; then
        for proto in tcp udp; do firewall_open "$port" "$proto"; done
        return 0
    fi
    if firewall_ufw_active; then
        ufw allow "${port}/${protocol}"
        info_msg "UFW 已放行 ${port}/${protocol}"
    elif firewall_firewalld_active; then
        firewall-cmd --permanent "--add-port=${port}/${protocol}"
        firewall-cmd --reload
        info_msg "firewalld 已放行 ${port}/${protocol}"
    else
        warn_msg "未检测到已启用 UFW/firewalld；未修改规则，请手动放行 ${port}/${protocol}。"
    fi
}

firewall_close() {
    local port=$1 protocol=$2 proto
    port=$(parse_port "$port")
    [[ "$protocol" == tcp || "$protocol" == udp || "$protocol" == both ]] || die '防火墙协议必须是 tcp、udp 或 both。'
    if [[ "$protocol" == both ]]; then
        for proto in tcp udp; do firewall_close "$port" "$proto"; done
        return 0
    fi
    if firewall_ufw_active; then
        ufw delete allow "${port}/${protocol}" >/dev/null 2>&1 || true
    elif firewall_firewalld_active; then
        firewall-cmd --permanent "--remove-port=${port}/${protocol}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    else
        warn_msg '未检测到已启用 UFW/firewalld；未修改规则。'
    fi
}

cmd_install_ss() {
    require_root
    ensure_app_dirs
    service_user_ready
    require_binary ss >/dev/null
    local method=2022-blake3-aes-256-gcm method_bytes port=8388 listen=0.0.0.0 server_address='<server-address>' tag=ss2022 password='' password_stdin=0 fast_open=true no_start=0 open_firewall=0 value node config
    while (($#)); do
        case "$1" in
            --method) [[ $# -ge 2 ]] || die '--method 缺少值'; method=$2; shift 2 ;;
            --port) [[ $# -ge 2 ]] || die '--port 缺少值'; port=$2; shift 2 ;;
            --listen) [[ $# -ge 2 ]] || die '--listen 缺少值'; listen=$2; shift 2 ;;
            --server-address) [[ $# -ge 2 ]] || die '--server-address 缺少值'; server_address=$2; shift 2 ;;
            --tag) [[ $# -ge 2 ]] || die '--tag 缺少值'; tag=$2; shift 2 ;;
            --password) [[ $# -ge 2 ]] || die '--password 缺少值'; password=$2; shift 2 ;;
            --password-stdin) password_stdin=1; shift ;;
            --fast-open) fast_open=true; shift ;;
            --no-fast-open) fast_open=false; shift ;;
            --no-start) no_start=1; shift ;;
            --open-firewall) open_firewall=1; shift ;;
            *) die "install ss 未知参数：$1" ;;
        esac
    done
    method_bytes=$(ss_method_bytes "$method") || die "不支持的 Shadowsocks method：$method"
    port=$(parse_port "$port")
    listen=$(parse_listen "$listen")
    server_address=$(parse_server_address "$server_address")
    tag=$(parse_tag "$tag")
    if (( password_stdin )); then
        IFS= read -r password || true
    fi
    [[ -n "$password" ]] || password=$(random_ss_password "$method_bytes")
    password=$(validate_ss_password "$method" "$password")
    config=$(jq -cn --arg server "$listen" --argjson port "$port" --arg password "$password" --arg method "$method" --argjson fast_open "$fast_open" \
        '{server:$server,server_port:$port,password:$password,method:$method,mode:"tcp_and_udp",fast_open:$fast_open,timeout:300}')
    node=$(jq -cn --arg kind shadowsocks-2022 --arg tag "$tag" --arg listen "$listen" --arg address "$server_address" \
        --argjson port "$port" --arg method "$method" --arg password "$password" --argjson fast_open "$fast_open" \
        '{kind:$kind,tag:$tag,listen:$listen,server_address:$address,port:$port,method:$method,password:$password,fast_open:$fast_open}')
    backup_file "$SS_CONFIG"
    json_write "$SS_CONFIG" "$config" 0640
    state_upsert_node "$node"
    write_runtime_service ss $(( port < 1024 ))
    apply_service ss-2022-own-ss.service "$(( ! no_start ))"
    (( open_firewall )) && firewall_open "$port" both
    print_node "$node" 0
    info_msg '配置已写入；使用 show --reveal 查看分享信息。'
}

cmd_install_reality() {
    require_root
    ensure_app_dirs
    service_user_ready
    require_binary xray >/dev/null
    local port=443 listen=0.0.0.0 server_address='<server-address>' tag=vless-reality target='' server_name='' uuid='' flow=xtls-rprx-vision fingerprint=chrome short_id='' private_key='' public_key='' spider_x=/ no_start=0 open_firewall=0 value pair inbound config node client client_path
    while (($#)); do
        case "$1" in
            --port) [[ $# -ge 2 ]] || die '--port 缺少值'; port=$2; shift 2 ;;
            --listen) [[ $# -ge 2 ]] || die '--listen 缺少值'; listen=$2; shift 2 ;;
            --server-address) [[ $# -ge 2 ]] || die '--server-address 缺少值'; server_address=$2; shift 2 ;;
            --tag) [[ $# -ge 2 ]] || die '--tag 缺少值'; tag=$2; shift 2 ;;
            --target) [[ $# -ge 2 ]] || die '--target 缺少值'; target=$2; shift 2 ;;
            --server-name) [[ $# -ge 2 ]] || die '--server-name 缺少值'; server_name=$2; shift 2 ;;
            --uuid) [[ $# -ge 2 ]] || die '--uuid 缺少值'; uuid=$2; shift 2 ;;
            --flow) [[ $# -ge 2 ]] || die '--flow 缺少值'; flow=$2; shift 2 ;;
            --fingerprint) [[ $# -ge 2 ]] || die '--fingerprint 缺少值'; fingerprint=$2; shift 2 ;;
            --short-id) [[ $# -ge 2 ]] || die '--short-id 缺少值'; short_id=$2; shift 2 ;;
            --private-key) [[ $# -ge 2 ]] || die '--private-key 缺少值'; private_key=$2; shift 2 ;;
            --public-key) [[ $# -ge 2 ]] || die '--public-key 缺少值'; public_key=$2; shift 2 ;;
            --spider-x) [[ $# -ge 2 ]] || die '--spider-x 缺少值'; spider_x=$2; shift 2 ;;
            --no-start) no_start=1; shift ;;
            --open-firewall) open_firewall=1; shift ;;
            *) die "install reality 未知参数：$1" ;;
        esac
    done
    port=$(parse_port "$port")
    listen=$(parse_listen "$listen")
    server_address=$(parse_server_address "$server_address")
    tag=$(parse_tag "$tag")
    target=$(parse_target "$target")
    server_name=$(parse_server_name "$server_name")
    [[ -z "$uuid" ]] && uuid=$(generate_uuid)
    uuid=$(parse_uuid "$uuid")
    [[ -z "$flow" || "$flow" == xtls-rprx-vision ]] || die 'flow 只允许空或 xtls-rprx-vision。'
    [[ "$fingerprint" =~ ^[a-z0-9_-]{1,32}$ ]] || die "无效 fingerprint：$fingerprint"
    [[ -z "$short_id" ]] && short_id=$(random_hex 8)
    [[ "$short_id" =~ ^[0-9A-Fa-f]{0,16}$ && $(( ${#short_id} % 2 )) -eq 0 ]] || die 'short-id 必须是偶数位十六进制。'
    [[ "$spider_x" == /* && "$spider_x" != *$'\r'* && "$spider_x" != *$'\n'* ]] || die 'spider-x 必须以 / 开头。'
    pair=$(xray_key_pair "$private_key" "$public_key")
    private_key=$(sed -n '1p' <<<"$pair")
    public_key=$(sed -n '2p' <<<"$pair")
    inbound=$(jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" --arg target "$target" \
        --arg server_name "$server_name" --arg private_key "$private_key" --arg short_id "$short_id" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:$flow,email:($tag+"@local")}],decryption:"none"},streamSettings:{network:"tcp",security:"reality",tcpSettings:{header:{type:"none"}},realitySettings:{show:false,target:$target,xver:0,serverNames:[$server_name],privateKey:$private_key,shortIds:[$short_id]}}}')
    config=$(xray_upsert_inbound "$(load_xray_config)" "$inbound")
    xray_validate_candidate "$config"
    node=$(jq -cn --arg kind vless-reality --arg tag "$tag" --arg listen "$listen" --arg address "$server_address" --argjson port "$port" --arg uuid "$uuid" \
        --arg flow "$flow" --arg target "$target" --arg server_name "$server_name" --arg fingerprint "$fingerprint" --arg short_id "$short_id" \
        --arg private_key "$private_key" --arg public_key "$public_key" --arg spider_x "$spider_x" \
        '{kind:$kind,tag:$tag,listen:$listen,server_address:$address,port:$port,uuid:$uuid,flow:$flow,target:$target,server_name:$server_name,fingerprint:$fingerprint,short_id:$short_id,private_key:$private_key,public_key:$public_key,spider_x:$spider_x}')
    backup_file "$XRAY_CONFIG"
    json_write "$XRAY_CONFIG" "$config" 0640
    state_upsert_node "$node"
    client=$(make_reality_client "$node")
    client_path=$(write_client_file "$tag" "$client")
    if xray_has_low_port "$config"; then write_runtime_service xray 1; else write_runtime_service xray 0; fi
    apply_service ss-2022-own-xray.service "$(( ! no_start ))"
    (( open_firewall )) && firewall_open "$port" tcp
    print_node "$node" 0
    info_msg "客户端 JSON 已写入：$client_path"
    info_msg '私钥只保存在服务端状态/配置；使用 show --reveal 查看分享信息。'
}

cmd_install_encryption() {
    require_root
    ensure_app_dirs
    service_user_ready
    require_binary xray >/dev/null
    local port=8443 listen=0.0.0.0 server_address='<server-address>' tag=vless-encryption uuid='' flow=xtls-rprx-vision auth=x25519 appearance=native ticket_ttl=600s private_key='' public_key='' no_start=0 open_firewall=0 pair decryption client_encryption inbound config node client client_path
    while (($#)); do
        case "$1" in
            --port) [[ $# -ge 2 ]] || die '--port 缺少值'; port=$2; shift 2 ;;
            --listen) [[ $# -ge 2 ]] || die '--listen 缺少值'; listen=$2; shift 2 ;;
            --server-address) [[ $# -ge 2 ]] || die '--server-address 缺少值'; server_address=$2; shift 2 ;;
            --tag) [[ $# -ge 2 ]] || die '--tag 缺少值'; tag=$2; shift 2 ;;
            --uuid) [[ $# -ge 2 ]] || die '--uuid 缺少值'; uuid=$2; shift 2 ;;
            --flow) [[ $# -ge 2 ]] || die '--flow 缺少值'; flow=$2; shift 2 ;;
            --auth) [[ $# -ge 2 ]] || die '--auth 缺少值'; auth=$2; shift 2 ;;
            --appearance) [[ $# -ge 2 ]] || die '--appearance 缺少值'; appearance=$2; shift 2 ;;
            --ticket-ttl) [[ $# -ge 2 ]] || die '--ticket-ttl 缺少值'; ticket_ttl=$2; shift 2 ;;
            --private-key) [[ $# -ge 2 ]] || die '--private-key 缺少值'; private_key=$2; shift 2 ;;
            --public-key) [[ $# -ge 2 ]] || die '--public-key 缺少值'; public_key=$2; shift 2 ;;
            --no-start) no_start=1; shift ;;
            --open-firewall) open_firewall=1; shift ;;
            *) die "install encryption 未知参数：$1" ;;
        esac
    done
    port=$(parse_port "$port")
    listen=$(parse_listen "$listen")
    server_address=$(parse_server_address "$server_address")
    tag=$(parse_tag "$tag")
    [[ -z "$uuid" ]] && uuid=$(generate_uuid)
    uuid=$(parse_uuid "$uuid")
    [[ -z "$flow" || "$flow" == xtls-rprx-vision ]] || die 'flow 只允许空或 xtls-rprx-vision。'
    [[ "$auth" == x25519 || "$auth" == mlkem768 ]] || die 'auth 必须是 x25519 或 mlkem768。'
    [[ "$appearance" == native || "$appearance" == xorpub || "$appearance" == random ]] || die 'appearance 无效。'
    [[ "$ticket_ttl" == 0s || "$ticket_ttl" =~ ^[1-9][0-9]*(\-[1-9][0-9]*)?s$ ]] || die 'ticket-ttl 示例：600s、300-600s 或 0s。'
    if [[ "$ticket_ttl" == *-* ]]; then
        local lower=${ticket_ttl%-*} upper=${ticket_ttl#*-}
        lower=${lower%s}; upper=${upper%s}
        (( lower <= upper )) || die 'ticket-ttl 范围必须从小到大。'
    fi
    if [[ "$auth" == x25519 ]]; then
        pair=$(xray_key_pair "$private_key" "$public_key")
        private_key=$(sed -n '1p' <<<"$pair")
        public_key=$(sed -n '2p' <<<"$pair")
    else
        pair=$(mlkem_key_pair "$private_key" "$public_key")
        private_key=$(sed -n '1p' <<<"$pair")
        public_key=$(sed -n '2p' <<<"$pair")
    fi
    decryption="mlkem768x25519plus.${appearance}.${ticket_ttl}.${private_key}"
    client_encryption="mlkem768x25519plus.${appearance}.0rtt.${public_key}"
    inbound=$(jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" --arg decryption "$decryption" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:$flow,email:($tag+"@local")}],decryption:$decryption},streamSettings:{network:"tcp",security:"none",tcpSettings:{header:{type:"none"}}}}')
    config=$(xray_upsert_inbound "$(load_xray_config)" "$inbound")
    xray_validate_candidate "$config"
    node=$(jq -cn --arg kind vless-encryption --arg tag "$tag" --arg listen "$listen" --arg address "$server_address" --argjson port "$port" --arg uuid "$uuid" \
        --arg flow "$flow" --arg auth "$auth" --arg appearance "$appearance" --arg ticket_ttl "$ticket_ttl" --arg private_key "$private_key" \
        --arg public_key "$public_key" --arg decryption "$decryption" --arg client_encryption "$client_encryption" \
        '{kind:$kind,tag:$tag,listen:$listen,server_address:$address,port:$port,uuid:$uuid,flow:$flow,auth:$auth,appearance:$appearance,ticket_ttl:$ticket_ttl,private_key:$private_key,public_key:$public_key,decryption:$decryption,client_encryption:$client_encryption}')
    backup_file "$XRAY_CONFIG"
    json_write "$XRAY_CONFIG" "$config" 0640
    state_upsert_node "$node"
    client=$(make_encryption_client "$node")
    client_path=$(write_client_file "$tag" "$client")
    if xray_has_low_port "$config"; then write_runtime_service xray 1; else write_runtime_service xray 0; fi
    apply_service ss-2022-own-xray.service "$(( ! no_start ))"
    (( open_firewall )) && firewall_open "$port" tcp
    print_node "$node" 0
    info_msg "客户端 JSON 已写入：$client_path"
    info_msg 'VLESS Encryption 是协议层加密，不等同于 TLS/Reality；使用 show --reveal 查看分享信息。'
}

cmd_deploy() {
    require_root
    ensure_app_dirs
    local ss_source='' xray_source='' input source target tmp state low
    while (($#)); do
        case "$1" in
            --ss) [[ $# -ge 2 ]] || die '--ss 缺少值'; ss_source=$2; shift 2 ;;
            --xray) [[ $# -ge 2 ]] || die '--xray 缺少值'; xray_source=$2; shift 2 ;;
            *) die "deploy 未知参数：$1" ;;
        esac
    done
    [[ -n "$ss_source" || -n "$xray_source" ]] || die '至少提供 --ss 或 --xray。'
    for input in ss xray; do
        if [[ "$input" == ss ]]; then source=$ss_source; target=$SS_BIN; else source=$xray_source; target=$XRAY_BIN; fi
        [[ -n "$source" ]] || continue
        [[ -f "$source" && -x "$source" && ! -L "$source" ]] || die "拒绝部署不存在、不可执行或符号链接文件：$source"
        reject_symlink "$target"
        tmp="$BIN_DIR/.${target##*/}.new.$$"
        cp -- "$source" "$tmp" || die "无法复制核心：$source"
        chmod 0755 "$tmp" || { rm -f -- "$tmp"; die "无法设置核心权限：$target"; }
        mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; die "无法部署核心：$target"; }
        info_msg "已部署：$target"
    done
    state=$(load_state)
    if [[ -n "$ss_source" ]]; then
        low=$(jq -e '[.nodes[]? | select(.kind == "shadowsocks-2022" and .port < 1024)] | length > 0' <<<"$state" >/dev/null && echo 1 || echo 0)
        configure_bind_capability ss "$low"
    fi
    if [[ -n "$xray_source" ]]; then
        low=$(jq -e '[.nodes[]? | select((.kind // "") | startswith("vless-") and .port < 1024)] | length > 0' <<<"$state" >/dev/null && echo 1 || echo 0)
        configure_bind_capability xray "$low"
    fi
}

cmd_show() {
    local reveal=0 tag='' server_address='' state node count=0
    while (($#)); do
        case "$1" in
            --reveal) reveal=1; shift ;;
            --tag) [[ $# -ge 2 ]] || die '--tag 缺少值'; tag=$2; shift 2 ;;
            --server-address) [[ $# -ge 2 ]] || die '--server-address 缺少值'; server_address=$2; shift 2 ;;
            *) die "show 未知参数：$1" ;;
        esac
    done
    [[ -z "$tag" || "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die "无效 tag：$tag"
    [[ -z "$server_address" ]] || server_address=$(parse_server_address "$server_address")
    state=$(load_state)
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        [[ -z "$server_address" ]] || node=$(jq -c --arg address "$server_address" '.server_address = $address' <<<"$node")
        (( count > 0 )) && printf '\n---\n'
        print_node "$node" "$reveal"
        count=$((count + 1))
    done < <(jq -c --arg tag "$tag" 'if $tag == "" then .nodes[]? else .nodes[]? | select(.tag == $tag) end' <<<"$state")
    (( count > 0 )) || info_msg '暂无节点。'
}

cmd_status() {
    local state node kind label tag port service active
    state=$(load_state)
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        kind=$(jq -r '.kind // "unknown"' <<<"$node")
        tag=$(jq -r '.tag // "-"' <<<"$node")
        port=$(jq -r '.port // "-"' <<<"$node")
        case "$kind" in
            shadowsocks-2022) label='Shadowsocks 2022'; service=ss-2022-own-ss.service ;;
            vless-reality) label='VLESS Reality'; service=ss-2022-own-xray.service ;;
            vless-encryption) label='VLESS Encryption'; service=ss-2022-own-xray.service ;;
            *) label=$kind; service='' ;;
        esac
        active='configured'
        if [[ -n "$service" ]] && (systemd_available || openrc_available); then
            if service_action is-active "$service" >/dev/null 2>&1; then active='running'; else active='stopped'; fi
        fi
        printf '%-20s %-24s :%-6s %s\n' "$label" "$tag" "$port" "$active"
    done < <(jq -c '.nodes[]?' <<<"$state")
}

cmd_core_info() {
    printf '%b=== 核心信息 ===%b\n' "$CYAN" "$RESET"
    printf '初始化系统：%s\n' "$(init_system_name)"
    printf 'Shadowsocks：%s\n' "$SS_BIN"
    printf 'Xray：%s\n' "$XRAY_BIN"
    if [[ -x "$SS_BIN" && ! -L "$SS_BIN" ]]; then
        printf 'SS 版本：%s\n' "$("$SS_BIN" --version 2>&1 | awk 'NF {print; exit}')"
    else
        printf 'SS 版本：未部署\n'
    fi
    if [[ -x "$XRAY_BIN" && ! -L "$XRAY_BIN" ]]; then
        printf 'Xray 版本：%s\n' "$("$XRAY_BIN" version 2>&1 | awk 'NF {print; exit}')"
    else
        printf 'Xray 版本：未部署\n'
    fi
    printf '预编译 Release：v0.1.0 amd64/glibc + amd64/musl\n'
    printf 'glibc SHA-256：ea19d8faee337cfc4bdb78c9c0527dddb16f03d7760792b98a5124c56c92a48b\n'
    printf 'musl SHA-256：93e2cab2d2eb643f014ec503939da2cfd16eed2941a4f7f6ddf983ffe277a458\n'
}

cmd_logs() {
    require_root
    local kind=all lines=50 service name result
    while (($#)); do
        case "$1" in
            ss|xray|all) kind=$1; shift ;;
            --lines) [[ $# -ge 2 ]] || die '--lines 缺少值'; lines=$2; shift 2 ;;
            *) die "logs 未知参数：$1" ;;
        esac
    done
    [[ "$lines" =~ ^[0-9]+$ ]] && (( lines >= 1 && lines <= 10000 )) || die '日志行数必须在 1-10000。'
    if openrc_available && have logread; then
        logread -l "$lines" || true
        return 0
    fi
    systemd_available && have journalctl || { warn_msg '没有可用的 systemd/journalctl 或 OpenRC/logread。'; return 0; }
    if [[ "$kind" == all ]]; then
        for service in ss-2022-own-ss.service ss-2022-own-xray.service; do
            printf '\n--- %s ---\n' "$service"
            journalctl --no-pager --full -n "$lines" -u "$service" || true
        done
    else
        if [[ "$kind" == ss ]]; then name=ss-2022-own-ss.service; else name=ss-2022-own-xray.service; fi
        journalctl --no-pager --full -n "$lines" -u "$name" || true
    fi
}

cmd_validate() {
    local config method password inbound settings clients decryption port
    if [[ -e "$SS_CONFIG" ]]; then
        reject_symlink "$SS_CONFIG"
        method=$(jq -r '.method // empty' "$SS_CONFIG")
        ss_method_bytes "$method" >/dev/null || die "未知 Shadowsocks method：$method"
        port=$(jq -r '.server_port // empty' "$SS_CONFIG")
        parse_port "$port" >/dev/null
        password=$(jq -r '.password // empty' "$SS_CONFIG")
        validate_ss_password "$method" "$password" >/dev/null
        info_msg "SS 配置 OK：$SS_CONFIG"
    fi
    if [[ -e "$XRAY_CONFIG" ]]; then
        reject_symlink "$XRAY_CONFIG"
        config=$(load_xray_config)
        while IFS= read -r inbound; do
            [[ -n "$inbound" ]] || continue
            port=$(jq -r '.port // empty' <<<"$inbound")
            parse_port "$port" >/dev/null
            [[ "$(jq -r '.protocol // empty' <<<"$inbound")" == vless ]] || die 'Xray inbound protocol 必须是 vless。'
            jq -e '.settings | type == "object" and (.clients | type == "array" and length > 0) and has("decryption")' <<<"$inbound" >/dev/null \
                || die "Xray VLESS inbound 字段不完整。"
        done < <(jq -c '.inbounds[]?' <<<"$config")
        xray_validate_file "$XRAY_CONFIG"
        info_msg "Xray 配置 OK：$XRAY_CONFIG"
    fi
    [[ -e "$SS_CONFIG" || -e "$XRAY_CONFIG" ]] || info_msg '暂无配置文件。'
}

cmd_service() {
    require_root
    local action=${1:-} kind=${2:-all} name
    [[ "$action" == enable || "$action" == disable || "$action" == start || "$action" == stop || "$action" == restart || "$action" == status ]] \
        || die 'service 操作必须是 enable/disable/start/stop/restart/status。'
    [[ "$kind" == ss || "$kind" == xray || "$kind" == all ]] || die 'service 类型必须是 ss/xray/all。'
    if [[ "$kind" == ss || "$kind" == all ]]; then
        service_action "$action" ss-2022-own-ss.service || [[ "$action" == stop || "$action" == disable || "$action" == status ]] || return 1
    fi
    if [[ "$kind" == xray || "$kind" == all ]]; then
        service_action "$action" ss-2022-own-xray.service || [[ "$action" == stop || "$action" == disable || "$action" == status ]] || return 1
    fi
}

remove_xray_tag() {
    local tag=$1 config updated state client_path
    [[ -e "$XRAY_CONFIG" ]] || die "Xray 配置不存在：$XRAY_CONFIG"
    config=$(load_xray_config)
    jq -e --arg tag "$tag" '[.inbounds[]? | select(.tag == $tag)] | length > 0' <<<"$config" >/dev/null || die "未找到 Xray 节点：$tag"
    updated=$(jq -c --arg tag "$tag" '.inbounds = [.inbounds[]? | select(.tag != $tag)]' <<<"$config")
    xray_validate_candidate "$updated"
    backup_file "$XRAY_CONFIG"
    json_write "$XRAY_CONFIG" "$updated" 0640
    state_remove_tag "$tag"
    client_path="$CLIENT_DIR/${tag}.json"
    if [[ -e "$client_path" ]]; then backup_file "$client_path"; rm -f -- "$client_path"; fi
    if jq -e '.inbounds | length > 0' <<<"$updated" >/dev/null; then
        if xray_has_low_port "$updated"; then write_runtime_service xray 1; else write_runtime_service xray 0; fi
        service_action restart ss-2022-own-xray.service >/dev/null 2>&1 || true
    else
        service_action disable-now ss-2022-own-xray.service || true
        rm -f -- "$XRAY_SERVICE" "$OPENRC_XRAY_SERVICE"
    fi
    info_msg "已删除 Xray 节点：$tag"
}

cmd_remove() {
    require_root
    local kind=all tag='' yes=0 node
    while (($#)); do
        case "$1" in
            ss|xray|all) kind=$1; shift ;;
            --tag) [[ $# -ge 2 ]] || die '--tag 缺少值'; tag=$2; shift 2 ;;
            --yes) yes=1; shift ;;
            *) die "remove 未知参数：$1" ;;
        esac
    done
    (( yes )) || die '删除操作需要 --yes。'
    if [[ -n "$tag" ]]; then
        tag=$(parse_tag "$tag")
        remove_xray_tag "$tag"
        return 0
    fi
    if [[ "$kind" == ss || "$kind" == all ]]; then
        if [[ -e "$SS_CONFIG" ]]; then backup_file "$SS_CONFIG"; rm -f -- "$SS_CONFIG"; fi
        state_remove_kind shadowsocks-2022
        service_action disable-now ss-2022-own-ss.service || true
        rm -f -- "$SS_SERVICE" "$OPENRC_SS_SERVICE"
    fi
    if [[ "$kind" == xray || "$kind" == all ]]; then
        if [[ -e "$XRAY_CONFIG" ]]; then backup_file "$XRAY_CONFIG"; rm -f -- "$XRAY_CONFIG"; fi
        state_remove_vless
        for node in $(load_state | jq -r '.nodes[]? | select((.kind // "") | startswith("vless-")) | .tag'); do
            client_path="$CLIENT_DIR/${node}.json"
            if [[ -e "$client_path" ]]; then backup_file "$client_path"; rm -f -- "$client_path"; fi
        done
        service_action disable-now ss-2022-own-xray.service || true
        rm -f -- "$XRAY_SERVICE" "$OPENRC_XRAY_SERVICE"
    fi
    if [[ "$kind" == all ]]; then
        save_state "$(initial_state)"
    fi
    if systemd_available; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
    info_msg '删除完成。'
}

prompt_menu() {
    local text=$1 default=${2:-} value
    if [[ -n "$default" ]]; then
        read -r -p "$text [$default]: " value || value=''
    else
        read -r -p "$text: " value || value=''
    fi
    printf '%s\n' "${value:-$default}"
}

prompt_secret_menu() {
    local text=$1 value
    read -r -s -p "$text: " value || value=''
    printf '\n' >&2
    printf '%s\n' "$value"
}

menu_pause() {
    [[ -t 0 ]] || return 0
    read -r -p '按回车返回上一级...' _ || true
}

menu_install_one() {
    local kind=$1 value method password auth appearance
    if [[ "$kind" == ss ]]; then
        method=$(prompt_menu '加密方式' 2022-blake3-aes-256-gcm)
        password=$(prompt_secret_menu '密码（留空随机生成）')
        cmd_install_ss --method "$method" --port "$(prompt_menu 端口 8388)" --listen "$(prompt_menu 监听地址 0.0.0.0)" \
            --server-address "$(prompt_menu 服务器地址 '<server-address>')" --tag "$(prompt_menu 节点 tag ss2022)" \
            ${password:+--password "$password"}
    elif [[ "$kind" == reality ]]; then
        cmd_install_reality --port "$(prompt_menu 端口 443)" --listen "$(prompt_menu 监听地址 0.0.0.0)" \
            --server-address "$(prompt_menu 服务器地址 '<server-address>')" --tag "$(prompt_menu 节点 tag vless-reality)" \
            --target "$(prompt_menu 伪装目标 www.example.com:443)" --server-name "$(prompt_menu 允许的 SNI www.example.com)" \
            --uuid "$(prompt_menu UUID（留空随机生成）)" --fingerprint "$(prompt_menu 指纹 chrome)" \
            --short-id "$(prompt_menu short ID（留空随机生成）)" --spider-x "$(prompt_menu spiderX /)"
    else
        auth=$(prompt_menu '认证方式（x25519/mlkem768）' x25519)
        appearance=$(prompt_menu '外观（native/xorpub/random）' native)
        cmd_install_encryption --port "$(prompt_menu 端口 8443)" --listen "$(prompt_menu 监听地址 0.0.0.0)" \
            --server-address "$(prompt_menu 服务器地址 '<server-address>')" --tag "$(prompt_menu 节点 tag vless-encryption)" \
            --auth "$auth" --appearance "$appearance" --ticket-ttl "$(prompt_menu ticket TTL 600s)" \
            --uuid "$(prompt_menu UUID（留空随机生成）)"
    fi
}

menu_try() {
    local label=$1; shift
    if ( "$@" ); then :; else warn_msg "$label 操作失败，已返回菜单。"; fi
    menu_pause
}

menu_nodes() {
    local choice tag confirm state node
    while true; do
        printf '%b=== 节点管理 ===%b\n' "$CYAN" "$RESET"
        printf '%s\n' '1. 查看节点（隐藏凭据）' '2. 查看指定节点详情' '3. 显示分享链接（需 SHOW）' '4. 删除指定节点' '5. 验证配置' '0. 返回'
        choice=$(prompt_menu 请选择)
        case "$choice" in
            0) return 0 ;;
            1) cmd_show ;;
            2) tag=$(prompt_menu 节点tag); cmd_show --tag "$tag" ;;
            3) confirm=$(prompt_menu '输入 SHOW 确认'); [[ "$confirm" == SHOW ]] && cmd_show --reveal || warn_msg '已取消。' ;;
            4)
                tag=$(parse_tag "$(prompt_menu 要删除的节点tag)")
                confirm=$(prompt_menu '输入 DELETE 确认')
                [[ "$confirm" == DELETE ]] || { warn_msg '已取消。'; menu_pause; continue; }
                state=$(load_state)
                node=$(jq -c --arg tag "$tag" '.nodes[]? | select(.tag == $tag)' <<<"$state")
                [[ -n "$node" ]] || die "未找到节点：$tag"
                if [[ "$(jq -r '.kind' <<<"$node")" == shadowsocks-2022 ]]; then cmd_remove ss --yes; else remove_xray_tag "$tag"; fi
                ;;
            5) cmd_validate ;;
            *) warn_msg '无效选项。' ;;
        esac
        menu_pause
    done
}

menu_services() {
    local choice kind
    while true; do
        printf '%b=== 服务管理 ===%b\n' "$CYAN" "$RESET"
        printf '%s\n' '1. 启动全部' '2. 停止全部' '3. 重启全部' '4. 查看状态' '5. 重启 Shadowsocks' '6. 重启 Xray' '0. 返回'
        choice=$(prompt_menu 请选择)
        case "$choice" in
            0) return 0 ;;
            1) cmd_service start all ;;
            2) cmd_service stop all ;;
            3) cmd_service restart all ;;
            4) cmd_service status all ;;
            5) cmd_service restart ss ;;
            6) cmd_service restart xray ;;
            *) warn_msg '无效选项。' ;;
        esac
        menu_pause
    done
}

menu_config() {
    local choice confirm
    while true; do
        printf '%b=== 配置与分享 ===%b\n' "$CYAN" "$RESET"
        printf '%s\n' '1. 查看摘要（隐藏凭据）' '2. 显示分享链接（需 SHOW）' '3. 验证配置' '0. 返回'
        choice=$(prompt_menu 请选择)
        case "$choice" in
            0) return 0 ;;
            1) cmd_show ;;
            2) confirm=$(prompt_menu '输入 SHOW 确认'); [[ "$confirm" == SHOW ]] && cmd_show --reveal || warn_msg '已取消。' ;;
            3) cmd_validate ;;
            *) warn_msg '无效选项。' ;;
        esac
        menu_pause
    done
}

menu_firewall() {
    local choice port protocol
    while true; do
        printf '%b=== 防火墙（仅显式操作） ===%b\n' "$CYAN" "$RESET"
        printf '%s\n' '1. 放行端口' '2. 回收端口' '0. 返回'
        choice=$(prompt_menu 请选择)
        case "$choice" in
            0) return 0 ;;
            1) port=$(prompt_menu 端口 443); protocol=$(prompt_menu '协议 tcp/udp/both' tcp); require_root; firewall_open "$port" "$protocol" ;;
            2) port=$(prompt_menu 端口 443); protocol=$(prompt_menu '协议 tcp/udp/both' tcp); require_root; firewall_close "$port" "$protocol" ;;
            *) warn_msg '无效选项。' ;;
        esac
        menu_pause
    done
}

menu_core() {
    local choice ss xray
    local -a deploy_args
    while true; do
        printf '%b=== 核心管理 ===%b\n' "$CYAN" "$RESET"
        printf '%s\n' '1. 查看核心版本/Release' '2. 验证当前配置' '3. 部署本地已审计产物' '0. 返回'
        choice=$(prompt_menu 请选择)
        case "$choice" in
            0) return 0 ;;
            1) cmd_core_info ;;
            2) cmd_validate ;;
            3)
                ss=$(prompt_menu 'ssserver 路径（可留空）')
                xray=$(prompt_menu 'xray 路径（可留空）')
                deploy_args=()
                [[ -n "$ss" ]] && deploy_args+=(--ss "$ss")
                [[ -n "$xray" ]] && deploy_args+=(--xray "$xray")
                cmd_deploy "${deploy_args[@]}"
                ;;
            *) warn_msg '无效选项。' ;;
        esac
        menu_pause
    done
}

menu_remove() {
    local choice confirm
    while true; do
        printf '%b=== 节点卸载（需确认） ===%b\n' "$CYAN" "$RESET"
        printf '%s\n' '1. 卸载 Shadowsocks' '2. 卸载全部 VLESS' '3. 卸载全部节点' '0. 返回'
        choice=$(prompt_menu 请选择)
        case "$choice" in
            0) return 0 ;;
            1) confirm=$(prompt_menu '输入 DELETE 确认'); [[ "$confirm" == DELETE ]] && cmd_remove ss --yes || warn_msg '已取消。' ;;
            2) confirm=$(prompt_menu '输入 DELETE 确认'); [[ "$confirm" == DELETE ]] && cmd_remove xray --yes || warn_msg '已取消。' ;;
            3) confirm=$(prompt_menu '输入 DELETE 确认'); [[ "$confirm" == DELETE ]] && cmd_remove all --yes || warn_msg '已取消。' ;;
            *) warn_msg '无效选项。' ;;
        esac
        menu_pause
    done
}

cmd_menu() {
    require_root
    local section=all choice
    if [[ "${1:-}" == --section ]]; then
        [[ $# -ge 2 ]] || die '--section 缺少值'
        section=$2
        shift 2
    fi
    case "$section" in
        ss|reality|encryption) menu_try "${section} 安装" menu_install_one "$section"; return ;;
        nodes) menu_nodes; return ;;
        services) menu_services; return ;;
        config) menu_config; return ;;
        logs) menu_try 日志 cmd_logs all; return ;;
        firewall) menu_firewall; return ;;
        core) menu_core; return ;;
        remove) menu_remove; return ;;
        all) ;;
        *) die "未知菜单分区：$section" ;;
    esac
    while true; do
        clear 2>/dev/null || true
        printf '%b============================================%b\n' "$GREEN" "$RESET"
        printf '%b       ss-2022-own 统一管理菜单 v%s%b\n' "$GREEN" "$APP_VERSION" "$RESET"
        printf '%b============================================%b\n' "$GREEN" "$RESET"
        cmd_status || true
        printf '%b--------------------------------------------%b\n' "$CYAN" "$RESET"
        printf '%s\n' ' 1. Shadowsocks 2022 安装管理' ' 2. VLESS Reality 安装管理' ' 3. VLESS Encryption 安装管理' \
            ' 4. 节点管理（查看/删除）' ' 5. 服务管理（启停/重启）' ' 6. 配置与分享' ' 7. 运行日志' \
            ' 8. 防火墙管理（显式操作）' ' 9. 核心管理/版本/校验' '10. 卸载节点' ' 0. 退出'
        printf '%b--------------------------------------------%b\n' "$CYAN" "$RESET"
        choice=$(prompt_menu 请输入选项)
        case "$choice" in
            0) return 0 ;;
            1) menu_try SS2022安装 menu_install_one ss ;;
            2) menu_try Reality安装 menu_install_one reality ;;
            3) menu_try Encryption安装 menu_install_one encryption ;;
            4) menu_nodes ;;
            5) menu_services ;;
            6) menu_config ;;
            7) menu_try 日志 cmd_logs all ;;
            8) menu_firewall ;;
            9) menu_core ;;
            10) menu_remove ;;
            *) warn_msg '无效选项。'; menu_pause ;;
        esac
    done
}

main() {
    local command=${1:-}
    if [[ "$command" == -h || "$command" == --help || -z "$command" ]]; then
        usage
        [[ -n "$command" ]] && return 0 || return 1
    fi
    if [[ "$command" != --version ]]; then need jq; fi
    shift || true
    case "$command" in
        install)
            local kind=${1:-}; shift || true
            case "$kind" in
                ss) cmd_install_ss "$@" ;;
                reality) cmd_install_reality "$@" ;;
                encryption) cmd_install_encryption "$@" ;;
                *) die 'install 类型必须是 ss、reality 或 encryption。' ;;
            esac
            ;;
        deploy) cmd_deploy "$@" ;;
        show) cmd_show "$@" ;;
        status) cmd_status "$@" ;;
        core-info) cmd_core_info "$@" ;;
        logs) cmd_logs "$@" ;;
        validate) cmd_validate "$@" ;;
        service) cmd_service "$@" ;;
        remove) cmd_remove "$@" ;;
        firewall)
            local action=${1:-}; shift || true
            require_root
            local port='' protocol=both
            while (($#)); do
                case "$1" in
                    --port) [[ $# -ge 2 ]] || die '--port 缺少值'; port=$2; shift 2 ;;
                    --protocol) [[ $# -ge 2 ]] || die '--protocol 缺少值'; protocol=$2; shift 2 ;;
                    *) die "firewall 未知参数：$1" ;;
                esac
            done
            [[ -n "$port" ]] || die 'firewall 需要 --port。'
            case "$action" in
                open) firewall_open "$port" "$protocol" ;;
                close) firewall_close "$port" "$protocol" ;;
                *) die 'firewall 操作必须是 open 或 close。' ;;
            esac
            ;;
        menu) cmd_menu "$@" ;;
        --version) printf '%s\n' "$APP_NAME $APP_VERSION" ;;
        *) die "未知命令：$command" ;;
    esac
}

main "$@"
