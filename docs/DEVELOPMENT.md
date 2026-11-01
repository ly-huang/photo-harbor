# 开发与验证

## 目录

| 路径 | 用途 |
| --- | --- |
| `Sources/PhotoHarbor/` | App 源码，无外部包依赖 |
| `Tests/PhotoHarborTests/` | 文件操作的合成夹具测试 |
| `scripts/` | 构建、安装、测试、仓库检查 |
| `assets/AppIcon/master.png` | 正式图标源图，不含照片元数据 |
| `docs/` | 当前实现的维护文档 |
| `.github/` | 自动检查及 PR 模板 |
| `.build/`、`dist.noindex/` | 忽略的构建输出 |
| `archive.local/` | 仅原开发机器保留的历史归档，不参与构建或提交 |

## 工具链与运行

先确认 `xcode-select -p`、`xcrun swift --version`、`xcrun --show-sdk-version` 指向合适工具链。需要 macOS 26+ SDK 编译玻璃 API；代码有运行时可用性检查，部署目标为 macOS 14。

`zsh scripts/build-app.sh` 编译 App、从正式图标生成 iconset / ICNS、写入 Info.plist，最后进行本地临时签名。源资源不被改写。输出在 `dist.noindex/拾影.app`，缓存和图标中间文件均在 `.build/`。脚本不安装、不修改照片、不注册开发副本。

`swift build` 可用于编译迭代，但它只生成可执行文件，不生成完整应用包。正式 UI / Dock / 图标检查应使用构建脚本生成的 `.app`。不要同时运行开发副本和已安装副本。

发布版本号与 build number 在 `scripts/build-app.sh` 的 Info.plist 中维护。分发到其他 Mac 的 Developer ID 签名、公证与自动更新暂未实现，不要将临时签名构建描述为已公证发行版。

## 自动测试

```sh
zsh scripts/check.sh      # 仓库检查 + 全部确定性测试
zsh scripts/build-app.sh  # 构建完整 App
```

可分别运行：

- `test-repository.rb`：模拟令牌、私人路径、私密文件与二进制拦截，并验证未暂存的干净替换不能掩盖索引内容。
- `test-core.sh`：15 项核心文件测试，包括配对歧义、EXIF 日期、位置优先级、复制校验、防覆盖、符号链接和文件身份。
- `test-store.sh`：7 组相册会话场景，包括四图选择、清空选择、撤销批次、冲突恢复和离线目录。
- `test-viewer.sh`：视野几何、鼠标锚点、工具栏和评测面板隐藏 / 固定生命周期。

核心测试使用临时目录和合成数据。Command Line Tools 环境没有完整 XCTest 时，`TestHarness.swift` 运行同一份测试方法；完整 Xcode 环境也可运行 `swift test`。不要为取得截图对个人照片做删除测试。

GitHub Actions 使用 `macos-26`，运行仓库检查、上述测试与 App 构建；不安装 App、不上传图片或打包产物。环境说明见 [GitHub 官方 runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

## 隔离 UI 验证

```sh
mkdir -p .build/ui-fixtures
xcrun swift scripts/make-fixtures.swift "$PWD/.build/ui-fixtures"
PHOTOHARBOR_STATE_PATH="$PWD/.build/ui-fixtures/state.json" \
  "dist.noindex/拾影.app/Contents/MacOS/PhotoHarbor"
```

占位 ARW 仅验证配对与文件操作，不代表真实 RAW 解码测试。真实 RAW 预览依赖当前系统对相机型号的支持。先退出其他实例，确保本轮测试使用隔离配置。评测结果与对比选择保存在会话内存中，退出后需重新选择 / 评测。

原生模型测试为可选实机检查：编译 `Models.swift`、`LibraryService.swift`、`PhotoAssessment.swift` 与 `scripts/AssessmentTests.swift`，向可执行文件传两个自行生成的 JPEG 路径。在受限或无图形计算服务环境可能不可用，确定性 CI 不依赖该测试，也不使用个人照片。模型结果不应固定断言为某个审美分数。

UI 改动还需人工检查：普通 / 全屏窗口、窄窗口、菜单悬停提示、导航开关、浮层顶端、固定评测不遮图、选择移出及清空。记录环境、覆盖项和未验证项到 CHANGELOG 或 PR；截图仅可使用合成内容。

## 常见问题

- 找不到玻璃 API：SDK 太旧，切换到 Xcode / CLT 26+。
- `iconutil` 或原生模型在受限环境失败：在正常 macOS 终端验证；不要绕过校验或把失败当成通过。
- 安装失败：先退出拾影，确认 `/Applications` 可写以及现有应用标识匹配。
- 修改状态模型：保持 `SavedState` 向后迁移，并添加迁移与失败恢复测试。手动排错先复制配置到本地隔离目录，禁止提交这份配置。

## 变更的文档要求

每次功能、修复、构建、持久化或测试行为变化都更新 CHANGELOG，并更新受影响文档。PR 检查会要求 `Sources/`、`scripts/`、`assets/`、`Package.swift` 的变更附带 CHANGELOG；具体要求见 CONTRIBUTING 和 AGENTS。
