# 拾影 · Photo Harbor

原生 macOS 相机照片整理工具。JPG 与 RAW 可以存放在不同目录，按文件配对浏览、筛选和管理。使用 SwiftUI / AppKit，无第三方运行时依赖。

## 功能

- **打开相册**：原位管理已有 JPG / RAW 目录，至少选择一种格式，支持同时打开多个相册。
- **导入拍摄**：按 `YYYYMMDD_地点` 分类复制；地点可选，自动探测失败时使用「未知」。两种格式可独立选择存放位置；选择同一位置时拆为 JPG、RAW 子目录。
- **筛片**：大图全屏、鼠标位置缩放、拖动平移、可隐藏导航、2–4 张对比、已选照片气泡与清空选择。
- **本机评测**：Apple Vision 审美参考、相似距离、细节与亮度指标。评分是辅助参考，不是照片优劣的客观结论。
- **成对删除**：确认后 JPG / RAW 一起移入废纸篓；按相册、操作批次撤销。

## 从源码构建

需要 Mac，以及 **Xcode 26+ 或带 macOS 26+ SDK 的 Command Line Tools**。Swift 工具链需支持 Swift 6 的 Package manifest；源码以 Swift 5 模式编译。部署目标为 macOS 14，审美评分需要 macOS 15+，系统玻璃效果需要 macOS 26+。旧系统回退普通材质；旧系统及 Intel Mac 尚未全面实机验证。

```sh
xcode-select --install   # 已有合适工具链可跳过
zsh scripts/check.sh
zsh scripts/build-app.sh
open "dist.noindex/拾影.app"
```

`dist.noindex/拾影.app` 是本地临时签名构建，无需开发者证书或密钥。默认构建当前 Mac 架构，未生成通用二进制。

安装到系统应用程序目录前先退出 App：

```sh
zsh scripts/install-app.sh
open "/Applications/拾影.app"
```

安装脚本验证应用标识与签名，并迁移用户 Applications 中的旧副本。目标目录不可写时，请通过系统授权或由有权限的用户运行；脚本不会自动使用 sudo。源码构建与测试不需要安装 App。

## 常用操作

| 操作 | 按键或入口 |
| --- | --- |
| 打开相册 / 导入照片 | ⌘O / ⌘I |
| 查看大图 | 双击或 Return |
| 标记 / 取消待删除 | ⌫（退格删除键） |
| 切换照片 | ← / → |
| 适应窗口 | F / ⌘0，或右键图片 |
| 平移 | 左键拖动，或按住空格移动鼠标 |
| 固定 / 自动隐藏工具栏 | H |
| 选择对比 | 右键加入对比，最多四张 |
| 管理选择 | 「对比所选图片」旁的「已选照片」气泡 |
| 撤销最近删除 | ⌘Z；历史按钮可选其他批次 |

## 开发文档

- [开发与验证](docs/DEVELOPMENT.md)：目录、测试、独立测试数据、打包及常见问题。
- [结构与行为约定](docs/ARCHITECTURE.md)：模块、配对、文件操作、窗口和状态生命周期。
- [隐私与仓库边界](docs/PRIVACY.md)：本机数据、网络行为、公开提交检查。
- [变更记录](CHANGELOG.md)：当前版本与后续更新。
- [贡献约定](CONTRIBUTING.md)及 [Agent 工作约定](AGENTS.md)：功能变更必须同步文档。

真实照片、状态文件、设计草稿和本机验证记录不属于仓库内容。正式图标源图位于 `assets/AppIcon/master.png`；其他资源在构建时生成。代码与随仓库发布的图标采用 [MIT](LICENSE) 许可证。
