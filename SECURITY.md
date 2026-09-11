# 安全说明

请不要把以下内容提交到公开仓库或发到聊天工具：

- `/etc/ss-2022-own/state.json`
- `/etc/ss-2022-own/ss.json`、`xray.json`
- `/etc/ss-2022-own/clients/*.json`
- 任何 `private_key`、ML-KEM Seed、Shadowsocks 密码或完整分享链接

发现管理层代码的安全问题时，请先通过私下渠道联系维护者，并提供复现步骤、受影响版本和最小化日志。不要在 issue 中公开节点地址、密钥或可直接利用的生产配置。

核心供应链问题应同时记录：上游提交、归档 SHA-256、工具链版本、构建参数和二进制哈希。发现构建输入变化时，停止发布，不要用 `latest` 覆盖既有产物。
