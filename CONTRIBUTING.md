# 贡献指南

## 开发准备

阅读 [README](README.md)、[架构设计](docs/ARCHITECTURE.md)、[开发指南](docs/DEVELOPMENT.md)及 [AGENTS.md](AGENTS.md)，在独立分支中开展修改。项目使用原生 macOS 框架，标准构建与验证入口位于 `scripts/`。

开发和测试使用合成照片、临时目录及独立状态路径。保持来源保留、防覆盖、配对歧义保护、离线处理、删除前核验及恢复不覆盖等文件操作约束。JPG 覆盖编辑须遵守首次备份和摘要验证协议。

## 变更与文档

功能、修复、文件操作、持久化、构建和测试行为变化必须更新 CHANGELOG。长期文档应描述最终行为与约束，不追加对话记录、个人机器日志或逐次实现过程。

| 变更类型 | 需要维护的文档 |
| --- | --- |
| 产品功能、入口、快捷键或系统要求 | `README.md`。 |
| 模块、状态归属、并发或文件操作规则 | `docs/ARCHITECTURE.md`。 |
| 编辑、渲染、备份及滤镜格式 | `docs/EDITOR.md`。 |
| 标记格式、迁移与生命周期 | `docs/MARKS.md`。 |
| 工具链、构建、测试及 CI | `docs/DEVELOPMENT.md`。 |
| 本机数据、网络行为或公开提交边界 | `docs/PRIVACY.md`。 |

界面文案与格式缩写保持一致。公开 API 实现与其他应用的近似效果应明确区分，不宣称未验证的像素一致性或模型质量。

## 验证要求

```sh
zsh scripts/check.sh
zsh scripts/build-app.sh --release
```

根据修改范围补充有意义的失败与恢复场景。UI 修改还需验证普通 / 全屏、窄窗口、输入与浮层边界；无法完成的原生模型或实机验证应明确记录。

提交前运行 `ruby scripts/check-repository.rb`，并人工检查完整暂存区。不得提交个人照片、状态、路径、预设资产、凭据、机器截图或构建产物。建议使用 GitHub noreply 邮箱。

## 提交与 Pull Request

提交说明应描述具体问题与最终行为。Pull Request 需要提供变更范围、验证结果及已知限制；按复杂度提供必要细节，避免记录无关实现过程。

版本号与 build number 在 `scripts/build-app.sh` 维护。普通提交不要求发布新应用，发行行为发生变化时应同步版本及 CHANGELOG。安装、远程推送、发布或修改他人分支应遵循明确授权，日常开发验证不修改个人应用配置。
