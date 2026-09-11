# 上游脚本审计摘要

审计对象：[`jinqians/ss-2022.sh`](https://github.com/jinqians/ss-2022.sh) 当前 main 快照及其树内脚本。审计只评估供应链和系统副作用，不把“未发现明显后门”误认为“可安全 root 执行”。

## 高风险证据

- `menu.sh` 以 root 直接 `bash <(curl ...)` 执行 Snell、SS-Rust、ShadowTLS 和 PSM；分支/域名没有 commit、签名或哈希固定。
- `ss-2022.sh` 通过 latest API 取版本，使用 `wget --no-check-certificate` 下载二进制；更新脚本、ShadowTLS、IP 屏蔽脚本也没有完整性校验。
- ShadowTLS 和 SS 更新使用可预测 `/tmp` 文件、相对当前目录脚本和 root 安装路径；存在 symlink/race 与当前目录投毒面。
- 配置/服务以默认权限保存密码，服务使用 root；ShadowTLS 后端没有保证 SS 只监听 loopback。
- block-mainland 更新先删旧规则再下载/解析，新数据失败会 fail-open；规则主要覆盖 IPv4，并可能删除同名/通用防火墙规则。
- root pip 安装未锁版本的 `maxminddb`，并使用 `--break-system-packages`。
- 菜单初始即安装依赖、写全局命令；更新和卸载路径缺少可靠 ownership marker 和二次确认。

完整脚本快照、提交验证状态和行号应在发布前由维护者留档。仓库近期提交的 GitHub API verification 不能替代对脚本内容的审计。

## 重写决策

本项目移除上述远程聚合入口、Snell/PSM/大陆 IP 规则、ShadowTLS 自动安装、自更新、第三方 IP 查询和隐式包管理。核心只从 `build-core.sh` 中列出的不可变版本快照构建；管理层不执行远端脚本。防火墙只在用户显式调用时处理 UFW/firewalld，卸载必须 `--yes`，配置使用原子写入和专用系统用户。

## 发布前复核

1. 对本仓库运行 `make test` 与 `git diff --check`。
2. 在干净环境检查源码归档 SHA-256、patch SHA-256、Cargo.lock/go.sum、工具链和二进制 manifest。
3. 运行 `ssctl.sh validate` 与固定 Xray 的 `run -test`。
4. 确认公开仓库没有 `state.json`、客户端 JSON、私钥、密码、完整分享链接或 `dist/`。
