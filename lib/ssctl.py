#!/usr/bin/env python3
"""Auditable local manager for Shadowsocks 2022 and VLESS nodes.

This module deliberately does not download or execute remote scripts.  Core
binaries are supplied by build-core.sh (or by a separately reviewed release
artifact) and are only used after their paths have been checked.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import datetime as dt
import ipaddress
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import uuid as uuidlib
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote, urlencode

APP_NAME = "ss-2022-own"
APP_VERSION = "0.1.0"
SERVICE_USER = os.environ.get("SSOWN_SERVICE_USER", "ssown")


def rooted(path: str) -> Path:
    root = Path(os.environ.get("SSOWN_ROOT", "/")).resolve()
    return root / path.lstrip("/")


ETC_DIR = rooted("/etc/ss-2022-own")
STATE_FILE = ETC_DIR / "state.json"
SS_CONFIG = ETC_DIR / "ss.json"
XRAY_CONFIG = ETC_DIR / "xray.json"
BACKUP_DIR = ETC_DIR / "backup"
CLIENT_DIR = ETC_DIR / "clients"
BIN_DIR = rooted("/usr/local/libexec/ss-2022-own")
SS_BIN = BIN_DIR / "ssserver"
XRAY_BIN = BIN_DIR / "xray"
SYSTEMD_DIR = rooted("/etc/systemd/system")
SS_SERVICE = SYSTEMD_DIR / "ss-2022-own-ss.service"
XRAY_SERVICE = SYSTEMD_DIR / "ss-2022-own-xray.service"

# The custom build enables only the modern AEAD-2022 family.  Keeping the
# allow-list in sync with build-core.sh prevents a config from selecting a
# cipher that was intentionally not compiled into the binary.
SS_METHODS = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "2022-blake3-chacha20-poly1305": 32,
    "2022-blake3-chacha8-poly1305": 32,
}


class UserError(Exception):
    """An expected, user-facing error."""


def die(message: str) -> None:
    raise UserError(message)


def command_exists(command: str) -> bool:
    return shutil.which(command) is not None


def require_root() -> None:
    if ETC_DIR == Path("/etc/ss-2022-own") and hasattr(os, "geteuid") and os.geteuid() != 0:
        die("此操作需要 root；测试可设置 SSOWN_ROOT 指向临时目录。")


def can_use_systemd() -> bool:
    return (
        os.environ.get("SSOWN_NO_SYSTEMD") != "1"
        and ETC_DIR == Path("/etc/ss-2022-own")
        and command_exists("systemctl")
        and Path("/run/systemd/system").exists()
    )


def run_command(
    command: list[str], *, check: bool = True, capture: bool = False
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=check,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except FileNotFoundError as exc:
        die(f"找不到命令：{command[0]}")
        raise exc


def ensure_dir(path: Path, mode: int) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def ensure_app_dirs() -> None:
    ensure_dir(ETC_DIR, 0o750)
    ensure_dir(BACKUP_DIR, 0o700)
    ensure_dir(CLIENT_DIR, 0o700)
    ensure_dir(BIN_DIR, 0o755)


def reject_symlink(path: Path) -> None:
    if path.is_symlink():
        die(f"拒绝写入符号链接路径：{path}")


def atomic_write_text(path: Path, content: str, mode: int) -> None:
    # Callers set security-sensitive directory modes explicitly.  Do not chmod
    # an existing parent (e.g. /etc/systemd/system) as a side effect.
    path.parent.mkdir(parents=True, exist_ok=True)
    reject_symlink(path)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, mode)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def atomic_write_json(path: Path, value: Any, mode: int = 0o640) -> None:
    atomic_write_text(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n", mode)


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    if path.is_symlink():
        die(f"拒绝读取符号链接配置：{path}")
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        die(f"配置文件无法读取或不是合法 JSON：{path} ({exc})")
        raise exc


def timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def backup(path: Path) -> None:
    if path.is_symlink():
        die(f"拒绝备份符号链接：{path}")
    if not path.exists():
        return
    ensure_dir(BACKUP_DIR, 0o700)
    destination = BACKUP_DIR / f"{path.name}.{timestamp()}"
    shutil.copy2(path, destination)
    os.chmod(destination, 0o600)


def service_user_ready() -> None:
    if ETC_DIR != Path("/etc/ss-2022-own"):
        return
    try:
        import pwd

        pwd.getpwnam(SERVICE_USER)
        return
    except KeyError:
        pass
    if not command_exists("useradd"):
        die(f"未找到 useradd，无法创建系统用户 {SERVICE_USER}。")
    run_command(
        [
            "useradd",
            "--system",
            "--user-group",
            "--home-dir",
            "/nonexistent",
            "--shell",
            "/usr/sbin/nologin",
            SERVICE_USER,
        ]
    )


def chown_service_file(path: Path) -> None:
    if ETC_DIR != Path("/etc/ss-2022-own"):
        return
    try:
        shutil.chown(str(path), user="root", group=SERVICE_USER)
    except (OSError, LookupError) as exc:
        die(f"无法设置配置文件属主/属组：{path} ({exc})")


def write_service_file(path: Path, content: str) -> None:
    ensure_dir(SYSTEMD_DIR, 0o755)
    atomic_write_text(path, content, 0o644)


def write_config(path: Path, value: Any) -> None:
    atomic_write_json(path, value, 0o640)
    chown_service_file(path)


def initial_state() -> dict[str, Any]:
    return {"schema": 1, "app": APP_NAME, "version": APP_VERSION, "nodes": []}


def load_state() -> dict[str, Any]:
    state = load_json(STATE_FILE, initial_state())
    if not isinstance(state, dict) or state.get("schema") != 1:
        die(f"不支持的状态文件格式：{STATE_FILE}")
    nodes = state.get("nodes")
    if not isinstance(nodes, list):
        die(f"状态文件 nodes 字段损坏：{STATE_FILE}")
    return state


def save_state(state: dict[str, Any]) -> None:
    state["version"] = APP_VERSION
    write_config(STATE_FILE, state)
    try:
        os.chmod(STATE_FILE, 0o600)
    except OSError:
        pass


def upsert_node(state: dict[str, Any], node: dict[str, Any]) -> None:
    nodes = state["nodes"]
    nodes[:] = [item for item in nodes if item.get("tag") != node["tag"]]
    nodes.append(node)


def remove_nodes(state: dict[str, Any], predicate) -> list[dict[str, Any]]:
    removed = [node for node in state["nodes"] if predicate(node)]
    state["nodes"][:] = [node for node in state["nodes"] if not predicate(node)]
    return removed


def parse_port(value: Any, *, minimum: int = 1) -> int:
    try:
        port = int(value)
    except (TypeError, ValueError):
        die(f"端口必须是数字：{value}")
    if not minimum <= port <= 65535:
        die(f"端口必须在 {minimum}-65535 范围内：{port}")
    return port


def parse_listen(value: str) -> str:
    value = (value or "").strip()
    if not value or any(char in value for char in "\r\n\x00"):
        die("监听地址不能为空或包含控制字符。")
    if value not in {"0.0.0.0", "::"}:
        try:
            ipaddress.ip_address(value)
        except ValueError as exc:
            die(f"监听地址必须是 IP 地址（支持 0.0.0.0/::）：{value}")
            raise exc
    return value


def parse_server_address(value: str) -> str:
    value = (value or "").strip()
    if value == "<server-address>":
        return value
    if not value or any(char.isspace() or char in "\r\n\x00/\\" for char in value):
        die("server-address 必须是主机名或 IP 地址，不要带协议/端口/路径。")
    if value.startswith("[") or value.endswith("]"):
        die("server-address 不要使用 URI 的方括号形式；IPv6 请直接填写地址。")
    try:
        ipaddress.ip_address(value)
        return value
    except ValueError:
        pass
    if len(value) > 253 or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", value):
        die(f"无效 server-address：{value}")
    if ".." in value:
        die(f"无效 server-address：{value}")
    return value


def parse_target(value: str) -> str:
    value = (value or "").strip()
    if not value or any(char in value for char in "\r\n\x00/\\"):
        die("Reality target 必须是 host:port，且不能含控制字符或路径。")
    host = ""
    port_text = ""
    if value.startswith("["):
        end = value.find("]")
        if end < 0 or end + 1 >= len(value) or value[end + 1] != ":":
            die(f"无效 target：{value}（IPv6 请使用 [addr]:port）")
        host = value[1:end]
        port_text = value[end + 2 :]
    else:
        host, separator, port_text = value.rpartition(":")
        if not separator or ":" in host:
            die(f"无效 target：{value}（IPv6 请使用 [addr]:port）")
    if not host or any(char.isspace() for char in host):
        die(f"无效 target 主机名：{value}")
    parse_port(port_text)
    return value


def parse_server_name(value: str) -> str:
    value = (value or "").strip()
    if not value or len(value) > 253 or any(char.isspace() for char in value):
        die("server-name 不能为空、不能含空格且长度不能超过 253。")
    if any(char in value for char in "\r\n\x00/\\*"):
        die("server-name 不允许包含路径、通配符或控制字符。")
    return value


def validate_tag(value: str) -> str:
    value = (value or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", value):
        die("tag 只能包含字母、数字、点、下划线和短横线，且长度不超过 64。")
    return value


def validate_uuid(value: str) -> str:
    try:
        parsed = uuidlib.UUID(value)
    except (ValueError, AttributeError) as exc:
        die(f"必须是合法 UUID：{value}")
        raise exc
    return str(parsed)


def valid_raw_url_b64(value: str, length: int, label: str) -> str:
    value = (value or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        die(f"{label} 必须是无填充 base64url。")
    try:
        decoded = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (ValueError, binascii.Error) as exc:
        die(f"{label} 不是合法 base64url。")
        raise exc
    if len(decoded) != length:
        die(f"{label} 解码后必须是 {length} 字节，当前为 {len(decoded)}。")
    return value


def valid_short_id(value: str) -> str:
    value = (value or "").strip().lower()
    if len(value) > 16 or len(value) % 2 or not re.fullmatch(r"[0-9a-f]*", value):
        die("short-id 必须是 0-16 个偶数位十六进制字符。")
    return value


def valid_flow(value: str) -> str:
    value = (value or "").strip()
    if value not in {"", "xtls-rprx-vision"}:
        die("当前版本只允许空 flow 或 xtls-rprx-vision。")
    return value


def valid_appearance(value: str) -> str:
    value = (value or "").strip().lower()
    if value not in {"native", "xorpub", "random"}:
        die("VLESS Encryption appearance 必须是 native、xorpub 或 random。")
    return value


def valid_ttl(value: str) -> str:
    value = (value or "").strip().lower()
    if value == "0s":
        return value
    if not re.fullmatch(r"[1-9][0-9]*(?:-[1-9][0-9]*)?s", value):
        die("ticket-ttl 示例：600s、300-600s 或 0s（仅 1-RTT）。")
    if "-" in value:
        lower, upper = value[:-1].split("-", 1)
        if int(lower) > int(upper):
            die("ticket-ttl 范围必须从小到大。")
    return value


def generate_ss_password(method: str) -> str:
    size = SS_METHODS[method]
    if size is None:
        return base64.b64encode(secrets.token_bytes(32)).decode("ascii")
    return base64.b64encode(secrets.token_bytes(size)).decode("ascii")


def validate_ss_password(method: str, value: str) -> str:
    value = (value or "").strip()
    if not value or any(char in value for char in "\r\n\x00"):
        die("Shadowsocks 密码不能为空或包含控制字符。")
    required = SS_METHODS[method]
    if required is not None:
        try:
            decoded = base64.b64decode(value, validate=True)
        except (ValueError, binascii.Error) as exc:
            die(f"{method} 密码必须是标准 base64 编码。")
            raise exc
        if len(decoded) != required:
            die(f"{method} 密码解码后必须是 {required} 字节，当前为 {len(decoded)}。")
    return value


def binary_path(kind: str) -> Path:
    configured = os.environ.get("SSOWN_SS_BIN" if kind == "ss" else "SSOWN_XRAY_BIN")
    return Path(configured) if configured else (SS_BIN if kind == "ss" else XRAY_BIN)


def require_binary(kind: str) -> Path:
    path = binary_path(kind)
    if not path.is_file() or not os.access(path, os.X_OK):
        die(
            f"未找到可执行 {kind} 核心：{path}\n"
            "请先运行 ./build-core.sh 并用 ssctl.sh deploy 部署构建产物。"
        )
    if path.is_symlink():
        die(f"拒绝使用符号链接核心：{path}")
    return path


def parse_keygen_output(output: str) -> tuple[str | None, str | None]:
    private = None
    public = None
    for line in output.splitlines():
        line = line.strip()
        match = re.match(r"(?:Private key|PrivateKey)\s*:\s*(\S+)$", line, re.I)
        if match:
            private = match.group(1)
            continue
        match = re.match(r"(?:Password|Public key|PublicKey)\s*:\s*(\S+)$", line, re.I)
        if match:
            public = match.group(1)
    return private, public


def x25519_pair(private: str | None, public: str | None) -> tuple[str, str]:
    if public and not private:
        die("只提供 public-key 无法恢复对应私钥；请同时提供 private-key，或两者都留空。")
    if private and public:
        return (
            valid_raw_url_b64(private, 32, "private-key"),
            valid_raw_url_b64(public, 32, "public-key"),
        )
    xray = require_binary("xray")
    command = [str(xray), "x25519"]
    if private:
        command.extend(["-i", private])
    result = run_command(command, capture=True)
    parsed_private, parsed_public = parse_keygen_output((result.stdout or "") + (result.stderr or ""))
    parsed_private = private or parsed_private
    parsed_public = public or parsed_public
    if not parsed_private or not parsed_public:
        die("无法解析 xray x25519 输出；请显式提供 private-key 和 public-key。")
    return (
        valid_raw_url_b64(parsed_private, 32, "private-key"),
        valid_raw_url_b64(parsed_public, 32, "public-key"),
    )


def parse_mlkem_output(output: str) -> tuple[str | None, str | None]:
    seed = None
    client = None
    for line in output.splitlines():
        line = line.strip()
        match = re.match(r"Seed\s*:\s*(\S+)$", line, re.I)
        if match:
            seed = match.group(1)
            continue
        match = re.match(r"Client\s*:\s*(\S+)$", line, re.I)
        if match:
            client = match.group(1)
    return seed, client


def mlkem768_pair(seed: str | None, client: str | None) -> tuple[str, str]:
    if client and not seed:
        die("只提供 ML-KEM Client 无法恢复 Seed；请同时提供 Seed 和 Client，或两者都留空。")
    if seed and client:
        return (
            valid_raw_url_b64(seed, 64, "mlkem-seed"),
            valid_raw_url_b64(client, 1184, "mlkem-client"),
        )
    xray = require_binary("xray")
    result = run_command([str(xray), "mlkem768"], capture=True)
    parsed_seed, parsed_client = parse_mlkem_output((result.stdout or "") + (result.stderr or ""))
    if not parsed_seed or not parsed_client:
        die("无法解析 xray mlkem768 输出；请显式提供 ML-KEM Seed 和 Client。")
    return (
        valid_raw_url_b64(parsed_seed, 64, "mlkem-seed"),
        valid_raw_url_b64(parsed_client, 1184, "mlkem-client"),
    )


def encryption_key_pair(auth: str, private: str | None, public: str | None) -> tuple[str, str]:
    if auth == "x25519":
        return x25519_pair(private, public)
    if auth == "mlkem768":
        return mlkem768_pair(private, public)
    die("VLESS Encryption auth 必须是 x25519 或 mlkem768。")


def random_uuid(value: str | None) -> str:
    return validate_uuid(value) if value else str(uuidlib.uuid4())


def default_xray_config() -> dict[str, Any]:
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [],
        "outbounds": [
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"},
        ],
    }


def load_xray_config() -> dict[str, Any]:
    config = load_json(XRAY_CONFIG, default_xray_config())
    if not isinstance(config, dict) or not isinstance(config.get("inbounds", []), list):
        die(f"Xray 配置结构损坏：{XRAY_CONFIG}")
    if not all(isinstance(item, dict) for item in config["inbounds"]):
        die(f"Xray inbounds 必须全部是对象：{XRAY_CONFIG}")
    config.setdefault("log", {"loglevel": "warning"})
    config.setdefault("outbounds", default_xray_config()["outbounds"])
    return config


def upsert_inbound(config: dict[str, Any], inbound: dict[str, Any]) -> None:
    tag = inbound["tag"]
    config["inbounds"][:] = [item for item in config["inbounds"] if item.get("tag") != tag]
    existing_ports = {
        int(item.get("port"))
        for item in config["inbounds"]
        if isinstance(item, dict) and str(item.get("port", "")).isdigit()
    }
    if inbound["port"] in existing_ports:
        die(f"Xray 端口已被其他 inbound 使用：{inbound['port']}")
    config["inbounds"].append(inbound)


def xray_has_privileged_port(config: dict[str, Any]) -> bool:
    return any(
        isinstance(item, dict)
        and isinstance(item.get("port"), int)
        and item["port"] < 1024
        for item in config.get("inbounds", [])
    )


def xray_reality_stream_server(
    listen: str, target: str, server_name: str, private_key: str, short_id: str
) -> dict[str, Any]:
    return {
        "network": "tcp",
        "security": "reality",
        "tcpSettings": {"header": {"type": "none"}},
        "realitySettings": {
            "show": False,
            "target": target,
            "xver": 0,
            "serverNames": [server_name],
            "privateKey": private_key,
            "shortIds": [short_id],
        },
    }


def xray_tcp_stream() -> dict[str, Any]:
    return {
        "network": "tcp",
        "security": "none",
        "tcpSettings": {"header": {"type": "none"}},
    }


def xray_reality_client(node: dict[str, Any]) -> dict[str, Any]:
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True},
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": node["server_address"],
                            "port": node["port"],
                            "users": [
                                {
                                    "id": node["uuid"],
                                    "encryption": "none",
                                    "flow": node["flow"],
                                }
                            ],
                        }
                    ]
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "serverName": node["server_name"],
                        "fingerprint": node["fingerprint"],
                        "password": node["public_key"],
                        "shortId": node["short_id"],
                        "spiderX": node["spider_x"],
                    },
                },
            },
            {"tag": "direct", "protocol": "freedom"},
        ],
    }


def xray_encryption_client(node: dict[str, Any]) -> dict[str, Any]:
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True},
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": node["server_address"],
                            "port": node["port"],
                            "users": [
                                {
                                    "id": node["uuid"],
                                    "encryption": node["client_encryption"],
                                    "flow": node["flow"],
                                }
                            ],
                        }
                    ]
                },
                "streamSettings": xray_tcp_stream(),
            },
            {"tag": "direct", "protocol": "freedom"},
        ],
    }


def uri_host(address: str) -> str:
    try:
        if isinstance(ipaddress.ip_address(address), ipaddress.IPv6Address):
            return f"[{address}]"
    except ValueError:
        pass
    return address


def make_vless_uri(node: dict[str, Any]) -> str:
    if node["kind"] == "vless-reality":
        query = {
            "encryption": "none",
            "flow": node["flow"],
            "security": "reality",
            "sni": node["server_name"],
            "fp": node["fingerprint"],
            "pbk": node["public_key"],
            "sid": node["short_id"],
            "spx": node["spider_x"],
            "type": "tcp",
        }
    else:
        query = {
            "encryption": node["client_encryption"],
            "flow": node["flow"],
            "security": "none",
            "type": "tcp",
        }
    query = {key: value for key, value in query.items() if value != ""}
    title = quote(node["tag"], safe="-._~")
    return (
        f"vless://{node['uuid']}@{uri_host(node['server_address'])}:{node['port']}?"
        f"{urlencode(query, safe='-._~')}#{title}"
    )


def make_ss_uri(node: dict[str, Any]) -> str:
    userinfo = base64.urlsafe_b64encode(
        f"{node['method']}:{node['password']}".encode("utf-8")
    ).decode("ascii").rstrip("=")
    return (
        f"ss://{userinfo}@{uri_host(node['server_address'])}:{node['port']}"
        f"?udp=true#{quote(node['tag'], safe='-._~')}"
    )


def write_client_file(node: dict[str, Any], client: dict[str, Any]) -> Path:
    path = CLIENT_DIR / f"{node['tag']}.json"
    backup(path)
    atomic_write_json(path, client, 0o600)
    return path


def xray_service_content(low_port: bool) -> str:
    capability = "CAP_NET_BIND_SERVICE" if low_port else ""
    return f"""[Unit]
Description=Auditable Xray core for {APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={SERVICE_USER}
Group={SERVICE_USER}
ExecStart={XRAY_BIN} run -c {XRAY_CONFIG}
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
CapabilityBoundingSet={capability}
AmbientCapabilities={capability}
UMask=0027
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""


def ss_service_content(low_port: bool) -> str:
    capability = "CAP_NET_BIND_SERVICE" if low_port else ""
    return f"""[Unit]
Description=Auditable Shadowsocks Rust core for {APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={SERVICE_USER}
Group={SERVICE_USER}
ExecStart={SS_BIN} -c {SS_CONFIG}
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
CapabilityBoundingSet={capability}
AmbientCapabilities={capability}
UMask=0027
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""


def systemctl(*arguments: str, check: bool = True) -> bool:
    if not can_use_systemd():
        print("[提示] 当前环境未执行 systemd 操作；配置文件已写入。")
        return True
    result = run_command(["systemctl", *arguments], check=False, capture=True)
    if check and result.returncode != 0:
        output = (result.stderr or result.stdout or "").strip()
        die(f"systemctl {' '.join(arguments)} 失败：{output}")
    return result.returncode == 0


def apply_service(path: Path, name: str, *, start: bool) -> None:
    systemctl("daemon-reload")
    systemctl("enable", name)
    if start:
        systemctl("restart", name)


def validate_xray_file(config_path: Path, *, warn_missing: bool = True) -> None:
    path = binary_path("xray")
    if not path.is_file() or not os.access(path, os.X_OK):
        if warn_missing:
            print(f"[警告] 未找到 Xray 核心，跳过运行时配置测试：{path}", file=sys.stderr)
        return
    result = run_command(
        [str(path), "run", "-test", "-c", str(config_path)], check=False, capture=True
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        die(f"Xray 配置测试失败：{detail}")


def validate_xray_with_binary() -> None:
    if XRAY_CONFIG.exists():
        validate_xray_file(XRAY_CONFIG)


def validate_xray_candidate(config: dict[str, Any]) -> None:
    """Validate a candidate before replacing the live Xray configuration."""
    ensure_app_dirs()
    fd, temporary = tempfile.mkstemp(prefix=".xray-check.", suffix=".json", dir=str(ETC_DIR))
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(config, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, 0o600)
        validate_xray_file(temporary_path, warn_missing=False)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def install_ss(args: argparse.Namespace) -> None:
    require_root()
    ensure_app_dirs()
    service_user_ready()
    require_binary("ss")
    method = args.method
    if method not in SS_METHODS:
        die(f"不支持的 Shadowsocks 加密方式：{method}")
    port = parse_port(args.port)
    listen = parse_listen(args.listen)
    password = args.password
    if args.password_stdin:
        password = sys.stdin.readline().strip()
    password = validate_ss_password(method, password or generate_ss_password(method))
    address = parse_server_address(args.server_address or "<server-address>")
    node = {
        "kind": "shadowsocks-2022",
        "tag": validate_tag(args.tag),
        "listen": listen,
        "server_address": address,
        "port": port,
        "method": method,
        "password": password,
        "fast_open": bool(args.fast_open),
    }
    config = {
        "server": listen,
        "server_port": port,
        "password": password,
        "method": method,
        "mode": "tcp_and_udp",
        "fast_open": bool(args.fast_open),
        "timeout": 300,
    }
    backup(SS_CONFIG)
    write_config(SS_CONFIG, config)
    state = load_state()
    upsert_node(state, node)
    save_state(state)
    write_service_file(SS_SERVICE, ss_service_content(port < 1024))
    apply_service(SS_SERVICE, "ss-2022-own-ss.service", start=not args.no_start)
    if args.open_firewall:
        firewall_open(port, "both")
    print_node(node, reveal=False)
    print("配置已写入；如需在受控终端查看分享信息，请执行 ssctl.sh show --reveal。")


def install_reality(args: argparse.Namespace) -> None:
    require_root()
    ensure_app_dirs()
    service_user_ready()
    require_binary("xray")
    port = parse_port(args.port)
    listen = parse_listen(args.listen)
    tag = validate_tag(args.tag)
    target = parse_target(args.target)
    server_name = parse_server_name(args.server_name)
    flow = valid_flow(args.flow)
    private_key, public_key = x25519_pair(args.private_key, args.public_key)
    short_id = valid_short_id(args.short_id or secrets.token_hex(8))
    server_address = parse_server_address(args.server_address or "<server-address>")
    spider_x = args.spider_x.strip()
    if not spider_x.startswith("/") or any(char in spider_x for char in "\r\n\x00"):
        die("spider-x 必须是以 / 开头的路径。")
    node = {
        "kind": "vless-reality",
        "tag": tag,
        "listen": listen,
        "server_address": server_address,
        "port": port,
        "uuid": random_uuid(args.uuid),
        "flow": flow,
        "target": target,
        "server_name": server_name,
        "fingerprint": args.fingerprint.strip().lower(),
        "short_id": short_id,
        "private_key": private_key,
        "public_key": public_key,
        "spider_x": spider_x,
    }
    if not re.fullmatch(r"[a-z0-9_-]{1,32}", node["fingerprint"]):
        die("fingerprint 只能包含小写字母、数字、下划线和短横线。")
    inbound = {
        "tag": tag,
        "listen": listen,
        "port": port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": node["uuid"], "flow": flow, "email": f"{tag}@local"}],
            "decryption": "none",
        },
        "streamSettings": xray_reality_stream_server(
            listen, target, server_name, private_key, short_id
        ),
    }
    config = load_xray_config()
    upsert_inbound(config, inbound)
    validate_xray_candidate(config)
    backup(XRAY_CONFIG)
    write_config(XRAY_CONFIG, config)
    state = load_state()
    upsert_node(state, node)
    save_state(state)
    client_path = write_client_file(node, xray_reality_client(node))
    write_service_file(XRAY_SERVICE, xray_service_content(xray_has_privileged_port(config)))
    validate_xray_with_binary()
    apply_service(XRAY_SERVICE, "ss-2022-own-xray.service", start=not args.no_start)
    if args.open_firewall:
        firewall_open(port, "tcp")
    print_node(node, reveal=False)
    print(f"客户端 JSON 已写入：{client_path}")
    print("私钥仅保存于 root-only 状态/服务端配置；如需查看分享信息，请执行 ssctl.sh show --reveal。")


def install_encryption(args: argparse.Namespace) -> None:
    require_root()
    ensure_app_dirs()
    service_user_ready()
    require_binary("xray")
    port = parse_port(args.port)
    listen = parse_listen(args.listen)
    tag = validate_tag(args.tag)
    appearance = valid_appearance(args.appearance)
    ticket_ttl = valid_ttl(args.ticket_ttl)
    flow = valid_flow(args.flow)
    auth = args.auth
    if auth not in {"x25519", "mlkem768"}:
        die("VLESS Encryption auth 必须是 x25519 或 mlkem768。")
    private_key, public_key = encryption_key_pair(auth, args.private_key, args.public_key)
    server_address = parse_server_address(args.server_address or "<server-address>")
    decryption = f"mlkem768x25519plus.{appearance}.{ticket_ttl}.{private_key}"
    client_encryption = f"mlkem768x25519plus.{appearance}.0rtt.{public_key}"
    node = {
        "kind": "vless-encryption",
        "tag": tag,
        "listen": listen,
        "server_address": server_address,
        "port": port,
        "uuid": random_uuid(args.uuid),
        "flow": flow,
        "auth": auth,
        "appearance": appearance,
        "ticket_ttl": ticket_ttl,
        "private_key": private_key,
        "public_key": public_key,
        "decryption": decryption,
        "client_encryption": client_encryption,
    }
    inbound = {
        "tag": tag,
        "listen": listen,
        "port": port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": node["uuid"], "flow": flow, "email": f"{tag}@local"}],
            "decryption": decryption,
        },
        "streamSettings": xray_tcp_stream(),
    }
    config = load_xray_config()
    upsert_inbound(config, inbound)
    validate_xray_candidate(config)
    backup(XRAY_CONFIG)
    write_config(XRAY_CONFIG, config)
    state = load_state()
    upsert_node(state, node)
    save_state(state)
    client_path = write_client_file(node, xray_encryption_client(node))
    write_service_file(XRAY_SERVICE, xray_service_content(xray_has_privileged_port(config)))
    validate_xray_with_binary()
    apply_service(XRAY_SERVICE, "ss-2022-own-xray.service", start=not args.no_start)
    if args.open_firewall:
        firewall_open(port, "tcp")
    print_node(node, reveal=False)
    print(f"客户端 JSON 已写入：{client_path}")
    print("VLESS Encryption 是协议层加密，不等同于 TLS/Reality 外观；如需查看分享信息，请执行 ssctl.sh show --reveal。")


def deploy(args: argparse.Namespace) -> None:
    require_root()
    ensure_app_dirs()
    copied: list[Path] = []
    for source, target_name in ((args.ss, "ssserver"), (args.xray, "xray")):
        if not source:
            continue
        source_input = Path(source).expanduser()
        if source_input.is_symlink():
            die(f"拒绝部署符号链接文件：{source_input}")
        source_path = source_input.resolve()
        if not source_path.is_file():
            die(f"拒绝部署不存在的文件：{source_path}")
        destination = BIN_DIR / target_name
        temporary = BIN_DIR / f".{target_name}.new"
        shutil.copyfile(source_path, temporary)
        os.chmod(temporary, 0o755)
        os.replace(temporary, destination)
        copied.append(destination)
    if not copied:
        die("至少提供 --ss 或 --xray 一个构建产物路径。")
    for path in copied:
        print(f"已部署：{path}")


def service_operation(args: argparse.Namespace) -> None:
    require_root()
    targets = []
    if args.kind in {"ss", "all"}:
        targets.append("ss-2022-own-ss.service")
    if args.kind in {"xray", "all"}:
        targets.append("ss-2022-own-xray.service")
    for name in targets:
        if args.action == "enable":
            systemctl("enable", name)
        elif args.action == "disable":
            systemctl("disable", name, check=False)
        elif args.action == "start":
            systemctl("start", name)
        elif args.action == "stop":
            systemctl("stop", name, check=False)
        elif args.action == "restart":
            systemctl("restart", name)
        elif args.action == "status":
            systemctl("--no-pager", "status", name, check=False)


def firewall_active_ufw() -> bool:
    if not command_exists("ufw"):
        return False
    result = run_command(["ufw", "status"], check=False, capture=True)
    return "Status: active" in (result.stdout or "")


def firewall_active_firewalld() -> bool:
    if not command_exists("firewall-cmd"):
        return False
    result = run_command(["firewall-cmd", "--state"], check=False, capture=True)
    return result.returncode == 0 and (result.stdout or "").strip() == "running"


def firewall_open(port: int, protocol: str) -> None:
    require_root()
    port = parse_port(port)
    protocols = ["tcp", "udp"] if protocol == "both" else [protocol]
    if protocol not in {"tcp", "udp", "both"}:
        die("防火墙协议必须是 tcp、udp 或 both。")
    if firewall_active_ufw():
        for proto in protocols:
            run_command(["ufw", "allow", f"{port}/{proto}"])
        print(f"UFW 已放行 {port}/{','.join(protocols)}")
        return
    if firewall_active_firewalld():
        for proto in protocols:
            run_command(["firewall-cmd", "--permanent", f"--add-port={port}/{proto}"])
        run_command(["firewall-cmd", "--reload"])
        print(f"firewalld 已放行 {port}/{','.join(protocols)}")
        return
    print(
        f"未检测到已启用的 UFW/firewalld；未修改规则。请手动放行："
        f" {port}/{','.join(protocols)}"
    )


def firewall_close(port: int, protocol: str) -> None:
    require_root()
    port = parse_port(port)
    protocols = ["tcp", "udp"] if protocol == "both" else [protocol]
    if firewall_active_ufw():
        for proto in protocols:
            run_command(["ufw", "delete", "allow", f"{port}/{proto}"], check=False)
        return
    if firewall_active_firewalld():
        for proto in protocols:
            run_command(
                ["firewall-cmd", "--permanent", f"--remove-port={port}/{proto}"],
                check=False,
            )
        run_command(["firewall-cmd", "--reload"], check=False)
        return
    print("未检测到已启用的 UFW/firewalld；未修改规则。")


def redact_node(node: dict[str, Any]) -> dict[str, Any]:
    redacted = dict(node)
    for key in ("password", "private_key", "public_key", "decryption", "client_encryption"):
        if key in redacted:
            redacted[key] = "<hidden>"
    return redacted


def print_node(node: dict[str, Any], *, reveal: bool) -> None:
    print(json.dumps(node if reveal else redact_node(node), ensure_ascii=False, indent=2))
    if reveal:
        if node["kind"] == "shadowsocks-2022":
            print(f"分享链接：{make_ss_uri(node)}")
        else:
            print(f"分享链接：{make_vless_uri(node)}")


def show(args: argparse.Namespace) -> None:
    state = load_state()
    nodes = state["nodes"]
    if args.tag:
        nodes = [node for node in nodes if node.get("tag") == args.tag]
    if args.server_address:
        address = parse_server_address(args.server_address)
        nodes = [dict(node, server_address=address) for node in nodes]
    if not nodes:
        print("暂无节点。")
        return
    for index, node in enumerate(nodes):
        if index:
            print("\n---")
        print_node(node, reveal=args.reveal)


def status(_: argparse.Namespace) -> None:
    state = load_state()
    for node in state["nodes"]:
        name = {
            "shadowsocks-2022": "Shadowsocks",
            "vless-reality": "VLESS Reality",
            "vless-encryption": "VLESS Encryption",
        }.get(node.get("kind"), node.get("kind", "unknown"))
        print(f"{name:20} {node.get('tag', '-'):<24} :{node.get('port', '-')} ", end="")
        if node.get("kind") == "shadowsocks-2022":
            service = "ss-2022-own-ss.service"
        else:
            service = "ss-2022-own-xray.service"
        if can_use_systemd():
            active = systemctl("is-active", service, check=False)
            print("running" if active else "stopped")
        else:
            print("configured")


def validate(args: argparse.Namespace) -> None:
    if SS_CONFIG.exists():
        config = load_json(SS_CONFIG, {})
        if not isinstance(config, dict):
            die("Shadowsocks JSON 根对象无效。")
        parse_port(config.get("server_port"))
        method = config.get("method")
        if method not in SS_METHODS:
            die(f"未知 Shadowsocks method：{method}")
        validate_ss_password(method, str(config.get("password", "")))
        print(f"SS 配置 OK：{SS_CONFIG}")
    if XRAY_CONFIG.exists():
        config = load_xray_config()
        for inbound in config.get("inbounds", []):
            if not isinstance(inbound, dict):
                die("Xray inbound 必须是对象。")
            parse_port(inbound.get("port"))
            if not inbound.get("protocol"):
                die("Xray inbound 缺少 protocol。")
        validate_xray_with_binary()
        print(f"Xray 配置 OK：{XRAY_CONFIG}")
    if not SS_CONFIG.exists() and not XRAY_CONFIG.exists():
        print("暂无配置文件。")


def remove(args: argparse.Namespace) -> None:
    require_root()
    if not args.yes:
        die("删除操作需要显式传入 --yes。")
    state = load_state()
    if args.tag:
        tag = validate_tag(args.tag)
        config = load_xray_config()
        before = len(config["inbounds"])
        config["inbounds"][:] = [item for item in config["inbounds"] if item.get("tag") != tag]
        if len(config["inbounds"]) == before:
            die(f"未找到 Xray 节点：{tag}")
        backup(XRAY_CONFIG)
        write_config(XRAY_CONFIG, config)
        if config["inbounds"]:
            write_service_file(XRAY_SERVICE, xray_service_content(xray_has_privileged_port(config)))
        else:
            systemctl("disable", "--now", "ss-2022-own-xray.service", check=False)
            if XRAY_SERVICE.exists():
                XRAY_SERVICE.unlink()
        remove_nodes(state, lambda node: node.get("tag") == tag)
        client_path = CLIENT_DIR / f"{tag}.json"
        if client_path.exists():
            backup(client_path)
            client_path.unlink()
        save_state(state)
        validate_xray_with_binary()
        if can_use_systemd():
            systemctl("restart", "ss-2022-own-xray.service", check=False)
        print(f"已删除 Xray 节点：{tag}")
        return
    if args.kind in {"ss", "all"}:
        if SS_CONFIG.exists():
            backup(SS_CONFIG)
            SS_CONFIG.unlink()
        systemctl("disable", "--now", "ss-2022-own-ss.service", check=False)
        if SS_SERVICE.exists():
            SS_SERVICE.unlink()
        remove_nodes(state, lambda node: node.get("kind") == "shadowsocks-2022")
    if args.kind in {"xray", "all"}:
        if XRAY_CONFIG.exists():
            backup(XRAY_CONFIG)
            XRAY_CONFIG.unlink()
        systemctl("disable", "--now", "ss-2022-own-xray.service", check=False)
        if XRAY_SERVICE.exists():
            XRAY_SERVICE.unlink()
        for node in list(state["nodes"]):
            if node.get("kind", "").startswith("vless-"):
                client_path = CLIENT_DIR / f"{node.get('tag')}.json"
                if client_path.exists():
                    backup(client_path)
                    client_path.unlink()
        state["nodes"][:] = [
            node
            for node in state["nodes"]
            if not (node.get("kind", "").startswith("vless-") or args.kind == "all")
        ]
    if args.kind == "all":
        state["nodes"].clear()
    save_state(state)
    if can_use_systemd():
        systemctl("daemon-reload", check=False)
    print("删除完成。")


def prompt(text: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{text}{suffix}: ").strip()
    return value or default


def menu(_: argparse.Namespace) -> None:
    require_root()
    while True:
        print("\n=== ss-2022-own 管理菜单 ===")
        print("1. 安装/覆盖 Shadowsocks 2022")
        print("2. 安装/覆盖 VLESS Reality")
        print("3. 安装/覆盖 VLESS Encryption")
        print("4. 查看节点（隐藏密钥）")
        print("5. 查看节点（显示分享信息）")
        print("6. 服务状态")
        print("0. 退出")
        choice = input("请选择: ").strip()
        if choice == "0":
            return
        if choice == "4":
            show(argparse.Namespace(tag=None, reveal=False, server_address=None))
            continue
        if choice == "5":
            show(argparse.Namespace(tag=None, reveal=True, server_address=None))
            continue
        if choice == "6":
            status(argparse.Namespace())
            continue
        if choice == "1":
            args = argparse.Namespace(
                method=prompt("method", "2022-blake3-aes-256-gcm"),
                port=int(prompt("端口", "8388")),
                listen=prompt("监听地址", "0.0.0.0"),
                server_address=prompt("服务器地址（可留空）", ""),
                tag=prompt("tag", "ss2022"),
                password=None,
                password_stdin=False,
                fast_open=True,
                no_start=False,
                open_firewall=False,
            )
            install_ss(args)
            continue
        if choice == "2":
            args = argparse.Namespace(
                port=int(prompt("端口", "443")),
                listen=prompt("监听地址", "0.0.0.0"),
                server_address=prompt("服务器地址（可留空）", ""),
                tag=prompt("tag", "vless-reality"),
                target=prompt("伪装目标 host:port", "www.example.com:443"),
                server_name=prompt("允许的 SNI", "www.example.com"),
                uuid=None,
                flow="xtls-rprx-vision",
                fingerprint="chrome",
                short_id="",
                private_key=None,
                public_key=None,
                spider_x="/",
                no_start=False,
                open_firewall=False,
            )
            install_reality(args)
            continue
        if choice == "3":
            args = argparse.Namespace(
                port=int(prompt("端口", "8443")),
                listen=prompt("监听地址", "0.0.0.0"),
                server_address=prompt("服务器地址（可留空）", ""),
                tag=prompt("tag", "vless-encryption"),
                uuid=None,
                flow="xtls-rprx-vision",
                auth=prompt("auth (x25519/mlkem768)", "x25519"),
                appearance=prompt("appearance", "native"),
                ticket_ttl=prompt("ticket TTL", "600s"),
                private_key=None,
                public_key=None,
                no_start=False,
                open_firewall=False,
            )
            install_encryption(args)
            continue
        print("无效选项。")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ssctl",
        description="审计友好的 Shadowsocks 2022 / VLESS Reality / VLESS Encryption 管理器",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    install = sub.add_parser("install", help="生成配置并安装 systemd 服务")
    install_sub = install.add_subparsers(dest="kind", required=True)

    ss = install_sub.add_parser("ss", help="安装 Shadowsocks 2022")
    ss.add_argument("--method", default="2022-blake3-aes-256-gcm", choices=sorted(SS_METHODS))
    ss.add_argument("--port", type=int, default=8388)
    ss.add_argument("--listen", default="0.0.0.0")
    ss.add_argument("--server-address", default="")
    ss.add_argument("--tag", default="ss2022")
    ss.add_argument("--password")
    ss.add_argument("--password-stdin", action="store_true")
    ss.add_argument("--fast-open", action=argparse.BooleanOptionalAction, default=True)
    ss.add_argument("--no-start", action="store_true")
    ss.add_argument("--open-firewall", action="store_true")
    ss.set_defaults(handler=install_ss)

    reality = install_sub.add_parser("reality", help="安装 VLESS + Reality")
    reality.add_argument("--port", type=int, default=443)
    reality.add_argument("--listen", default="0.0.0.0")
    reality.add_argument("--server-address", default="")
    reality.add_argument("--tag", default="vless-reality")
    reality.add_argument("--target", required=True, help="Reality fallback target，例如 www.example.com:443")
    reality.add_argument("--server-name", required=True)
    reality.add_argument("--uuid")
    reality.add_argument("--flow", default="xtls-rprx-vision")
    reality.add_argument("--fingerprint", default="chrome")
    reality.add_argument("--short-id")
    reality.add_argument("--private-key")
    reality.add_argument("--public-key")
    reality.add_argument("--spider-x", default="/")
    reality.add_argument("--no-start", action="store_true")
    reality.add_argument("--open-firewall", action="store_true")
    reality.set_defaults(handler=install_reality)

    encryption = install_sub.add_parser("encryption", help="安装 VLESS Encryption")
    encryption.add_argument("--port", type=int, default=8443)
    encryption.add_argument("--listen", default="0.0.0.0")
    encryption.add_argument("--server-address", default="")
    encryption.add_argument("--tag", default="vless-encryption")
    encryption.add_argument("--uuid")
    encryption.add_argument("--flow", default="xtls-rprx-vision")
    encryption.add_argument("--auth", default="x25519", choices=["x25519", "mlkem768"])
    encryption.add_argument("--appearance", default="native", choices=["native", "xorpub", "random"])
    encryption.add_argument("--ticket-ttl", default="600s")
    encryption.add_argument("--private-key")
    encryption.add_argument("--public-key")
    encryption.add_argument("--no-start", action="store_true")
    encryption.add_argument("--open-firewall", action="store_true")
    encryption.set_defaults(handler=install_encryption)

    deploy_parser = sub.add_parser("deploy", help="部署 build-core.sh 生成的核心产物")
    deploy_parser.add_argument("--ss")
    deploy_parser.add_argument("--xray")
    deploy_parser.set_defaults(handler=deploy)

    show_parser = sub.add_parser("show", help="查看节点信息")
    show_parser.add_argument("--tag")
    show_parser.add_argument("--reveal", action="store_true", help="显示密码/分享链接")
    show_parser.add_argument("--server-address", help="临时替换分享链接中的服务器地址")
    show_parser.set_defaults(handler=show)

    status_parser = sub.add_parser("status", help="查看服务状态")
    status_parser.set_defaults(handler=status)

    validate_parser = sub.add_parser("validate", help="验证 JSON 和核心配置")
    validate_parser.set_defaults(handler=validate)

    service_parser = sub.add_parser("service", help="控制 systemd 服务")
    service_parser.add_argument("action", choices=["enable", "disable", "start", "stop", "restart", "status"])
    service_parser.add_argument("kind", choices=["ss", "xray", "all"], default="all", nargs="?")
    service_parser.set_defaults(handler=service_operation)

    remove_parser = sub.add_parser("remove", help="删除配置/服务（需要 --yes）")
    remove_parser.add_argument("kind", choices=["ss", "xray", "all"], default="all", nargs="?")
    remove_parser.add_argument("--tag")
    remove_parser.add_argument("--yes", action="store_true")
    remove_parser.set_defaults(handler=remove)

    firewall = sub.add_parser("firewall", help="显式修改 UFW/firewalld 规则")
    firewall_sub = firewall.add_subparsers(dest="action", required=True)
    for action in ("open", "close"):
        fw = firewall_sub.add_parser(action)
        fw.add_argument("--port", type=int, required=True)
        fw.add_argument("--protocol", choices=["tcp", "udp", "both"], default="both")
        fw.set_defaults(handler=firewall_open if action == "open" else firewall_close)

    menu_parser = sub.add_parser("menu", help="交互式菜单")
    menu_parser.set_defaults(handler=menu)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        args.handler(args)
        return 0
    except UserError as exc:
        print(f"[错误] {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\n已取消。", file=sys.stderr)
        return 130
    except subprocess.CalledProcessError as exc:
        print(f"[错误] 命令失败（退出码 {exc.returncode}）：{exc.cmd}", file=sys.stderr)
        return exc.returncode or 1


if __name__ == "__main__":
    raise SystemExit(main())
