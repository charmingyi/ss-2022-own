# ss-2022-own

一个**本地可审计**的 Shadowsocks 2022 / VLESS Reality / VLESS Encryption 管理器。
本项目不是把上游脚本换个名字，而是重新实现管理层，并从固定版本源码构建核心。

> 公开仓库地址：<https://github.com/charmingyi/ss-2022-own>。默认一键入口指向该仓库；生产环境仍建议固定到完整提交号。

## 为什么重写

对 [`jinqians/ss-2022.sh`](https://github.com/jinqians/ss-2022.sh) 的审计发现：菜单以 root 直接执行可变的 `bash <(curl ...)`，核心/ShadowTLS 使用动态 latest 下载且没有哈希或签名校验，并存在 `--no-check-certificate`、可预测临时文件、root 服务、明文凭据、宽泛防火墙删除等问题。

本项目明确不保留这些行为：

- 不执行 `curl | bash`、`bash <(curl ...)`，不提供自更新菜单。
- 不查询第三方 IP 服务，不强制修改时区/NTP，不自动安装 Python/PIP 包。
- 不接入 Snell、PSM、ShadowTLS、IP 地理库等未经本项目审计的远程脚本。
- 下载源码时使用固定 tag 快照和 SHA-256；归档成员会检查路径穿越和链接。
- 默认不改防火墙；只有显式执行 `firewall open` 或传入 `--open-firewall` 才会调用 UFW/firewalld。
- systemd 使用专用 `ssown` 用户、最小 bind 能力、`ProtectSystem=strict`、`NoNewPrivileges` 等限制。
- 凭据写入 root-only 状态文件和 `0640` 服务配置；`show` 默认隐藏密码/私钥。

## 核心版本与兼容性

`build-core.sh` 当前固定：

| 组件 | 版本 | 固定提交 | 用途 |
| --- | --- | --- | --- |
| shadowsocks-rust | v1.24.0 | `7ee1aa9223ed8f4d34734aac919036c8ad4502c2` | SS 2022 AEAD |
| Xray-core | v25.9.11 | `3edfb0e33557330ac721862adb2e4be89ee7412a` | VLESS Reality / VLESS Encryption |

Xray v25.9.11 已包含 [VLESS Encryption PR #5067](https://github.com/XTLS/Xray-core/pull/5067)。配置基线以该 tag 的解析器为准：`network: "tcp"`、`tcpSettings`、VLESS inbound 使用 `settings.clients`，而不是直接套用较新文档中的字段名。

默认构建目标是：

- Shadowsocks：Linux musl 静态目标（`x86_64-unknown-linux-musl` 或 `aarch64-unknown-linux-musl`）。
- Xray：`CGO_ENABLED=0` 的静态 Go 二进制。

因此默认产物不依赖运行环境的 glibc，强于“最低 glibc 2.36”。若选择 `--libc glibc`，应在 Debian 12/bookworm（glibc 2.36）构建，并由 `readelf`/`objdump` 检查最高 `GLIBC_2.x` 符号不得超过 2.36。Alpine 使用 musl 静态 Release 和 OpenRC 服务模板，详见 [`docs/BUILD.md`](docs/BUILD.md) 与 [`docs/ALPINE.md`](docs/ALPINE.md)。

## 预编译一键安装

当前公开 Release 提供 Linux amd64/glibc 与 amd64/musl 预编译核心，安装服务器不需要 Go、Rust 或 Git：Debian/Ubuntu 选择 glibc，Alpine 会自动选择 musl。只需 Bash、curl、Python3 和 sha256sum。

```bash
curl --fail --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/charmingyi/ss-2022-own/main/bootstrap.sh \
  | SSOWN_REF=main bash
```

入口会固定下载 Release `v0.1.0`，校验归档 SHA-256、归档内部 manifest 和核心哈希后才部署。glibc 归档 SHA-256 为 `6ee27771389b8bafc31329671ff0bd705fb47fd0cce33930ca211a077a9f5d21`，musl 归档 SHA-256 为 `20dc8536307cb5e825e50f279807d1820876960707a73db8ca29decdf4ee8ca8`。生产环境请将 `main` 换成已审计的完整提交号；当前 Release 暂未提供 ARM64 预编译包。

## 构建核心（备用）

只有在需要自行复核源码或目标架构暂无 Release 时才使用 `--build`。需要本地准备 Rust 1.88+、对应 linker/Rust target，以及 Go 1.25+；脚本不会偷偷安装工具链：

```bash
cd ss-2022-own
./build-core.sh --core all --arch native --libc musl
```

构建产物和清单写入 `dist/`：

```text
dist/ssserver-amd64-musl
dist/xray-amd64-static
dist/manifest-amd64-musl.json
```

部署自己构建的产物：

```bash
sudo ./ssctl.sh deploy \
  --ss dist/ssserver-amd64-musl \
  --xray dist/xray-amd64-static
```

`manifest-*.json` 记录固定源码哈希、提交、目标架构、工具链、可复现性补丁和二进制 SHA-256。上游 `build-time` 0.1.3 实际取 `Utc::now()`，所以 [`patches/shadowsocks-rust-build-time.patch`](patches/shadowsocks-rust-build-time.patch) 是构建输入的一部分；不要把 `dist/` 产物或服务端状态文件提交到公开仓库。

构建出 amd64/glibc 或 amd64/musl 产物后，可用 [`package-release.sh`](package-release.sh) 生成带固定时间、owner、顺序和内部 SHA256SUMS 的 Release 归档：

```bash
./package-release.sh
```

## 安装节点

先部署核心，再创建节点。服务器地址只用于生成客户端配置/分享信息，不会被脚本自动发到第三方服务。

### Shadowsocks 2022

```bash
sudo ./ssctl.sh install ss \
  --port 8388 \
  --method 2022-blake3-aes-256-gcm \
  --server-address example.com \
  --open-firewall
```

脚本会随机生成符合 AEAD-2022 密钥长度要求的标准 Base64 密码。当前自有构建只启用以下四种 AEAD-2022 方法：

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`
- `2022-blake3-chacha8-poly1305`

### VLESS + REALITY + XTLS Vision

```bash
sudo ./ssctl.sh install reality \
  --port 443 \
  --server-address example.com \
  --target www.example.com:443 \
  --server-name www.example.com \
  --open-firewall
```

REALITY 私钥/公钥由固定版本 Xray 的 `xray x25519` 生成。服务端只保存私钥；客户端 JSON 和分享信息只包含公钥、UUID、short ID 等客户端参数。

`--target` 是未通过 REALITY 验证的连接会被转发到的目标，必须谨慎选择。目标站点位于 CDN 后时，本机可能被扫描者滥用成转发器；不要把未知 SNI 当作可信流量。

### VLESS Encryption

```bash
sudo ./ssctl.sh install encryption \
  --port 8443 \
  --server-address example.com \
  --appearance native \
  --ticket-ttl 600s \
  --open-firewall
```

脚本写入服务端：

```text
mlkem768x25519plus.native.600s.<X25519 private key>
```

并生成客户端：

```text
mlkem768x25519plus.native.0rtt.<X25519 public key>
```

也可选择 `xorpub` 或 `random` 外观。`random` 不是 HTTPS 外观；VLESS Encryption 的 `security: none` 只提供协议层加密，不等同于 REALITY/TLS，不应把它宣传成直接的 HTTPS 伪装。普通公网入口优先使用 REALITY。

默认使用 X25519 认证；若要使用 ML-KEM-768 Seed/Client，可显式指定 `--auth mlkem768`，脚本会调用固定核心的 `xray mlkem768`，也可在受控环境中用 `--private-key/--public-key` 提供相匹配的值。不要混用两套 `xray vlessenc` 输出；Seed/Client 长度分别是 64/1184 字节的无填充 base64url。

## 查看、验证、控制

```bash
# 默认隐藏秘密
sudo ./ssctl.sh show

# 只在受控终端显示分享链接/密码
sudo ./ssctl.sh show --reveal --server-address example.com

sudo ./ssctl.sh validate
sudo ./ssctl.sh status
sudo ./ssctl.sh service restart all

# 删除必须显式确认；按 tag 删除单个 Xray inbound
sudo ./ssctl.sh remove --tag vless-reality --yes
sudo ./ssctl.sh remove xray --yes
```

客户端 JSON 保存在 `/etc/ss-2022-own/clients/`，权限为 `0600`。分享 URI 中的 UUID、公钥/Client 也按节点凭据处理；服务端 `private_key`、`decryption` 绝不能上传或放进链接。

## 交互菜单与管理

直接运行 `sudo /usr/local/share/ss-2022-own/menu.sh`（安装器也会安全地创建全局 `menu`/`ss-2022` 命令）即可进入彩色管理菜单；`ss-2022.sh` 是兼容上游单协议入口，外壳参考上游菜单但只调用本项目后端：

- 三种协议安装/覆盖：SS 2022、VLESS Reality、VLESS Encryption。
- 节点查看、凭据隐藏/确认显示、按 tag 删除、配置验证。
- SS/Xray 服务启停、重启、状态和日志；Debian 使用 systemd，Alpine 使用 OpenRC。
- 核心版本/Release 信息、本地产物部署，以及显式 UFW/firewalld 防火墙操作。
- 卸载操作必须输入 `DELETE`；分享信息必须输入 `SHOW`，避免误操作和凭据泄露。

## 一键入口

公开仓库保留与上游相同的 Bash 一键入口模式，默认安装预编译核心；生产环境建议把 `main` 替换成已审计的完整提交号：

```bash
bash <(curl --fail --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/charmingyi/ss-2022-own/main/menu.sh)
```

兼容上游 SS 单协议入口：

```bash
bash <(curl --fail --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/charmingyi/ss-2022-own/main/ss-2022.sh)
```

直接使用预编译安装器：

```bash
bash <(curl --fail --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/charmingyi/ss-2022-own/main/bootstrap.sh)
```

固定提交号的形式：

```bash
SSOWN_REF=<commit> bash <(curl --fail --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/charmingyi/ss-2022-own/<commit>/bootstrap.sh)
```

入口脚本只从指定仓库固定引用取菜单、管理脚本、构建脚本和固定补丁，不会把后续下载内容直接交给 shell。生产环境最好先下载脚本、核对提交/哈希后再执行；本项目不会强迫用户盲信一条 root 管道命令。

如果目标机器没有预构建 release 产物，先在受控构建机运行 `build-core.sh`，把产物通过你们自己的发布流程部署；不要在服务器上启用动态 latest 下载。

## 官方资料

- [Shadowsocks Rust](https://github.com/shadowsocks/shadowsocks-rust)
- [Xray-core](https://github.com/XTLS/Xray-core)
- [VLESS inbound](https://xtls.github.io/en/config/inbounds/vless.html)
- [VLESS outbound](https://xtls.github.io/en/config/outbounds/vless.html)
- [REALITY transport](https://xtls.github.io/en/config/transports/reality.html)
- [Xray transport compatibility](https://xtls.github.io/en/config/transport.html)
- [VLESS Encryption PR #5067](https://github.com/XTLS/Xray-core/pull/5067)

分享链接中 `pbk`、`sid`、`spx`、`fp` 是客户端生态常见映射，不是 Xray core JSON parser 的独立 URI schema；导入前应按目标客户端逐一验证。

## 许可证

管理层代码按 MIT 发布；核心源码和依赖仍遵循各自上游许可证。公开发布时请同时保留上游许可证、构建清单和本 README。
