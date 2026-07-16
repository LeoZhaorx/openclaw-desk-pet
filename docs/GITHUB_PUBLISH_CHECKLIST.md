# GitHub 发布清单

当前仓库已在本地初始化为 `main`，文件已暂存，但尚未创建提交、配置远端或上传任何内容。

## 发布前必须确认

- [ ] 确认采用 MIT License。
- [ ] 确认有权按 MIT 再分发 `media/` 和 `desk-sprite/console/visuals/` 中的所有视觉素材。
- [ ] 选择仓库名称；建议 `openclaw-desk-pet`。
- [ ] 选择提交身份，并优先使用 GitHub 提供的 `users.noreply.github.com` 邮箱，避免暴露私人邮箱。
- [ ] 决定是否在第一次提交前使用 Git LFS。当前普通 Git 内容约 381MB，所有单文件低于 100MiB，但一个动画超过 50MiB。

## 建议仓库资料

- Description: `A native macOS desktop pet that visualizes OpenClaw agent activity.`
- Topics: `openclaw`, `macos`, `swift`, `swiftui`, `desktop-pet`, `ai-agent`
- Visibility: Public
- 默认分支: `main`

创建 GitHub 仓库时不要让 GitHub 自动生成 README、`.gitignore` 或 License；本地已经包含这些文件。

## 提交与推送

把占位内容替换为你的 GitHub 信息：

```bash
git config user.name "YOUR_GITHUB_NAME"
git config user.email "YOUR_ID+YOUR_GITHUB_NAME@users.noreply.github.com"
python3 scripts/check_release.py
git commit -m "Initial open-source release"
git remote add origin git@github.com:YOUR_GITHUB_NAME/openclaw-desk-pet.git
git push -u origin main
```

如果选择 Git LFS，应在第一次提交前安装并执行：

```bash
git lfs install
git lfs track "media/*.mov"
git add .gitattributes media
python3 scripts/check_release.py
```

## GitHub 仓库设置

- [ ] 启用 Private vulnerability reporting。
- [ ] 启用 Secret scanning 和 Push protection（若账户/仓库支持）。
- [ ] 保护 `main`，要求 CI 通过后再合并。
- [ ] 检查 Actions 首次运行：Python 测试、Swift 构建、发布审计均应通过。
- [ ] 创建第一个 Release，并记录测试过的 macOS、Swift、Python 和 OpenClaw 版本。
