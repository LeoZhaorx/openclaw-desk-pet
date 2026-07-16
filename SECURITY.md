# Security Policy

## Supported versions

安全修复只针对默认分支的最新版本。

## Reporting a vulnerability

请优先使用 GitHub 仓库的 Private vulnerability reporting 功能私下报告。报告中请包含受影响版本、复现条件、影响和建议修复；不要附带真实 Token、会话内容或其他个人数据。

如果仓库尚未启用 Private vulnerability reporting，请联系仓库维护者，并在建立私密沟通渠道前仅说明问题类别，不要公开利用细节。

## Security assumptions

- 本地配置面板只支持回环地址，不支持 LAN 或公网部署。
- `desk-sprite/.desk-sprite.env` 可能包含 Gateway Token，必须保持未跟踪且权限为 `0600`。
- 自定义 `OPENCLAW_START_SCRIPT` 等同于本机代码执行授权，只应指向用户信任的文件。
