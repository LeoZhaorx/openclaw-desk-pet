# 贡献指南

感谢参与 OpenClaw Desk Pet。

## 提交前

1. 不要提交 `.desk-sprite.env`、Token、日志、会话记录、本机绝对路径或个人快捷指令。
2. 运行 Swift 构建、Python 测试和发布自检。
3. 若修改动画，请保持现有文件名和透明通道，并说明编码、分辨率、帧率及来源授权。
4. 新配置项必须加入示例配置和 README；敏感值必须默认留空。

```bash
swift build --package-path desk-sprite
python3 -m unittest discover -s desk-sprite/tests -v
python3 scripts/check_release.py
```

## 代码风格

- Swift 代码维持现有 SwiftUI/AppKit 混合结构，跨线程更新 UI 时回到主线程。
- Python 仅使用标准库，除非新增依赖有明确收益并同时提供锁定方式。
- Shell 脚本使用 `set -euo pipefail`，不得 `source` 用户可编辑的配置文件。
- Web UI 对外部或用户文本使用 `textContent`/DOM API；不要把它们传给 `innerHTML`。

## Pull Request

请说明行为变化、验证命令、截图或录屏（若影响 UI），以及是否修改了配置格式、Gateway 协议或素材。
