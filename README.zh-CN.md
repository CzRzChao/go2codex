[English](README.md) | 简体中文

<!-- readme-section: overview -->

# Go2Codex

只需点击一次 Finder 工具栏按钮，即可在 Codex 或 Claude 中打开当前文件夹。

Go2Codex 会向 Finder 工具栏添加一个按钮，把 Finder 最前方窗口实际显示的文件夹交给 Codex App、Codex CLI、Claude Desktop 或 Claude Code CLI。公开发布包只有一个顶层 `Go2Codex.app`；Finder 使用的 Launcher 内嵌在这个 App 中。

[下载最新稳定版](https://github.com/CzRzChao/go2codex/releases/tag/v0.1.1) · [全部版本](https://github.com/CzRzChao/go2codex/releases) · [安全策略](SECURITY.md)

> [!WARNING]
> 当前公开构建使用 ad-hoc 签名，没有 Developer ID 签名，也未经过 Apple 公证。通过浏览器下载的副本，首次启动时通常会被 Gatekeeper 阻止。GitHub Release 标记为 Stable 并不改变它的 Apple 签名状态。

<p align="center">
  <img src="docs/assets/settings-zh-CN.png" alt="Go2Codex 简体中文设置页面" width="640">
</p>

<!-- readme-section: quick-start -->

## 60 秒快速开始

1. 从[当前稳定版](https://github.com/CzRzChao/go2codex/releases/tag/v0.1.1)下载两个发布文件：
   - `Go2Codex-0.1.1-macos-arm64.zip`
   - `Go2Codex-0.1.1-macos-arm64.zip.sha256`
2. 在终端中进入这两个文件所在的下载目录并校验 ZIP：

   ```sh
   cd ~/Downloads
   shasum -a 256 -c Go2Codex-0.1.1-macos-arm64.zip.sha256
   ```

3. 双击 ZIP 解压，然后在打开 App 之前，把 `Go2Codex.app` 移到 `/Applications` 或 `~/Applications`。
4. 打开一次 Go2Codex。如果 macOS 阻止启动，请按照下面的 [Gatekeeper 步骤](#下载校验与-gatekeeper) 操作。
5. 选择默认目标、默认终端，以及 CLI 会话使用新标签页还是新窗口。如果没有安装 iTerm2，请选择 Terminal。
6. 点击**完成设置并安装到 Finder**。如果自动设置不可用，请点击**完成设置并显示手动安装步骤**，然后按照 Command 拖入说明操作。
7. 在 Finder 中打开一个普通文件夹，点击 Go2Codex 工具栏按钮。Shift 点击时，请持续按住 Shift，直到单次使用的目标选择器出现。

仅仅打开设置窗口不会触发“自动化”授权。第一次实际使用工具栏启动时会请求 Finder 自动化权限；第一次启动 CLI 时还会请求 Terminal 或 iTerm2 自动化权限。

<!-- readme-section: requirements -->

## 系统要求

- **Apple 芯片** Mac。目前不发布 Intel 或 Universal 构建。
- **macOS 14 Sonoma** 或更高版本。
- 已经安装至少一个受支持的编程 Agent：
  - 桌面目标需要 Codex App 或 Claude Desktop；和/或
  - CLI 目标需要 shell 中可以找到 `codex` 或 `claude`。
- CLI 目标需要 Terminal.app 或 iTerm2。iTerm2 交接要求账户登录 shell 是可执行的 **zsh**、**bash** 或 **fish**。

Go2Codex 不会安装或捆绑 Codex、Claude 或 iTerm2。使用预构建发布包不需要 Xcode，也不需要付费 Apple Developer 账号。

<!-- readme-section: download-and-gatekeeper -->

## 下载、校验与 Gatekeeper

### 下载并校验

请从[当前稳定版 GitHub Release](https://github.com/CzRzChao/go2codex/releases/tag/v0.1.1)下载 ZIP 和校验文件，并把它们放在同一个目录：

- `Go2Codex-0.1.1-macos-arm64.zip`
- `Go2Codex-0.1.1-macos-arm64.zip.sha256`

解压前先校验：

```sh
shasum -a 256 -c Go2Codex-0.1.1-macos-arm64.zip.sha256
```

只有命令输出 `OK` 并且你信任此仓库时才应继续。可选的预览版标签使用 `vX.Y.Z-preview.N` 格式；预览版用于提前测试，不会替代稳定版。

### 首次启动与 Gatekeeper

第一次启动前，请先把 App 移到 `/Applications` 或 `~/Applications`。直接从“下载”目录运行可能触发 App Translocation，Go2Codex 会有意拒绝从这个临时位置安装 Finder 工具栏按钮。

公开的稳定版和预览版使用 ad-hoc 签名，但**没有 Developer ID 签名，也未经过 Apple 公证**。带有浏览器下载隔离标记的副本可能显示“Apple 无法验证”，或者建议把 App 移到废纸篓。

第一次启动被阻止后：

1. 打开**系统设置** → **隐私与安全性**。
2. 滚动到**安全性**，为 Go2Codex 选择**仍要打开**。
3. 完成身份验证并确认**打开**。

不要仅仅为了绕过这一步而删除隔离属性。由组织管理的 Mac 可能不允许“仍要打开”。应用的安全边界见 [SECURITY.md](SECURITY.md)。

<!-- readme-section: finder-toolbar -->

## 安装 Finder 工具栏按钮

公开发布包只有一个可搜索的 `Go2Codex.app`。工具栏 Launcher 位于 `Go2Codex.app/Contents/Helpers`，不需要再安装第二个顶层 App。

### 自动设置

1. 把 `Go2Codex.app` 放到 `/Applications` 或 `~/Applications`。
2. 完成首次启动时显示的设置。
3. 点击**完成设置并安装到 Finder**；如果已经完成首次设置，则点击**安装到 Finder**。
4. 阅读警告并确认**安装并重启 Finder**。Finder 会短暂重启。

自动安装、修复和移除属于实验性功能。它们会保留无关的工具栏项目，在修改当前用户的 Finder 私有工具栏偏好之前写入恢复日志，重启 Finder，并校验最终结果。

当前稳定版仅在以下精确环境中启用自动修改：

- macOS build `23G80`，Finder `14.6 (1632.6.3)`
- macOS build `25F84`，Finder `26.4 (1828.5.2)`

不同的 macOS/Finder 补丁版本、未知的工具栏结构或未通过安全检查时，通常会回退到手动设置。这种回退不表示 App 本身安装失败。

### 手动设置

1. 点击**显示手动安装步骤**，再点击**在 Finder 中显示**。
2. 如果工具栏中已经有旧的 Go2Codex 按钮，请按住 Command (⌘) 并把它拖出工具栏。
3. Finder 显示当前内嵌 Launcher 后，按住 Command (⌘)，把 Go2Codex 拖入工具栏。

Finder 没有用于这个私有工具栏偏好的公开原子 API。确认步骤和恢复日志可以降低风险，但无法消除另一个进程恰好同时修改工具栏时极小的竞态。如果不接受这个限制，请使用手动 Command 拖入方式。

<!-- readme-section: targets-and-terminal -->

## 目标与终端配置

| Agent 目标 | 启动方式 | 终端 |
| --- | --- | --- |
| Codex App | 打开 `codex:` deep link，并验证已注册处理程序的 bundle identifier 是 `com.openai.codex` | — |
| Codex CLI | 运行 `cd <folder> && codex` | Terminal.app / iTerm2 |
| Claude Desktop Code | 打开 `claude:` deep link，并验证已注册处理程序的 bundle identifier 是 `com.anthropic.claudefordesktop` | — |
| Claude Code CLI | 运行 `cd <folder> && claude` | Terminal.app / iTerm2 |

设置页会通过精确 bundle identifier 检查桌面 URL handler，并标记不可用的目标。如果没有安装 iTerm2，设置页会把它标记为不可用，并且不允许选中；改选 Terminal 即可继续。桌面目标不会使用“默认终端”设置，但首次设置仍要求选择一个终端，以便之后通过 Shift 点击启动 CLI 目标。

### CLI 状态

设置页会在一个后台账户登录 shell 进程中同时检测 `codex` 和 `claude`。这个过程不会打开终端窗口，但短暂检测期间可能会运行 zsh、bash 或 fish 的启动文件。

| 状态 | 含义 |
| --- | --- |
| **可用** | 后台登录 shell 找到了可执行命令。 |
| **未找到** | 这个 shell 没有找到命令。安装 CLI 或调整 `PATH` 后，点击**刷新 CLI 状态**。 |
| **无法验证** | shell 不受支持、检测超时、启动失败或结果无法确定；这不代表 CLI 没有安装。 |

这三种状态都只供参考。由于真实的 Terminal 或 iTerm profile 可能有不同的 shell 配置，它们不会阻止保存或启动。必要时，请在准备使用的终端中验证：

```sh
command -v codex
command -v claude
```

### 新标签页或新窗口

- **新标签页**会请求所选终端创建一个新标签页。如果没有合适的窗口，Terminal 可能原生回退为新建窗口。
- **新窗口**会请求创建一个独立窗口。
- Terminal.app 和 iTerm2 中的 Codex CLI、Claude Code CLI 都支持这两种方式。

Go2Codex 进入工作目录后，只会提交固定的 `codex` 或 `claude` 命令。如果无法唯一确认新会话，Terminal 交接会安全失败：不会猜测目标，也不会自动重试，因此可能留下空标签页或空窗口。iTerm2 会把登录 shell 和 CLI 命令作为会话初始命令；结果无法确定时也不会自动重试。

<!-- readme-section: usage -->

## 使用方式

- **点击** Finder 工具栏按钮：使用默认目标快速启动。
- **Shift 点击**：打开目标选择器。请持续按住 Shift，直到选择器出现。也可以在设置中禁用备用触发方式。

**工作目录**始终是 Finder 最前方窗口实际显示的文件夹。Go2Codex 不会使用 Finder 当前选中的项目、推断 Git 根目录，也不会在无法解析位置时替换成其他目录。如果 Finder 实际显示的是 Home 或 Desktop 文件夹，它们可以正常使用；“最近使用”等虚拟位置则不行。

<!-- readme-section: update-and-uninstall -->

## 更新与完整卸载

### 更新

1. 下载并校验新版 ZIP 和校验文件。
2. 退出 Go2Codex，替换 `/Applications` 或 `~/Applications` 中已有的 App。
3. 打开新版，并完成可能再次出现的 Gatekeeper 提示。
4. 检查设置中的 **Finder 工具栏**状态：
   - 如果显示**在 Finder 中修复**，请执行修复；或者
   - 如果之前是手动安装，请按住 Command 把旧按钮拖出，再添加当前内嵌 Launcher。
5. 实际启动一次你会使用的目标。如果 macOS 再次请求 Finder、Terminal 或 iTerm2 自动化权限，请在这时检查并授权。

由于公开构建使用 ad-hoc 签名，更新后 macOS 可能会再次请求 Finder、Terminal 或 iTerm2 自动化权限。

### 完整卸载

1. 删除 App 前，先移除工具栏按钮：
   - 自动移除可用时，点击**从 Finder 卸载**；或者
   - 点击**显示手动移除步骤**，然后按住 Command (⌘)，把按钮拖出 Finder 工具栏。
2. 确认按钮已经消失，退出 Go2Codex，再把“应用程序”中的 `Go2Codex.app` 移到废纸篓。
3. 可选：清理偏好设置。

   ```sh
   defaults delete io.github.czrzchao.go2codex
   ```

4. 可选：清理恢复数据。在 Finder 中选择**前往** → **前往文件夹…**，输入 `~/Library/Application Support/io.github.czrzchao.go2codex`，把这个文件夹移到废纸篓。请只在确认工具栏按钮已经移除后操作，因为这里可能包含恢复日志。
5. 可选：清理自动化授权。

   ```sh
   tccutil reset AppleEvents io.github.czrzchao.go2codex
   ```

**重置设置**仅会在保存的设置需要恢复时出现。它不是通用卸载入口，也不会移除 Finder 按钮、App、恢复数据或自动化权限。

<!-- readme-section: troubleshooting -->

## 故障排查

### 自动化权限被拒绝，或者没有出现授权窗口

权限是按需请求的，不会在浏览设置页或安装工具栏按钮时出现。请先实际点击 Finder 工具栏按钮；只有真正启动 CLI 目标时，才会请求终端访问权限。

如果启动失败，请在错误窗口中点击**打开“自动化”设置**，或者手动打开**系统设置** → **隐私与安全性** → **自动化**。在 Go2Codex 下启用 Finder 和所选终端。Go2Codex **不需要**辅助功能、完全磁盘访问权限、屏幕录制或通知权限。

如果没有 Go2Codex 条目，或之前的拒绝状态无法恢复，请退出 Go2Codex，执行下面这个限定范围的重置命令，重新打开 App 后再触发一次启动：

```sh
tccutil reset AppleEvents io.github.czrzchao.go2codex
```

### Finder 提示当前位置不是文件夹

请在 Finder 中打开一个普通且可访问的文件夹后重试。“最近使用”、搜索结果、智能文件夹和其他虚拟视图不能作为工作目录。Finder 没有打开窗口时，Go2Codex 也会安全失败。

### CLI 显示“未找到”或“无法验证”

请在准备使用的终端 profile 中运行 `command -v codex` 或 `command -v claude`。安装 CLI 或修复它的 `PATH` 后，点击**刷新 CLI 状态**。这些状态只供参考，不会阻止保存或启动。

### Terminal 留下空标签页或空窗口

Go2Codex 因为无法安全确认唯一目标，所以没有提交 CLI 命令。请关闭空会话，等待 Terminal 完成其他窗口或标签页变化后重试。如果新标签页持续失败，请在设置中改选新窗口。短暂交接期间，请不要创建、关闭、重排或移动 Terminal 标签页和窗口。

如果另一个 Go2Codex Terminal 交接正在进行，请等待它结束后再重试。

### iTerm2 提示结果无法确定

iTerm2 可能已经创建了请求的会话，但 Go2Codex 没有收到确定的回复。请先检查 iTerm2，再决定是否重试，避免创建重复会话。

### CLI 启动时标题不断变化

Terminal 和 iTerm2 控制自己的标题。登录 shell 初始化，以及前台进程切换到 Codex 或 Claude 时，标题可能发生变化；这不表示 Go2Codex 在重复提交命令。

### 报告问题

请在错误窗口中使用**复制诊断信息**，把脱敏后的记录附到 [GitHub Issue](https://github.com/CzRzChao/go2codex/issues)。Release 诊断不会包含完整工作目录路径或生成的命令。疑似安全漏洞请按照 [SECURITY.md](SECURITY.md) 的说明，通过 [GitHub Security Advisory](https://github.com/CzRzChao/go2codex/security/advisories/new) 私下报告。

<!-- readme-section: known-limitations -->

## 已知限制

- **不支持 Option 点击。** Finder 会保留这个操作，并且可能关闭来源窗口。请使用 Shift 点击，或禁用备用触发方式。
- **Finder 自动设置使用私有偏好，而且依赖精确构建版本。** 未识别的版本会使用手动设置；即使版本受支持，也仍有极小的并发修改竞态。
- **自动 Finder 操作失败后，设置页可能不会立即提供手动入口。** 在受支持的构建上，执行失败后仍可能继续显示“安装”或“修复”。此时仍可显示 `Go2Codex.app/Contents/Helpers/Go2CodexLauncher.app` 并按住 Command 手动拖入，但设置页不会直接提供这个回退入口。
- **仅支持 Apple 芯片。** 不发布 Intel 或 Universal 安装包。
- **没有自动更新。** 稳定版和预览版都需要手动下载并安装。
- **标题由终端控制。** Go2Codex 不会覆盖 Terminal 或 iTerm2 的标题行为。
- **iTerm 返回不确定时不会重试。** 手动重试前请先检查 iTerm2。
- **Go2Codex 本身仅在本地运行。** 它不会发起网络请求，也没有遥测、崩溃上报或后台监控。Go2Codex 调用的编程 Agent、终端、shell 和 shell 启动文件属于其他软件，可能有自己的网络行为或副作用。

不在范围内：VS Code、Cursor、其他编辑器、常驻菜单栏 App、会话恢复、任意提示词注入、Mac App Store 分发，以及自动安装编程 Agent。

<!-- readme-section: building-from-source -->

## 从源码构建

从源码构建需要安装完整 Xcode。为了保证可复现，CI 和公开 Release 构建固定使用 Xcode 16.2。兼容的新版本 Xcode 可以用于本地开发，但发布一致性以 16.2 的验证结果为准。构建前请先检查当前开发者目录：

```sh
xcode-select -p
xcodebuild -version
```

如果 `xcode-select` 提示开发者目录无效，请在 Xcode 设置中选择已经安装的 Xcode，或者让 `xcode-select --switch` 指向这个 App 的 `Contents/Developer` 目录。

项目使用 Swift 6、arm64 macOS 14 部署目标和 Xcode project，不使用 Swift Package Manager。

```sh
git clone https://github.com/CzRzChao/go2codex.git
cd go2codex
Scripts/test.sh
```

在 Xcode 中打开 `Go2Codex.xcodeproj` 即可构建 App。在干净的工作区中，维护者也可以验证 ad-hoc Release 产物，而不发布或安装：

```sh
Scripts/package-github-release.sh --verify-build-only
```

`Scripts/` 下的其他脚本属于维护者工作流，其中部分会操作已经安装的应用。运行前请先检查脚本内容。

<!-- readme-section: publishing -->

## 发布 GitHub Release

仓库支持两个公开发布通道：

- 稳定版标签：`vX.Y.Z`，其中 `X.Y.Z` 必须等于 `MARKETING_VERSION`。
- 预览版标签：`vX.Y.Z-preview.N`，其中 `X.Y.Z` 必须等于 `MARKETING_VERSION`，`N` 必须等于不带前导零的正整数 `CURRENT_PROJECT_VERSION`。

两个通道都会发布使用 ad-hoc 签名、未经公证的 arm64 构建。“Stable”只描述 GitHub Release 通道。

`Config/PublishedRelease.xcconfig` 记录的稳定版已经发布，受保护的标签不能再次创建。这个值告诉两份 README 应展示哪个已成功发布的稳定版；它与当前正在构建的版本有意保持独立。

每次创建新构建时，都应递增 `Config/Base.xcconfig` 中的 `CURRENT_PROJECT_VERSION`；只有目标产品版本变化时才修改 `MARKETING_VERSION`。预览版标签中的 `N` 必须使用当前 build number；准备或发布预览版时，不得修改 `PUBLISHED_STABLE_VERSION`。

请在干净的工作区中执行下面的流程，并在 `stable_tag` 和 `preview_tag` 中选择一个。预检会拒绝有未提交改动的工作区、不完全等于 `origin/main` 的本地 commit，以及本地或远端已经存在的标签：

```sh
set -euo pipefail

test -z "$(git status --porcelain)"
git switch main
git fetch --no-tags origin "refs/heads/main:refs/remotes/origin/main"
git merge --ff-only origin/main
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"

release_version="$(awk -F= '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' Config/Base.xcconfig)"
build_version="$(awk -F= '/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' Config/Base.xcconfig)"
stable_tag="v${release_version}"
preview_tag="v${release_version}-preview.${build_version}"
release_tag="" # Set to "$stable_tag" or "$preview_tag".

case "$release_tag" in
    "$stable_tag"|"$preview_tag") ;;
    *) echo "Choose a stable or preview release tag." >&2; exit 64 ;;
esac
test -z "$(git tag --list "$release_tag")"
remote_tag_refs="$(git ls-remote --tags origin "refs/tags/${release_tag}")"
test -z "$remote_tag_refs"
Scripts/test-github-release.sh
Scripts/package-github-release.sh --validate-only "$release_tag"
git tag -a "$release_tag" -m "Go2Codex ${release_tag#v}"
git push origin "refs/tags/${release_tag}"
```

推送发布标签就是正式发布操作；不要仅仅为了测试工作流而推送标签。请保持稳定版和预览版标签保护规则启用，已经发布的标签绝不能移动或删除。

GitHub Actions 工作流会构建并校验 App，检查 ZIP 往返解压和 SHA-256，然后发布对应的稳定版 Release 或 Pre-release。发布后，请重新下载两个文件、验证校验和、确认 Gatekeeper 说明，并人工测试支持的 Finder 和目标矩阵。

在预览版开发和稳定版发布过程中，`PUBLISHED_STABLE_VERSION` 都应继续指向上一个成功的稳定版。只有新的稳定版工作流成功，而且重新下载的产物通过验证后，才在后续文档 PR 中更新 `Config/PublishedRelease.xcconfig`、两份 README 的稳定版链接、资产名以及所有特定版本文案。README 契约测试会确保可机器校验的值保持同步。

<!-- readme-section: license -->

## 许可证

[MIT](LICENSE)。
