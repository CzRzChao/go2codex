# Go2Codex 本地开发、实机验证与发布 SOP

本文件是 Go2Codex 本地开发的唯一操作规范。它解决三个问题：开发中的改动不能碰到正在使用的正式版；真实 Finder、Automation 和终端行为必须在独立 Debug 身份下验证；正式更新必须能够证明来源、完成备份，并在失败时确定性回滚。

脚本是强制门禁，不是便捷别名。脚本拒绝继续时，不允许改用 Xcode、Finder 拷贝、`codesign` 或临时命令绕过。应先修复门禁指出的问题，再从对应车道重新开始。

## 0. 当前安全状态

截至本 SOP 建立时：

- 仓库已执行 `git init`，但还没有首个 commit；
- 本机尚没有可用的 Apple Development 签名身份；
- 当前安装在 `~/Applications/Go2Codex.app` 的正式版是需要保护的已知可用基线；
- 源码中的新改动不等于已经安装，也不得直接覆盖这份基线。
- “最近使用”友好提示、Terminal.app 冷启动修复和 iTerm2 initial-event 冷启动修复目前只在源码中，尚未进入这份冻结正式版。

因此目前可以运行 Unit 车道，也可以在用户明确确认后安装独立的临时 ad-hoc Debug 做非权威人工观察；配置 Apple Development 身份后才能进入稳定签名的 Installed Debug，建立首个 Git baseline 并保持 clean HEAD 后才能记录权威 smoke，递增 Build 号后才能进入 Release Candidate 和 Promote。门禁拒绝越过对应阶段是正确行为，不是脚本故障。Unit 始终可以用于事故诊断；存在未完成的正式安装或回滚状态时，Installed Debug、Debug smoke 和 Release Candidate 必须停止，直到拥有该状态的专用脚本完成确定性恢复。

## 1. 四车道模型

每个改动必须沿同一个方向前进：

```text
Unit（隔离测试）
  → Installed Debug（独立身份实机验证）
    → Release Candidate（只生成候选）
      → Promote（明确安装）
        ↘ 失败时 Rollback（只恢复已验证备份）
```

| 车道 | 用途 | 固定产物或位置 | 是否可以碰正式版 |
| --- | --- | --- | --- |
| Unit | 编译、单元测试、脚本门禁测试 | 项目内 `.build/` | 不可以 |
| Installed Debug | 在真实 Finder、TCC、Terminal.app、iTerm2 和目标应用中验证 | `~/Applications/Go2CodexDebug.app` | 不可以 |
| Release Candidate | 从 clean Git HEAD 生成可审计候选 | `.finder-toolbar-local/release-candidate/Go2Codex.app` 和 `manifest.env` | 不可以 |
| Promote / Rollback | 将唯一候选提升为正式版，或恢复安装脚本创建的备份 | `~/Applications/Go2Codex.app`；备份位于 `.finder-toolbar-local/backups/*.zip` | 只允许专用脚本 |

四个车道的 Bundle ID、偏好域、应用名和构建位置不能混用。Unit 和 Debug 成功不代表正式版已更新；Release Candidate 成功也不代表已安装。

临时 ad-hoc Debug 是四车道之外的诊断旁路，只能用于证书缺失时的当前故障观察。它使用同一独立 Debug 路径和 Bundle ID，但不能记录 smoke pass、不能生成候选或发布凭据，也不能被描述为正式版已修复。

正式安装与回滚共用固定事务目录，但事务 `state` 必须记录唯一 `OPERATION`：`release-install` 或 `release-rollback`。只有对应的 `install-personal.sh` 或 `rollback-personal.sh` 可以恢复它。原子提交前留下的 operation-specific `.preparing` 只包含未生效快照，归属脚本会先确认没有活动事务、cleanup 或冲突记录，再安全清除并要求重跑；它不能留给用户手工删除。事务完成或恢复后，活动目录会先原子改名为同归属的 `.cleanup` 退役墓碑，再递归清理；断电最多留下可识别墓碑，不会留下半删的活动事务。归属脚本必须先依据 pending 与目标树完成协调，再安全删除墓碑。归属缺失、损坏、与 pending 记录冲突或属于另一脚本时，必须原样保留全部证据并停止；不能根据当前 App “看起来像新/旧版”来猜测。

脚本职责固定如下：

- `test-sop.sh`：只测试路径、Git、签名、manifest、事务和失败回滚等 SOP 门禁；
- `test.sh`：运行全部自动化测试，并证明隔离构建没有改变正式版；
- `install-debug.sh`：只构建、验证和安装独立 Debug；默认确认入口要求稳定签名，临时 ad-hoc 入口必须另行显式确认；
- `smoke-debug.sh`：开始实机检查并记录用户明确确认的结果，不模拟 UI 通过；
- `build-personal.sh`：只生成 Release Candidate 和 manifest；
- `install-personal.sh`：只把固定候选提升到固定正式路径；
- `rollback-personal.sh`：只恢复安装流程创建并验证过的固定备份；
- `verify-app.sh`：只读验证一个包的身份、结构、签名、权限、架构、资源和隐私边界，通常由以上脚本调用；单独通过它不构成发布成功。

## 2. 不可违反的规则

1. 不得从 Xcode、DerivedData、`.build` 或 Finder 直接复制 `Go2Codex.app` 到 `~/Applications` 或 `/Applications`。
2. 不得在 Applications、桌面、下载目录、`/private/tmp` 等可发现位置保留第二个正式 Bundle ID 的 `.app` 副本。唯一例外是脚本管理、未登记且不得启动的隐藏固定候选；临时备份必须是安装脚本创建的非 `.app` ZIP。
3. 不得通过 Xcode Run 启动 Release。Xcode Run 的 Debug 也不能计入真实 Finder/TCC smoke；权威实机检查只能使用 `install-debug.sh` 安装并稳定签名的 `Go2CodexDebug.app`。
4. 不得使用 `codesign --deep --force`、手动重签或修改候选包。`codesign --deep` 只能由校验流程用于只读验证。
5. 不得把重置正式版 Automation 权限、重启 Finder、修改 Finder 偏好、删除 Go2Codex 偏好、重启 `cfprefsd`、重置 Launchpad 或编辑其数据库当作通用调试步骤。
6. 不得把 Finder 的“最近使用”、搜索结果或其他智能文件夹当作真实 Workspace，也不得在失败时回退到桌面、主目录、上次路径或后台 Finder 窗口。
7. 不得给构建脚本传入任意 DerivedData、安装目标或备份位置。所有构建与 DerivedData 目录必须固定在项目 `.build/` 内；候选、备份、Debug/正式事务和回滚临时目录只能使用脚本内固定并受安全检查的路径，不能由调用者改写。
8. 不得跳过 `test-sop.sh`、`test.sh`、Debug smoke、Git clean、版本递增、签名连续性、候选 manifest、备份或安装后校验中的任一门禁。
9. “只是一个小修复”“之前已经测试过”或“现在急用”都不是跳车道的理由。热修复遵守同一流程。
10. 脚本一旦失败，当前车道立即停止。不能人工完成它尚未完成的后半段，再把结果当成成功。
11. 不得并行运行 Unit、产品构建、Debug 安装、smoke 记录、正式候选、安装或回滚中的任意两个操作。全部车道共用一把进程锁；产品脚本内部调用 Unit 时，只允许脚本验证过的父子继承。未取得锁的进程不得执行构建清理、事务恢复或记录协调，也不能删除有效锁文件来强行继续。
12. Debug smoke 只有在 `debug-smoke.pass` 有效，且 `debug-smoke.pending`、`debug-smoke.pending.next`、`debug-smoke.pass.next` 全部不存在时才算通过。pass 与 pending 并存仍是未完成状态，不能进入候选或安装。
13. `~/Applications/.go2codex-update`、任一 operation-specific `.preparing` 或 `.cleanup`、`install.pending(.next)`、`rollback.pending(.next)` 或回滚收据 staging 任一存在，都属于未完成的 Release 操作。除 Unit 诊断和对应归属脚本的恢复外，其他产品车道一律停止。
14. 不得手工删除 transaction、pending、next 或 staging 来“解锁”。只能运行错误信息指定的归属脚本；若归属不明或校验失败，保留现场并审查。

## 3. 一次性准备

### 3.1 建立 Git baseline

Release Candidate 必须能指向一个不可变的 Git commit。首次准备需要：

1. 在仓库内配置真实的 Git 作者名和经过 GitHub 验证的邮箱；不要猜测或代填邮箱。
2. 审查 `git status --short` 中的全部文件，确认没有证书、个人路径、构建产物、Finder 快照或其他机器私有数据。
3. 先通过 `./Scripts/test-sop.sh` 和 `./Scripts/test.sh`。
4. 创建首个 commit，并再次确认 `git status --short` 为空。

后续发布仍必须从 clean HEAD 开始。未跟踪文件也属于脏工作区；不能用临时忽略或 stash 掩盖来源不明的内容来通过发布门禁。

### 3.2 创建稳定的 Apple Development 身份

真实 Finder 和 Automation 验证需要跨重建保持稳定身份。一次性操作为：

1. 在 Xcode 的 Settings → Accounts 中登录 Apple ID。
2. 选择对应 Team，在 Manage Certificates 中创建 Apple Development 证书。
3. 确认 Keychain 中出现一个有效的 Apple Development 代码签名身份。
4. 从 `Config/LocalSigning.conf.example` 复制出 `Config/LocalSigning.conf`。
5. 只填写两个字段：

   - `TEAM_ID`：10 位大写字母或数字；
   - `IDENTITY_SHA1`：该 Apple Development 证书的 40 位十六进制 SHA-1 指纹。

`Config/LocalSigning.conf` 是本机私有配置，必须被 Git 忽略；example 才能提交。脚本必须校验证书类型、有效性、Team、指纹，以及外层 App 与嵌套 Launcher 的签名一致性。不能只凭证书显示名称选择身份。

如果证书过期、更换 Team 或 Keychain 丢失，应停止 Installed Debug 和发布流程，先恢复同一签名策略；不能临时切回 ad-hoc 后继续更新。

### 3.3 首次签名迁移

当前已安装正式版是 ad-hoc 签名，而后续本地正式版使用稳定 Apple Development 身份。两者的签名要求不同，所以第一次提升属于一次性迁移：

- 只能在 Git baseline、完整测试、完整 Debug smoke 和稳定签名候选全部通过后执行；
- 必须使用迁移专用确认 `--confirm-migrate-adhoc`，不能与普通安装确认同时传入；
- 迁移后可能需要对 Finder 或终端 Automation 再授权一次；
- 迁移完成后，普通更新必须保持外层和 Launcher 的指定签名要求一致，不能再次使用迁移开关来绕过身份变化。

这不是当前即可默认执行的步骤。只有安装脚本确认当前确实是旧 ad-hoc 基线、候选确实是 Apple Development 签名时，迁移开关才有效。

### 3.4 安装独立 Debug 按钮

首次实机调试时，运行：

```sh
./Scripts/install-debug.sh --confirm-install-debug
```

它只能在不存在未完成 Release 操作时安装 `Go2CodexDebug.app` 到 `~/Applications/Go2CodexDebug.app`，并校验 Debug 名称、Bundle ID、偏好域和稳定签名。它不得覆盖、启动、登记或重签正式版；安装完成后也不自动启动 Debug、不重置 TCC、不重启 Finder。

当 Apple Development 证书不可用，且用户只需立即观察当前修复时，可以显式运行：

```sh
./Scripts/install-debug.sh --confirm-install-adhoc-debug
```

该模式仍先运行全部自动测试，只安装同一固定 Debug 路径，使用事务备份与失败回滚，校验正式版前后指纹，并且不自动启动应用。它可能在每次重建后重新请求 Automation 权限；不得对该包执行 `smoke-debug.sh --record-pass`，也不得将其用于 Release Candidate 或 Promote。脚本拒绝在 ad-hoc 与稳定 Debug 之间无迁移切换，并拒绝用 ad-hoc 覆盖已有稳定 Debug。

随后从 Debug 设置页显示嵌套 Launcher，并按应用内说明 Command-drag 到 Finder 工具栏。Debug 按钮应显示为 `Go2Codex Debug`，与正式按钮并存。以后调试只能点击 Debug 按钮；不要用 Debug Launcher 替换正式按钮。

## 4. 普通开发迭代

每次代码改动按以下顺序执行：

1. 先写清楚复现条件：Finder 是普通目录还是智能视图、点击方式、目标、终端、窗口/标签状态、应用版本、`stage` 和 `errorCode`。
2. 先在测试或受控 fixture 中复现，再做最小修改；不要把现象直接归因于 TCC、签名或 Finder。
3. 运行 Unit 车道：

   ```sh
   ./Scripts/test.sh
   ```

   `test.sh` 必须先运行 `test-sop.sh`，再通过只包含 Core 与 UnitTests 的测试 scheme 执行完整 Xcode 测试。它使用固定 `.xcresult`，不能只相信 `xcodebuild` 的退出码；结果包必须明确记录 `Passed`、测试数大于零、失败/跳过/预期失败均为零且通过数等于总数。它不得生成任何 App 产品、不得触发 Launch Services 应用登记，并证明正式安装包未变化。

4. 开发中可以用显式 ad-hoc 入口安装脏工作区的独立 Debug 做观察，但这种检查不能生成正式 smoke 记录，也不能进入候选流程。
5. 准备发布时先递增 `CURRENT_PROJECT_VERSION`。修复版可保持相同 `MARKETING_VERSION`，但 Build 号必须是整数且大于当前安装版。
6. 再运行完整 `test.sh`，提交全部代码、配置、资源、测试、脚本与文档改动，并确认 HEAD clean。
7. 从这一个 clean commit 重新运行 `install-debug.sh`，再执行并记录完整 Debug smoke。记录绑定 Git HEAD、Debug 包摘要、Team ID，以及外层和 Launcher 的指定签名要求。
8. 如果 smoke 失败，回到 Unit 修复并创建新 commit；旧记录立即失效。不得在同一记录上只补测失败项。
9. smoke 通过后进入 Release Candidate。候选生成后不再修改候选包；任何源码、版本、配置、签名、Debug 包、smoke 凭据或脚本变化都必须从 Unit 重新开始。

若只修改纯 Core 算法或测试，开发中间可以暂不安装 Debug；但任何正式候选都必须有与其内容一致的完整 Debug smoke 记录。

修改 SOP 或任一 `Scripts/` 文件时，应先单独运行：

```sh
./Scripts/test-sop.sh
```

确认门禁的拒绝路径也通过后，再运行完整 `./Scripts/test.sh`。不能通过删减脚本测试来让门禁放行。

若修改 `Sources/Go2CodexLauncher/Resources/ITermHandoff.applescript`，必须在装有受支持 iTerm2 的开发机上使用唯一的显式入口重新生成同目录的 `ITermHandoff.scpt` 和 provenance：

```sh
./Scripts/rebuild-iterm-handoff.sh --confirm-rebuild-iterm-handoff
./Scripts/verify-iterm-handoff.sh
```

重建脚本只编译到受控 staging 文件，确认可反编译后才替换二进制并生成绑定源码与二进制精确字节摘要的 provenance；它不会执行生产 handler。脚本最后显示的反编译内容只用于人工复核每个 handler 首先派生精确的 `Library/Application Support/iTerm2/version.txt` 静默启动路径、把打开该路径作为 timeout 内第一个目标命令、随后创建对象并绑定目标 session、单次 write、60 秒 Apple Event timeout、无通用 `launch`/activate/run/reopen/delay/close 和显式 `return true`，不能作为跨系统稳定文本保存或比较。普通构建、Unit 和 CI 只运行只读 provenance 门禁，不会启动 iTerm、调用 `osacompile` 或修改源码。不能手工编辑 `.scpt` 或 provenance，也不能只更新其中一个；三者必须在同一轮 review。Unit 会验证编译资源可加载，产品验证会校验打包摘要且要求资源只出现在嵌套 Launcher 中，但真实 iTerm 行为仍只由 Installed Debug smoke 证明。

handler 内的 sentinel open 只是已编译资源中保留的保护，不承担 iTerm2 冷启动的首事件排序保证。该保证位于 Swift 平台适配器：每次 iTerm2 Handoff 都先向 Launch Services 解析出的精确 App URL 提交一个不含命令的 `aevt/odoc` initial event，direct object 只能是包含 `~/Library/Application Support/iTerm2/version.txt` file URL 的单元素 list，并等待 `NSWorkspace` completion 成功。失败时不得查询 current window、执行 handler、重试或 fallback。New Window 成功后只能执行一次 handler；New Tab 成功后才允许查询 current window 并执行一次选定的 handler。仅修改这一 preflight 边界时不得顺带重建或修改 `ITermHandoff.applescript`、`.scpt` 或 provenance；自动测试必须分别覆盖精确 descriptor、精确 App URL、调用次数和失败后的零下游副作用。

## 5. Installed Debug 实机 smoke

### 5.1 开始条件

- Unit 车道已通过；
- `Config/LocalSigning.conf` 指向有效 Apple Development 身份；
- 已安装 Debug 必须是 `stable-local`；临时 ad-hoc Debug 不符合开始条件，不得记录权威 smoke；
- 正式版仍位于唯一固定路径，且没有被本轮修改；
- 不存在未完成的 Release transaction、preparing、cleanup 墓碑、install/rollback pending 或 staging；
- Finder 工具栏中的 Debug 按钮明确指向 `Go2CodexDebug.app` 的嵌套 Launcher；
- 准备一个普通本地文件夹作为测试 Workspace；路径不需要是 Git 仓库，也不要包含私人诊断内容。

安装并开始本轮 smoke：

```sh
./Scripts/install-debug.sh --confirm-install-debug
./Scripts/smoke-debug.sh --begin
```

`--begin` 会做只读预检、作废旧的通过记录，并写入与当前 commit、Debug 包和签名身份绑定的本轮 pending 记录；它不修改或启动任何 App。它不能替代可见 UI、TCC 和目标应用中的人工确认。若 `--record-pass` 在 pass 已原子写入、pending 尚未清除时被中断，两者并存仍视为未通过；恢复方式是重新执行同一个 `--record-pass --confirm-smoke-passed`，不是手工删除任何记录。

### 5.2 必测清单

1. **普通启动**：从 `~/Applications/Go2CodexDebug.app` 启动，只出现 Debug 设置页；不得读取 Finder Workspace 或启动任何目标。
2. **普通目录 + 普通点击**：Finder 前台窗口显示测试文件夹，普通点击 Debug 按钮；默认目标只启动一次，并收到这个文件夹，而不是选中项、Git 根、桌面或其他窗口。
3. **“最近使用”**：Finder 进入“最近使用”后分别普通点击与 Shift 点击 Debug 按钮；两次都应出现“当前 Finder 位置不是实际文件夹”的友好提示，不显示目标选择器、不启动目标、不切换到其他 Finder 窗口，也不回退路径。
4. **Shift 点击**：回到普通目录，按住 Shift 直到选择面板稳定出现。确认四个目标顺序固定、面板不闪退；Escape 和点击外部都安静取消；再次打开并选择一个目标时只 Handoff 一次。
5. **重复调用**：连续完成至少五次打开/取消，并做一次受控快速重复点击；不得出现重叠面板或重复 Handoff。
6. **桌面目标**：从选择器分别启动 Codex App 与 Claude Desktop 一次；两者都只启动一次并收到准确目录。
7. **iTerm2 + Codex CLI**：每个冷启动用例前都完全退出 iTerm2，再分别以 New Window 和“New Tab 但未启动”调用；每次只能出现一个承载命令的窗口，不得附带默认空窗口或空标签。再验证 iTerm2 已运行但无窗口，以及有现有窗口时按设置新建标签或窗口且不改变原标签；这同时证明每次都会运行、但不含命令的 preflight 没有破坏 warm path。每一种路径连续执行五次。新会话必须进入测试文件夹，只提交固定 `codex` 命令。
8. **iTerm2 + Claude Code CLI**：重复完全退出、运行但无窗口、运行且有窗口三种状态下的新标签和新窗口路径；每个冷启动用例前都要重新完全退出，且只能出现一个承载命令的窗口，不得附带默认空窗口或空标签；warm path 的现有窗口和原 session 不得被 preflight 改动。每一种路径连续执行五次，只提交固定 `claude` 命令。
9. **Terminal.app 冷启动 + 两个 CLI**：完全退出 Terminal.app，分别用 New Window 和“New Tab 但无窗口”启动 Codex CLI 与 Claude Code CLI；每次都必须只出现一个承载命令的窗口、没有额外空白窗口，进入准确文件夹，并且只提交一次对应的固定命令。每个用例前都要重新完全退出 Terminal，不得用已运行进程代替冷启动；每一种成功路径连续执行五次。
10. **Terminal.app 运行中路径**：保持 Terminal 运行，先关闭全部窗口，再验证 New Window 与 New Tab 都各生成一个承载命令的窗口；随后保留一个现有窗口，New Window 必须新建独立窗口，New Tab 必须在提交命令前明确失败且不改动现有标签。
11. **失败与生命周期边界**：command not found、Terminal.app 与 iTerm2 的 Automation 拒绝、以及取消均不得回退目标或重复提交；成功、取消或失败后 Launcher 都应退出，不留下 Dock 图标、菜单栏项或常驻后台进程。
12. **隔离复核**：正式版的应用文件、偏好、Automation 状态和 Finder 正式按钮没有被脚本重置或覆盖。

任一项失败都不得记录通过。保存脱敏诊断，返回 Unit 车道修复并重新执行整套 smoke；不能只重测刚失败的一项。

全部人工确认后运行：

```sh
./Scripts/smoke-debug.sh --record-pass --confirm-smoke-passed
```

记录必须绑定当前源码状态、Debug 包摘要和签名身份。记录命令不应自动点击 UI，也不应根据“没有报错”推断通过。候选与安装脚本会同时检查 pass 内容及 pending/next 全部不存在，因此一次中断的记录不能误授权发布。

## 6. Release Candidate

Release Candidate 是可审计产物，不是安装命令。执行：

```sh
./Scripts/build-personal.sh
```

候选流程必须拒绝或无法完成以下状态：

- Git 没有 HEAD；
- 工作区存在已修改、已暂存或未跟踪文件；
- `test-sop.sh`、完整测试、包体验证或当前内容对应的 Debug smoke 未通过；
- smoke pending/next/pass staging 任一存在，即使已有 pass；
- 任一 Release transaction、operation-specific preparing/cleanup、install/rollback pending/next 或回滚收据 staging 存在；
- Build 号不是整数、没有递增或与安装版相同；
- 本地签名配置缺失、证书无效、使用 ad-hoc、Team 不一致，或外层与 Launcher 身份不一致；
- 固定候选位置、构建位置或其中任一路径是符号链接或逃逸到允许目录之外。

候选目录成功后只允许保留：

- `.finder-toolbar-local/release-candidate/Go2Codex.app`；
- `.finder-toolbar-local/release-candidate/manifest.env`。

manifest 至少绑定 Git HEAD、版本、候选整包树摘要、Team、外层与 Launcher 的指定签名要求摘要，以及 smoke 凭据摘要。Xcode 构建 App 时可能短暂登记固定 `.build` 产品，脚本必须立即精确注销并删除该 App 构建目录；隐藏固定候选自身不得登记或启动。不要手动编辑 manifest 或候选包；需要变更时删除旧候选应由脚本安全处理，并从 Unit 车道重新生成。

## 7. Promote、首次迁移与安装后确认

### 7.1 普通提升

候选和 manifest 未变化且所有门禁仍有效时，明确执行：

```sh
./Scripts/install-personal.sh --confirm-install
```

标准安装只接受脚本刚生成且与当前 clean HEAD 一致的固定候选。它必须：

1. 先重新验证 smoke 没有 pending/next、候选、manifest、版本和外层/Launcher 签名连续性；候选生成后开始的新一轮 smoke 也会阻断安装；
2. 更新已有正式版时，在 `.finder-toolbar-local/backups/` 创建非 `.app` ZIP；在触碰正式版前，必须完成 ZIP 完整性检查、受限目录 round-trip 解压、唯一顶层 payload、整树摘要和历史兼容包体验证。全新安装会明确记录没有可回滚旧版；
3. 只处理可执行路径精确属于固定正式 App 的进程；正常结束超时就中止，不自动强杀；
4. 在 `~/Applications/.go2codex-update` 中使用 `previous.payload`、`next.payload` 和带 `OPERATION=release-install` 的 `state` 完成可恢复事务；成功或恢复后先原子改名为 `release-install.cleanup` 墓碑，再协调 pending 与目标树并清理；这里不得出现第二个 `.app`，且安装脚本不得恢复 rollback-owned 或未知归属事务；
5. 安装后重新进行包体、签名、manifest 和逐文件校验；
6. 失败时在候选启动前自动恢复旧版并验证恢复结果；
7. 只登记固定正式路径，不自动启动应用、不重置 TCC、不重启 Finder。

### 7.2 首次 ad-hoc 迁移

只有第 3.3 节所述的一次性情形，才改用迁移专用确认：

```sh
./Scripts/install-personal.sh --confirm-migrate-adhoc
```

该开关只能允许“已验证旧 ad-hoc 基线 → 已验证 Apple Development 候选”这一个身份变化，不能允许任意签名变化、降级、跳过备份或跳过校验。迁移完成后，后续普通更新不得再次使用；如果明确回滚到旧 ad-hoc 基线，则这次迁移也随之撤销，重新提升稳定签名候选时必须再次走同一显式迁移门禁。

### 7.3 安装后人工确认

安装脚本成功不等于功能验收成功，因为它不会自动启动。用户随后手动确认：

1. 从 Applications 或 Launchpad 启动，只进入设置；
2. 普通 Finder 文件夹的普通点击正确 Handoff；
3. “最近使用”的普通点击与 Shift 点击都显示友好提示且无 Handoff；
4. Shift 面板稳定，取消与选择各一次；
5. 本次改动涉及的目标或 Terminal Host 路径至少验证一次；
6. Finder 工具栏原按钮仍指向固定嵌套 Launcher 路径。

首次签名迁移若出现系统 Automation 提示，只对明确需要的 Finder 或当前所选 Terminal Host 授权。不要主动重置权限来“重新测一遍”。

## 8. Rollback

正式版安装后若关键路径失败，停止继续试错，执行：

```sh
./Scripts/rollback-personal.sh --confirm-rollback
```

回滚脚本只能使用最近一次安装脚本生成、摘要与 manifest 均有效的固定备份；不接受任意 `.app`、下载文件或手工 ZIP。解压出的恢复源必须在结束目标进程或准备覆写事务前通过整树匹配和历史兼容包体验证。它沿用相同的固定目标、进程范围、事务状态、符号链接拒绝和包体验证，且不自动启动、不重置 TCC、不重启 Finder。

回滚成功后，手动验证普通文件夹普通点击、Shift 面板和本次故障路径。回滚事务必须记录 `OPERATION=release-rollback`，且必须与 rollback pending 一致；回滚脚本只恢复这种明确归属的事务。若事务属于安装、归属缺失或记录冲突，回滚脚本必须停止并提示先使用安装脚本恢复。恢复复制、包体验证或重新登记任一步失败时，都必须保留唯一事务快照，不能凭当前目录中“看起来像旧版”的文件猜测。

如果没有有效备份，回滚必须停止并报告；不得从 `/private/tmp`、DerivedData、聊天附件或旧 `.app` 副本恢复。

## 9. 事故恢复

遇到“之前可用，改完完全不可用”时按以下顺序处理：

1. **冻结现场**：停止构建、安装、重签、权限重置、Finder/Dock/`cfprefsd` 重启和偏好删除。不要再次覆盖正式版。
2. **先确认 Finder 场景**：记录当前是否为普通目录、最近使用、搜索结果、智能文件夹、无窗口、已卸载卷或无权限目录。虚拟视图失败不等于正式版整体损坏。
3. **保留脱敏证据**：复制错误弹窗中的版本、系统版本、`stage`、`errorCode`、目标和终端；不公开完整 Workspace 路径。
4. **划清版本**：只读确认当前运行可执行文件来自正式固定路径还是 Debug 固定路径，并确认外层/Launcher 的版本和摘要。不要根据图标、窗口标题或 Launchpad 位置猜版本。
5. **验证已知基线**：在一个普通测试文件夹中只做一次最小检查。如果正式版在基线场景仍工作，就保持不动，所有修复回到 Unit 和 Installed Debug。
6. **复现并加测试**：先让自动测试或受控 fixture 捕获相同错误分类，再修改源码。平台返回值不能仅凭一次现象重新解释；错误文案也需要测试。
7. **只通过车道更新**：修复必须重新通过 Unit、完整 Debug smoke、clean HEAD、Release Candidate 和显式 Promote。不能现场修改已安装包。
8. **正式版确实回归时回滚**：只使用 `rollback-personal.sh --confirm-rollback`。回滚后保留候选、manifest、备份和诊断用于复盘，不继续堆叠修复。

若现场存在 transaction、preparing、cleanup 墓碑、pending 或 next，先读取错误提示中的事务归属，只运行对应的安装或回滚入口。`.preparing` 表示尚未到达原子提交点，归属脚本验证协调记录后可清除它，目标 App 必须保持不变；`.cleanup` 表示覆盖事务已完成或已完成恢复，但清理曾被中断，归属脚本必须先根据 pending 和已安装目标树协调收据，再删除墓碑。安装脚本不得处理 rollback-owned 状态，回滚脚本不得处理 install-owned 状态；归属不明时两者都不得运行恢复动作。不要删除记录，也不要交替试两个脚本。

下列操作只在有独立证据且有专门步骤时允许，绝不能作为第一反应：

- 重置 Debug 外层 Bundle ID 的特定 Automation 权限；
- 精确注销一个已确认的 Debug 构建路径；
- 刷新 Launch Services 或 Dock；
- 修复本机证书或本地签名配置。

即使需要这些操作，也不得影响正式 Bundle ID、正式偏好域、Finder 工具栏配置或其他应用。

## 10. 每轮完成证据

一次可发布迭代至少要保留以下结果：

- `test-sop.sh` 的全部安全检查通过；
- `test.sh` 完整通过，以及固定 `.build/test-results.xcresult` 和 `.build/test-summary.json` 中明确的零失败、零跳过结果；
- 与当前内容绑定的 Debug smoke pass 记录，并确认 pending/next/pass staging 全部不存在；
- clean Git HEAD；
- 递增后的版本与 Build；
- Release Candidate 的 `manifest.env`；
- Promote 更新已有正式版时生成并验证的 ZIP 备份；全新安装时 manifest 中明确记录 `NONE`；
- 安装后人工确认结果，或失败后的 rollback 结果；成功结束后确认没有残留 transaction、preparing、cleanup 墓碑、pending 或 staging。

任何一项缺失，状态只能写“尚未发布”，不能写“已修复正式版”或“已完成”。自动化测试通过也不能替代真实 Finder、TCC、iTerm2 和目标应用的可见验证。

## 11. 用户需要介入的边界

日常编码、自动测试、Debug/Release 构建、包体检查、候选生成、备份和事务恢复可以由开发代理完整执行。以下动作必须由用户明确参与：

- 一次性登录 Xcode、创建 Apple Development 证书，并提供本机签名配置中的 Team 与证书指纹；
- Finder、Automation、iTerm2 和目标应用中的可见 smoke 结果确认；
- `--confirm-install-debug`、`--confirm-install`、一次性的 `--confirm-migrate-adhoc` 和 `--confirm-rollback` 所代表的明确授权；
- 首次 Git commit 前确认作者邮箱和纳入版本控制的文件范围。

除此之外，不应把常规构建、测试、候选制作或故障诊断步骤交给用户手工拼接。
