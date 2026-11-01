# Agent 工作约定

- 这是原生 macOS SwiftUI / AppKit 项目，先读 README 和 docs/ARCHITECTURE.md。
- 构建：`zsh scripts/build-app.sh`；检查：`zsh scripts/check.sh`。脚本是独立于个人配置的标准入口。
- 任何功能、修复、构建、状态模型或测试行为变更都必须更新 CHANGELOG.md，并同步对应 README / docs。PR CI 会检查代码变更是否附带 CHANGELOG。
- 不读取个人照片作为测试夹具。UI 验证使用 `make-fixtures.swift` 和 `PHOTOHARBOR_STATE_PATH`。禁止提交照片、状态、日志、个人绝对路径、密钥和访问令牌。
- 提交前运行 `ruby scripts/check-repository.rb` 并人工审阅 Git 暂存区。检查结果只显示规则和路径，不打印疑似密钥。
- `.build/`、`dist.noindex/`、`archive.local/` 是本地产物，不作为源码依赖，不提交。
- 文件操作必须保持：来源保留、目标不覆盖、歧义不删除、离线不当空库、删除前重新核验、恢复不覆盖。改动这些行为需先补相应失败场景测试。
- 不重画已批准图标，不引入运行时图标覆盖。图标中间文件生成于 `.build/`。
- 默认安装位置是 `/Applications/拾影.app`；安装需退出运行实例并验证签名。普通开发验证不安装，不修改个人配置。不在没有明确请求时创建远程仓库、推送、发布或发消息。
