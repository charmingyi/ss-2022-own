#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d -t ssown-test.XXXXXX)
FAKE_BIN=$(mktemp -d -t ssown-bin.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT" "$FAKE_BIN"' EXIT

cat >"$FAKE_BIN/ssserver" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$FAKE_BIN/xray" <<'EOF'
#!/bin/sh
# Config-test stub used only to test manager file/argument handling.
if [ "$1" = "run" ] && [ "$2" = "-test" ]; then exit 0; fi
exit 0
EOF
chmod 755 "$FAKE_BIN/ssserver" "$FAKE_BIN/xray"

export SSOWN_ROOT="$TEST_ROOT"
export SSOWN_NO_SYSTEMD=1
export SSOWN_NO_OPENRC=1
export SSOWN_SS_BIN="$FAKE_BIN/ssserver"
export SSOWN_XRAY_BIN="$FAKE_BIN/xray"

key_a=$(head -c 32 /dev/zero | base64 | tr '+/' '-_' | tr -d '=\r\n')
key_b=$(head -c 32 /dev/zero | base64 | tr '+/' '-_' | tr -d '=\r\n')
ss_password=$(head -c 32 /dev/zero | base64 | tr -d '\n')

run() { "$PROJECT_DIR/ssctl.sh" "$@"; }

run install ss --port 8388 --server-address node.example --password "$ss_password" --no-start >/dev/null
run install reality --port 443 --server-address node.example \
  --target www.example.com:443 --server-name www.example.com \
  --private-key "$key_a" --public-key "$key_b" --no-start >/dev/null
run install encryption --port 8443 --server-address node.example \
  --private-key "$key_a" --public-key "$key_b" --no-start >/dev/null

jq -e '.method == "2022-blake3-aes-256-gcm" and .server_port == 8388' \
  "$TEST_ROOT/etc/ss-2022-own/ss.json" >/dev/null
[[ "$(jq '.inbounds | length' "$TEST_ROOT/etc/ss-2022-own/xray.json")" -eq 2 ]]
jq -e 'any(.inbounds[]; .tag == "vless-reality" and .settings.decryption == "none" and .streamSettings.security == "reality")' \
  "$TEST_ROOT/etc/ss-2022-own/xray.json" >/dev/null
jq -e 'any(.inbounds[]; .tag == "vless-encryption" and (.settings.decryption | startswith("mlkem768x25519plus.native.600s.")) and .streamSettings.security == "none")' \
  "$TEST_ROOT/etc/ss-2022-own/xray.json" >/dev/null
jq -e '[.nodes[].kind] | sort == ["shadowsocks-2022", "vless-encryption", "vless-reality"]' \
  "$TEST_ROOT/etc/ss-2022-own/state.json" >/dev/null
[[ -f "$TEST_ROOT/etc/ss-2022-own/clients/vless-reality.json" ]]
[[ -f "$TEST_ROOT/etc/ss-2022-own/clients/vless-encryption.json" ]]

# Default output must not expose secret values.
redacted=$(run show)
case "$redacted" in
  *"$key_a"*|*"$ss_password"*)
    echo 'redaction failed' >&2
    exit 1
    ;;
esac

run validate >/dev/null
run remove --tag vless-reality --yes >/dev/null
jq -e 'all(.inbounds[]; .tag != "vless-reality")' "$TEST_ROOT/etc/ss-2022-own/xray.json" >/dev/null
run remove ss --yes >/dev/null
jq -e 'all(.nodes[]; .kind != "shadowsocks-2022")' "$TEST_ROOT/etc/ss-2022-own/state.json" >/dev/null

if run install ss --port 8390 --password 'not-a-2022-key' --no-start >/dev/null 2>&1; then
  echo 'invalid SS password was accepted' >&2
  exit 1
fi

printf '%s\n' 'manager tests: OK'
