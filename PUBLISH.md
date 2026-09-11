# 公开发布与维护清单

当前公开仓库：<https://github.com/charmingyi/ss-2022-own>。

首次公开推送已完成；后续发布请继续遵循：

1. 不覆盖上游 `jinqians/ss-2022.sh`，每次发布使用新的、可审计的提交/tag。
2. 推送前运行 `make test`、`git diff --check`、`jq --version` 和 `bash -n *.sh`。
3. 确认 `.gitignore` 没有失效，尤其不能提交 `dist/`、`.build/`、状态文件、客户端配置和任何私钥/密码。
4. 公开仓库只包含管理层源码、构建脚本、README、NOTICE、SECURITY、补丁和测试；不要把服务器实例配置放进仓库。
5. 一键入口应固定到已审计的完整提交号，而不是长期依赖 `main`。
6. 在受控构建机生成每个架构的二进制、manifest、SBOM 和签名；发布页只上传经过审计的产物。当前 `v0.1.0` 提供 [amd64/glibc 与 amd64/musl 预编译归档](https://github.com/charmingyi/ss-2022-own/releases/tag/v0.1.0)，SHA-256 分别为 `6ee27771389b8bafc31329671ff0bd705fb47fd0cce33930ca211a077a9f5d21`、`20dc8536307cb5e825e50f279807d1820876960707a73db8ca29decdf4ee8ca8`。
7. 用干净的 Debian 12 和 Alpine/musl 环境做 smoke test，再公开 release 下载地址；更新 `bootstrap.sh` 中的 Release 哈希后才切换默认版本。

## 登录/推送安全

推送时的 GitHub 密码、个人访问令牌和设备验证码不应写入聊天记录、脚本、shell history 或仓库。设备流登录应由维护者本人在 <https://github.com/login/device> 输入验证码；推荐使用短期细粒度 token 或 SSH key，并在发布后撤销临时凭据。

本项目不包含自动读取验证码或绕过 GitHub 二次验证的代码。公开仓库的后续 release、权限变更和组织设置仍应由维护者在 GitHub UI 审核确认。
