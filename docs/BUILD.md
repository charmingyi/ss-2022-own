# 可复现构建与 glibc 兼容性

## 固定输入

`build-core.sh` 不读取 latest API，也不执行上游构建脚本。当前输入为：

默认 Release 同时包含 amd64/glibc 与 amd64/musl；Alpine 应使用 musl 归档，Debian/Ubuntu 可使用 glibc 归档。

```text
shadowsocks-rust v1.24.0
  commit: 7ee1aa9223ed8f4d34734aac919036c8ad4502c2
  archive: a89865d1c5203de1b732017dd032e85f943d1592e8d3152eb7d2c4f3fca387bf

Xray-core v25.9.11
  commit: 3edfb0e33557330ac721862adb2e4be89ee7412a
  archive: 9bccd2681183698bf860b1af5407f97b4b60090324aa3ef1546e446612d44e1f
```

两个提交均可在 GitHub API 中看到已验证的 release commit。Xray v25.9.11 的 release 说明包含 VLESS Post-Quantum Encryption；其 `go.mod` 要求 Go 1.25。

注意：上游 shadowsocks-rust 仍调用 `build-time` 0.1.3，而该 proc-macro 实际使用 `Utc::now()`。因此本项目用 [`patches/shadowsocks-rust-build-time.patch`](../patches/shadowsocks-rust-build-time.patch) 把构建时间改为明确的 `SSOWN_BUILD_TIME`，并在 manifest 记录补丁 SHA-256；仅设置 `SOURCE_DATE_EPOCH` 不足以保证复现。

## 受控构建机

推荐使用 Debian 12/bookworm 构建 glibc 变体。至少准备：

```bash
apt-get install --no-install-recommends \
  build-essential binutils ca-certificates curl file jq patch \
  musl-tools pkg-config tar xz-utils
```

Rust 和 Go 应从组织批准的版本源安装，不要在 root shell 中直接执行未知安装脚本。最低版本：

- Rust 1.88.0（shadowsocks-rust v1.24.0 MSRV）
- Go 1.25.0（Xray v25.9.11 `go 1.25`）

musl 构建还需要对应 Rust target：

```bash
rustup target add x86_64-unknown-linux-musl
# ARM64 交叉构建还需要组织批准的 aarch64-linux-musl-gcc
rustup target add aarch64-unknown-linux-musl
```

若不具备目标 linker，脚本会中止，不会回退到系统 `cc`。

## 默认静态构建

```bash
./build-core.sh --core all --arch native --libc musl
```

Shadowsocks 使用：

```bash
cargo build --locked --release \
  --no-default-features \
  --features 'server,logging,multi-threaded,aead-cipher,aead-cipher-2022' \
  --bin ssserver --target x86_64-unknown-linux-musl
```

Xray 使用 `CGO_ENABLED=0`、`-trimpath`、`-buildvcs=false`、空 Go build ID 和固定的构建标识。依赖由 `Cargo.lock` / `go.sum` 锁定并由 Cargo/Go 校验；`--offline` 可强制只读本地缓存：

```bash
./build-core.sh --core all --arch amd64 --libc musl --offline
```

脚本对 musl 目标显式传入 `-static`、`crt-static`、`relocation-model=static` 和固定 linker；成功后还会运行 `--version`，并以 `readelf -lW` 无 `PT_INTERP`、`readelf -dW` 无 `DT_NEEDED` 为准，而不是只看 `file` 输出。成功后 `dist/manifest-*.json` 会记录源码、目标、工具链和产物 SHA-256。

## glibc 2.36 变体

如果必须产出动态 glibc 版本：

```bash
# 建议在 Debian 12/bookworm 中执行
./build-core.sh --core ss --arch amd64 --libc glibc
```

脚本要求 `x86_64-linux-gnu-gcc`/`aarch64-linux-gnu-gcc`（取决于目标），并检查 ELF interpreter。对 amd64 产物再执行：

```bash
readelf -l dist/ssserver-amd64-glibc | grep 'INTERP'
objdump -T dist/ssserver-amd64-glibc \
  | grep -oE 'GLIBC_[0-9]+\\.[0-9]+' \
  | sort -Vu
```

最高出现的 `GLIBC_2.x` 不得超过 `GLIBC_2.36`。Xray 即使在该模式下仍以 `CGO_ENABLED=0` 构建，因而是静态的。若构建机不是 glibc 2.36，不要声称兼容；换到 Debian 12 或使用默认 musl 产物。

## 复现检查

在同一受控环境中使用相同工具链运行两次：

```bash
rm -rf .build dist
SOURCE_DATE_EPOCH=1765409939 ./build-core.sh --core ss --arch amd64 --libc musl
sha256sum dist/ssserver-amd64-musl
cp dist/ssserver-amd64-musl /tmp/ssserver.first
rm -rf .build dist
SOURCE_DATE_EPOCH=1765409939 ./build-core.sh --core ss --arch amd64 --libc musl
sha256sum dist/ssserver-amd64-musl
cmp /tmp/ssserver.first dist/ssserver-amd64-musl
```

若工具链或依赖缓存发生变化，先检查 manifest，不要静默覆盖发布产物。构建过程只产生 `ssserver` 和 `xray`，不会安装 systemd、修改防火墙或写入 `/etc`。

## 部署与运行时检查

```bash
sudo ./ssctl.sh deploy \
  --ss dist/ssserver-amd64-musl \
  --xray dist/xray-amd64-static
sudo ./ssctl.sh validate
```

检查静态性：

```bash
file dist/ssserver-amd64-musl dist/xray-amd64-static
readelf -l dist/ssserver-amd64-musl | grep INTERP || true
readelf -l dist/xray-amd64-static | grep INTERP || true
```

然后用固定核心测试 Xray 配置：

```bash
/usr/local/libexec/ss-2022-own/xray run -test \
  -c /etc/ss-2022-own/xray.json
```

`run -test` 只验证配置装载，不代表 REALITY 目标站点、客户端 GUI 或公网防火墙一定连通；仍需在隔离测试节点做端到端检查。
