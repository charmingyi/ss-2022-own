#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d -t ssown-test.XXXXXX)
FAKE_BIN=$(mktemp -d -t ssown-bin.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT" "$FAKE_BIN"' EXIT

cat >"$FAKE_BIN/ssserver" <<'EOF'
#!/bin/sh
[ "$1" = "--version" ] || [ "$1" = "-h" ] || [ "$1" = "-c" ]
exit 0
EOF
cat >"$FAKE_BIN/xray" <<'EOF'
#!/bin/sh
# Config-test stub used only to test the manager's file/argument handling.
if [ "$1" = "run" ] && [ "$2" = "-test" ]; then exit 0; fi
exit 0
EOF
chmod 755 "$FAKE_BIN/ssserver" "$FAKE_BIN/xray"

export SSOWN_ROOT="$TEST_ROOT"
export SSOWN_NO_SYSTEMD=1
export SSOWN_SS_BIN="$FAKE_BIN/ssserver"
export SSOWN_XRAY_BIN="$FAKE_BIN/xray"

key_a=$(python3 - <<'PY'
import base64
print(base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('='))
PY
)
key_b=$(python3 - <<'PY'
import base64
print(base64.urlsafe_b64encode(bytes(range(32, 64))).decode().rstrip('='))
PY
)
python3 - "$PROJECT_DIR" <<'PY'
import base64
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
import ssctl
seed = base64.urlsafe_b64encode(bytes(64)).decode().rstrip("=")
client = base64.urlsafe_b64encode(bytes(1184)).decode().rstrip("=")
assert ssctl.encryption_key_pair("mlkem768", seed, client) == (seed, client)
PY

run() { "$PROJECT_DIR/ssctl.sh" "$@"; }

ss_password=$(python3 - <<'PY'
import base64
print(base64.b64encode(bytes(32)).decode())
PY
)
run install ss --port 8388 --server-address node.example --password "$ss_password" >/dev/null
run install reality --port 443 --server-address node.example \
  --target www.example.com:443 --server-name www.example.com \
  --private-key "$key_a" --public-key "$key_b" --no-start >/dev/null
run install encryption --port 8443 --server-address node.example \
  --private-key "$key_a" --public-key "$key_b" --no-start >/dev/null

python3 - "$TEST_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
etc = root / "etc" / "ss-2022-own"
ss = json.loads((etc / "ss.json").read_text())
xray = json.loads((etc / "xray.json").read_text())
state = json.loads((etc / "state.json").read_text())
assert ss["method"] == "2022-blake3-aes-256-gcm"
assert len(xray["inbounds"]) == 2
reality = next(i for i in xray["inbounds"] if i["tag"] == "vless-reality")
encryption = next(i for i in xray["inbounds"] if i["tag"] == "vless-encryption")
assert reality["settings"]["decryption"] == "none"
assert reality["streamSettings"]["security"] == "reality"
assert encryption["settings"]["decryption"].startswith("mlkem768x25519plus.native.600s.")
assert encryption["streamSettings"]["security"] == "none"
assert {n["kind"] for n in state["nodes"]} == {"shadowsocks-2022", "vless-reality", "vless-encryption"}
assert (etc / "clients" / "vless-reality.json").exists()
assert (etc / "clients" / "vless-encryption.json").exists()
ss_unit = (root / "etc/systemd/system/ss-2022-own-ss.service").read_text()
xray_unit = (root / "etc/systemd/system/ss-2022-own-xray.service").read_text()
assert "User=ssown" in ss_unit
assert "CapabilityBoundingSet=CAP_NET_BIND_SERVICE" in xray_unit
PY

# Default output must not expose secrets.
redacted=$(run show)
case "$redacted" in
  *"$key_a"*|*"$ss_password"*)
    echo 'redaction failed' >&2
    exit 1
    ;;
esac

run validate >/dev/null
run remove --tag vless-reality --yes >/dev/null
! grep -q 'vless-reality' "$TEST_ROOT/etc/ss-2022-own/xray.json"
run remove ss --yes >/dev/null
python3 - "$TEST_ROOT" <<'PY'
import json
import pathlib
import sys
nodes = json.loads((pathlib.Path(sys.argv[1]) / "etc/ss-2022-own/state.json").read_text())["nodes"]
assert all(node["kind"] != "shadowsocks-2022" for node in nodes)
PY

if run install ss --port 8390 --password 'not-a-2022-key' >/dev/null 2>&1; then
  echo 'invalid SS password was accepted' >&2
  exit 1
fi

printf '%s\n' 'manager tests: OK'
