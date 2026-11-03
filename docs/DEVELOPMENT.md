# 开发指南

## 环境准备

需要 macOS，以及 Xcode 26+ 或包含 macOS 26+ SDK 的 Command Line Tools。构建目标为 macOS 14，源码使用 Swift 5 语言模式；Swift Package Manager 的 manifest 需要支持 Swift 6 的工具链。

确认工具链选择正确：

```sh
xcode-select -p
xcrun swift --version
xcrun --show-sdk-version
```

构建和测试入口使用系统工具，不依赖个人配置、开发者证书、第三方软件包或仓库外的源码文件。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| `Sources/PhotoHarbor/` | 应用实现。 |
| `Tests/PhotoHarborTests/` | 核心文件操作的合成测试。 |
| `scripts/` | 构建、测试、安装、仓库检查及夹具生成器。 |
| `assets/AppIcon/master.png` | 无个人照片元数据的正式图标源图。 |
| `docs/` | 架构、开发、编辑、标记和隐私规范。 |
| `.github/` | CI 与协作配置。 |
| `.build/`、`dist.noindex/` | 忽略的编译缓存和打包输出。 |
| `archive.local/` | 可选本地归档，不参与构建或提交。 |

## 构建与打包

```sh
zsh scripts/build-app.sh            # 增量 debug 构建
zsh scripts/build-app.sh --release  # 优化构建
```

标准输出为 `dist.noindex/拾影.app`。构建脚本编译当前架构、生成图标资源、写入 Info.plist 并进行本地临时签名；它不安装应用或修改照片。版本号与 build number 在 `scripts/build-app.sh` 中维护。

`compile-app.sh` 使用文件级增量编译，debug 和 release 产物分开存储。模块、依赖和对象文件使用固定输出路径；打包和签名每次执行，并在独立暂存目录完成后替换输出包。

图标使用已批准的源图，保留透明边缘。1024px 画布中的有效内容缩至 860px，四边各保留 82px 空间。缓存同时检查源图、生成脚本和 ICNS 摘要；缓存校验失败会重新生成。不要重画图标或通过运行时覆盖应用图标。

`swift build` 可在完整匹配的 SwiftPM 环境中使用，但仅产生可执行文件，不替代完整 `.app` 打包。窗口、Dock 和图标验证必须使用打包后的应用。

## 自动检查

```sh
zsh scripts/check.sh
```

| 检查入口 | 主要覆盖范围 |
| --- | --- |
| `check-repository.rb`、`test-repository.rb` | 已跟踪 / 暂存文件的隐私规则、敏感文件、路径与资源限制。 |
| `test-distribution.rb` | 版本说明提取、非法标签与缺失版本章节的拒绝行为。 |
| `test-core.sh` | 配对、歧义、日期、地点、复制校验、防覆盖、符号链接和文件身份；筛选导出的目录布局、冲突决策、目标变更与来源保护。 |
| `test-store.sh` | 多相册会话、对比选择、颜色筛选、删除范围、撤销批次、冲突及离线处理。 |
| `test-viewer.sh` | 缩放与视野几何、工具栏、导航和评测面板生命周期。 |
| `test-editor.sh` | 合成图像渲染、参数与曲线、编辑几何、备份及还原、元数据、滤镜库、系统参数撤销 / 还原与批量导入。 |
| `test-marks.sh` | 标记便携性、目录移动、同名替换、旧记录迁移、损坏记录和符号链接拒绝。 |

测试使用临时目录、合成图像及临时预设，不依赖个人照片或滤镜资产。核心测试可通过 `TestHarness.swift` 在缺少完整 XCTest 的 Command Line Tools 环境运行；完整 Xcode 环境也可执行 `swift test`。

`compile-test.sh` 根据编译器版本、参数、直接源文件和脚本内容生成缓存键，并验证缓存可执行文件摘要。缓存只省略编译，每次检查仍执行测试程序。新增直接源文件时必须同步测试编译清单。

```sh
PHOTOHARBOR_CLEAN_BUILD=1 zsh scripts/check.sh
```

上述环境变量强制重新编译全部脚本测试，不清除 App 的增量构建目录。

### 外部预设兼容性检查

可选地将自行获取并有权使用的 XMP 文件放入专用目录，执行：

```sh
PHOTOHARBOR_IMPORT_TEST_PATH=/path/to/test-xmp zsh scripts/test-editor.sh
```

检查在临时库中处理这些文件，不修改应用的实际资产库。默认测试包含大库场景及含损坏项的批次；外部文件用于额外兼容性验证，不应提交仓库。文件解析成功不代表其全部参数均可映射或渲染结果与 Lightroom 一致。

## 隔离 UI 验证

先退出其他拾影实例，避免应用标识和配置选择混淆，然后执行：

```sh
mkdir -p .build/ui-fixtures
xcrun swift scripts/make-fixtures.swift "$PWD/.build/ui-fixtures"
PHOTOHARBOR_STATE_PATH="$PWD/.build/ui-fixtures/state.json" \
  "dist.noindex/拾影.app/Contents/MacOS/PhotoHarbor"
```

占位 ARW 仅验证配对与文件操作，不代表真实 RAW 解码测试。真实 RAW 预览取决于系统对相机型号的支持。UI 截图仅使用合成内容，不对个人照片执行编辑、删除或恢复测试。

大量 LUT 列表可通过以下命令生成隔离夹具：

```sh
xcrun swift scripts/make-lut-fixtures.swift "$PWD/.build/ui-fixtures"
```

生成器创建 240 个合成 LUT，供滚动、搜索、长名称、命名、重命名及编辑选择器同步验证。禁止将输出目录设为个人应用状态目录。

UI 验证应覆盖普通 / 全屏和窄窗口、悬停提示、导航状态、浮层边界、固定侧栏、选择管理，以及编辑后的撤销 / 还原。验证报告记录运行环境、覆盖项与未验证项，不将机器截图或日志纳入源码。

本机评测可使用 `scripts/AssessmentTests.swift` 进行可选实机检查，其依赖为 `Models.swift`、`LibraryService.swift` 和 `PhotoAssessment.swift`，输入应为合成 JPEG。原生模型和 Core Image 需要可用的系统计算服务；受限环境中的失败不能记为通过，也不应将审美结果固定断言为某个分数。

## 安装与发行边界

```sh
zsh scripts/install-app.sh
```

安装前需退出已安装实例。脚本校验应用标识与签名，分阶段替换 `/Applications/拾影.app`，并迁移用户应用程序目录的旧副本。目标目录需可写；脚本不自动提权。

日常开发验证不安装、不修改个人配置。Developer ID 签名、公证、Universal Binary 和自动更新尚未实现，不应将本地临时签名包描述为公证发行版。

## 持续集成

普通 GitHub Actions CI 使用 `macos-26`，执行仓库检查、全部脚本测试和 release 构建。Pull Request 还检查代码变更是否包含 CHANGELOG。该 CI 不安装应用或上传照片。独立的版本标签工作流负责生成并发布 DMG，详见[构建分发指南](DISTRIBUTION.md)。

## 维护与排错

| 情况 | 处理原则 |
| --- | --- |
| 编译器找不到玻璃 API | 核对 SDK 版本及 `xcode-select` 指向。 |
| SwiftPM 工具链不匹配 | 优先使用标准构建脚本；该入口直接调用 Swift 编译器。 |
| 图标或图像服务受限 | 在具备原生图形服务的 macOS 环境重新验证，不绕过校验。 |
| 安装失败 | 检查运行实例、目标权限及应用标识。 |
| 状态模型变更 | 保持旧配置可迁移，增加迁移与失败恢复测试。 |
| 排查个人数据问题 | 使用本地隔离副本；不提交配置、预设、照片或原始日志。 |

功能、文件操作、持久化、构建和测试行为变化必须更新 CHANGELOG，并同步受影响文档。具体提交要求见[贡献指南](../CONTRIBUTING.md)和 [AGENTS.md](../AGENTS.md)。
