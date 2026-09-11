# Alpine / OpenRC

预编译的 `ss-2022-own-linux-amd64-musl.tar.gz` 使用 musl 静态 SS 核心和 `CGO_ENABLED=0` 的静态 Xray，不需要 `gcompat`、glibc、Go 或 Rust。

## 一键入口

```sh
apk add --no-cache bash git python3 curl coreutils libcap
curl --fail --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/charmingyi/ss-2022-own/main/bootstrap.sh \
  | SSOWN_REF=<已审计提交号> bash
```

入口检测 `/etc/os-release` 的 `ID=alpine` 后选择 musl Release，并校验整个归档、内部 manifest 和两个核心的 SHA-256。当前 musl 归档 SHA-256 为 `20dc8536307cb5e825e50f279807d1820876960707a73db8ca29decdf4ee8ca8`。默认不执行 `apk add`，避免未经确认改变系统；上面的依赖命令由管理员显式执行。

## OpenRC 管理

安装器会安全地创建全局 `menu`/`ss-2022` 入口；管理器在检测到 `rc-service`、`rc-update` 和 `/sbin/openrc-run` 时生成：

```text
/etc/init.d/ss-2022-own-ss
/etc/init.d/ss-2022-own-xray
```

服务以 `ssown:ssown` 前台运行，使用 OpenRC `supervise-daemon` 和有限重启策略，并通过 `rc-update add ... default` 设置开机启动：

```sh
rc-service ss-2022-own-ss status
rc-service ss-2022-own-xray restart
rc-update show -v
```

1024 以下端口仍需要最小化的 `CAP_NET_BIND_SERVICE` 能力；OpenRC 模板不会把服务改成 root。若系统没有可用 init 管理器，脚本只写配置并给出提示，不会偷偷安装守护进程。

Alpine 的 BusyBox 用户创建使用 `addgroup -S` 与 `adduser -S -D -H -G`，不依赖 Debian 的 `useradd --system` 参数。日志通过 `logread` 查看；systemd 主机则继续使用 `journalctl`。
