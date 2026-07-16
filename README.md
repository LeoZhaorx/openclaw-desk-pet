# OpenClaw Desk Pet

一个运行在 macOS 桌面的 OpenClaw 状态精灵。它会把 OpenClaw 的思考、工具调用、完成和休眠状态映射成带透明通道的猫咪动画，并提供快捷任务、文字输入、服务控制和本地配置面板。

![OpenClaw Desk Pet](desk-sprite/console/visuals/art-work.png)

## 功能

- 常驻所有桌面空间的透明悬浮窗口，可拖动并记住位置。
- 根据 OpenClaw Gateway 事件切换待机、思考、开工、工具调用、完成、浅睡和深睡动画。
- Gateway 不可用时，回退读取 OpenClaw 主会话索引与 JSONL 会话记录。
- 展示执行摘要、工具标签和分段后的最终回复。
- 支持快捷任务轮播、滚轮选择和直接文字输入。
- 支持通过 Gateway、OpenClaw CLI 或已打开的本地控制台发送消息。
- 提供仅绑定 `127.0.0.1` 的本地配置面板。

## 系统要求

- macOS 13 或更高版本。
- Swift 5.9 或更高版本（Xcode Command Line Tools 即可）。
- Python 3.9 或更高版本。
- 已安装并配置 [OpenClaw](https://docs.openclaw.ai/)。

本项目当前验证环境：macOS 15.7.4、Swift 6.2.4、Python 3.9.6、OpenClaw 2026.6.11。

## 快速开始

```bash
git clone <your-repository-url>
cd openclaw-desk-pet
cp desk-sprite/.desk-sprite.env.example desk-sprite/.desk-sprite.env
chmod 600 desk-sprite/.desk-sprite.env
```

编辑 `desk-sprite/.desk-sprite.env`，至少确认 `OPENCLAW_ROOT` 指向你的 OpenClaw 状态目录。默认值是 `$HOME/.openclaw`。

启动：

```bash
./启动桌面精灵.command
```

配置面板默认位于 [http://127.0.0.1:17890/](http://127.0.0.1:17890/)。修改配置后点击“重新载入”。

停止或重启：

```bash
./停止桌面精灵.command
./重启桌面精灵.command
```

也可以直接在 `desk-sprite/` 目录使用 `./launch.sh`、`./halt.sh` 和 `./health.sh`。

## 配置

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `OPENCLAW_ROOT` | `$HOME/.openclaw` | OpenClaw 状态、配置与会话目录 |
| `OPENCLAW_GATEWAY_URL` | `ws://127.0.0.1:18789` | Gateway WebSocket 地址 |
| `OPENCLAW_GATEWAY_TOKEN` | 自动发现 | 可选 Gateway Token；不要提交到 Git |
| `OPENCLAW_ACTIVE_WINDOW_SECONDS` | `20` | 文件回退模式的活跃窗口 |
| `OPENCLAW_START_SCRIPT` | 空 | 可选的绝对启动脚本路径；为空时运行 `openclaw gateway start` |
| `DESK_SPRITE_CONSOLE_PORT` | `17890` | 本地配置面板端口 |
| `DESK_SPRITE_ASSETS` | 仓库 `media/` | 动画素材目录 |

Token 的发现顺序为：显式环境变量、OpenClaw 配置中的 Gateway Token、OpenClaw `.env` 文件。所有本机配置均应只保存在被 Git 忽略的 `desk-sprite/.desk-sprite.env` 中。

## 项目结构

```text
.
├── desk-sprite/
│   ├── Package.swift                 # SwiftPM 可执行程序
│   ├── Sources/DeskSprite/main.swift # 状态监控、UI 与动画状态机
│   ├── console_server.py             # 仅回环地址可访问的配置服务
│   ├── console/index.html            # 配置面板
│   └── tests/                        # Python 安全回归测试
├── media/                            # 运行时透明 ProRes 动画
├── scripts/check_release.py          # 发布前泄密与文件限制检查
└── 启动/停止/重启桌面精灵.command
```

更详细的数据流和状态机见 [架构说明](docs/ARCHITECTURE.md)。

## 开发与验证

```bash
swift build --package-path desk-sprite
python3 -m unittest discover -s desk-sprite/tests -v
python3 -m py_compile desk-sprite/console_server.py scripts/check_release.py
bash -n desk-sprite/*.sh
```

初始化 Git 并暂存文件后，可执行发布自检：

```bash
python3 scripts/check_release.py
```

`media/` 当前约 378MB，单文件均小于 GitHub 100MiB 硬限制；`idle-core.mov` 超过 50MiB，会触发 GitHub 的大文件提示。若以后频繁修改动画，建议迁移到 Git LFS 或 GitHub Releases，避免 Git 历史持续膨胀。

## 隐私与安全

- 配置面板只监听 `127.0.0.1`，并校验 Host 与 Origin；不要改成局域网监听。
- `.desk-sprite.env`、日志、PID、构建缓存、压缩包和原尺寸素材副本均已在 `.gitignore` 中排除。
- 应用会读取 OpenClaw 会话记录，并请求 Gateway 的 operator 权限以观察事件和发送任务。
- 为把任务同步到已打开的 OpenClaw 网页，应用可能请求 Chrome/Safari 的 AppleScript 自动化权限。
- 发现安全问题时请按 [安全政策](SECURITY.md) 私下报告，不要公开提交包含利用细节的 Issue。

安全审计记录见 [docs/SECURITY_AUDIT.md](docs/SECURITY_AUDIT.md)。

## 许可证

本仓库的源码和随仓库发布的视觉素材采用 [MIT License](LICENSE)。提交视觉素材前，请确认你有权将其按该许可证再分发。

OpenClaw 是独立项目。本仓库是社区集成项目，不代表 OpenClaw 官方背书。
