# 构建分发与版本发布

## 下载与安装

安装包在仓库的 [GitHub Releases](https://github.com/ly-huang/photo-harbor/releases) 提供。选择 `PhotoHarbor-<版本>-macos-arm64.dmg`，打开后将「拾影.app」拖入「Applications」。升级前退出运行实例，照片及应用状态保留。

分发目标为 Apple Silicon（M 系列）Mac，最低 macOS 14。Intel 及 Universal Binary 暂未发布。审美评分需 macOS 15+，系统玻璃效果需 macOS 26+。

当前安装包采用本地临时签名，未经 Developer ID 签名和 Apple 公证，其他 Mac 可能阻止首次打开。请核对下载来源，并参考 [Apple 安全打开应用说明](https://support.apple.com/102445) 自行判断。安装包不移除隔离属性，也不修改系统安全设置。

同一目录下载 DMG 和 `SHA256SUMS.txt` 后，可验证文件完整性：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

SHA-256 校验用于发现损坏或内容不一致，不替代开发者身份认证、公证或安全审查。

## 自动发布流程

`.github/workflows/release.yml` 在推送稳定版本标签 `v<主版本>.<次版本>.<修订版本>` 时触发：

1. 在 `macos-26` Apple Silicon runner 检查标签和架构。
2. 执行完整检查及 release 构建。
3. 验证应用标识、版本与签名，生成只读压缩 DMG 和校验文件。
4. 从 CHANGELOG 中提取对应版本说明，并附安装与签名状态说明。
5. 将通过验证的文件交给发布任务；该任务再次核验 SHA-256，创建草稿 Release、上传资产，成功后公开。

构建任务只有仓库读取权限；发布任务使用 GitHub 自动提供的 `GITHUB_TOKEN` 获得当前仓库的 `contents: write` 权限，无需个人访问令牌。普通 main / PR CI 不发布安装包。

DMG 仅包含应用、Applications 快捷入口、MIT 许可证及安装说明，不打包源码目录、个人配置、照片、预设或本地缓存。Actions 中间产物保留 7 天，正式下载使用 Release 附件。

## 维护者发布步骤

1. 更新 `scripts/build-app.sh` 中的版本号与 build number。
2. 在 CHANGELOG 添加同版本章节，并同步受影响文档。
3. 完成检查、release 构建及必要实机验证后提交并推送。
4. 在目标提交上创建版本标签，例如：

```sh
git tag -a v1.1.2 -m 'Photo Harbor 1.1.2'
git push origin v1.1.2
```

标签必须与应用 `CFBundleShortVersionString` 相同；版本不匹配、架构错误或检查失败时不会发布。不要移动已经公开的版本标签。发布前需确认 CI 工作流来自已审核的源码。

发布任务不覆盖同名 Release。失败可能留下草稿；应检查日志和已有附件，再由维护者决定清理草稿后重跑。已公开版本的修复使用新版本与新标签。

## 本地打包与验证

在 Apple Silicon Mac 上执行：

```sh
zsh scripts/build-app.sh --release
RELEASE_TAG=v1.1.2 zsh scripts/package-dmg.sh
ruby scripts/release-notes.rb v1.1.2
```

打包脚本默认读取 `dist.noindex/拾影.app`，输出到 `dist.noindex/release/`。可用第一个参数指定应用包，第二个参数指定独立输出目录。已有同名 DMG 或校验文件时拒绝覆盖。

本地验收应检查 DMG 完整性、只读挂载、应用签名、版本和 arm64 架构、Applications 快捷入口以及安装说明。真实下载后的 Gatekeeper 行为需在独立测试 Mac 上验收，不应将本机构建可启动等同于通过公证。

## Developer ID 与公证

当前工作流不接收 Apple 签名或公证凭据。若需正式签名分发，应另行实现临时钥匙串、Developer ID 签名、Hardened Runtime、公证提交与票据装订，并进行独立下载验证。证书与公证凭据应保存在 GitHub Actions Secrets，仅向可信发布任务提供，不提交源码或回显至日志。

当前 App 仍为临时签名构建；配置 Secrets 本身不会自动启用尚未实现的签名流程。
