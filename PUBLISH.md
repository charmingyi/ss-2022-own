# 公开发布清单

这个目录在绑定远程仓库前应完成以下步骤：

1. 由维护者创建一个新的**公开 GitHub 仓库**，不要覆盖上游 `jinqians/ss-2022.sh`。
2. 先检查 `git diff --check`、`tests/test_manager.sh`、`python3 -m py_compile lib/ssctl.py`、`bash -n *.sh`。
3. 确认 `.gitignore` 没有忽略规则失效，尤其不能提交 `dist/`、`.build/`、状态文件、客户端配置和任何私钥/密码。
4. 推送管理层源码、构建脚本、README、NOTICE、SECURITY 和测试；不要把服务器实例配置放进仓库。
5. 推送后固定一个完整提交号，替换 `bootstrap.sh` 中的 `CHANGE_ME`，再用该提交号做一键入口示例。
6. 在受控构建机生成每个架构的二进制、manifest、SBOM 和签名；发布页只上传经过审计的产物。
7. 用干净的 Debian 12 和 Alpine/musl 环境做 smoke test，再公开 release 下载地址。

## 登录/推送

推送前需要维护者在 GitHub UI 完成登录、组织/仓库选择和二次验证。验证码、密码、个人访问令牌不要写入聊天记录、脚本、shell history 或仓库；在 GUI 的验证码输入框中由维护者本人提交即可。推荐使用短期细粒度 token 或 SSH key，并在发布后撤销临时凭据。

本项目不包含自动创建仓库、读取验证码或绕过 GitHub 二次验证的代码。获得仓库 URL 和已授权的 Git 操作环境后，再设置 `origin` 并推送。
