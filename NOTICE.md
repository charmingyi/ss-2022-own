# NOTICE

`ss-2022-own` 管理层代码按本仓库 `LICENSE` 发布。

`build-core.sh` 在构建时获取以下独立上游源码；本仓库不重新分发这些源码，也不把它们改名为自有代码：

- [shadowsocks-rust v1.24.0](https://github.com/shadowsocks/shadowsocks-rust), MIT License。
- [Xray-core v25.9.11](https://github.com/XTLS/Xray-core), Mozilla Public License 2.0。

构建输出还包含各自 Cargo/Go 依赖，依赖许可证及版权信息由其上游清单决定。公开发布构建产物时应同时发布 `manifest-*.json`、上游许可证清单和依赖 SBOM；服务端私钥、密码、状态文件和客户端配置不属于发布内容。
