# 贡献指南

1. 阅读 README、结构文档及 AGENTS，建立独立分支。
2. 用合成照片和独立状态路径开发，保留文件操作的安全不变量。
3. 修改后运行 `zsh scripts/check.sh` 与 `zsh scripts/build-app.sh`。UI 改动补充普通 / 全屏实机检查；原生模型失败要记录，不能伪称通过。
4. 每次功能、修复、构建或持久化变化更新 CHANGELOG。快捷键 / 用户流程改 README，模块 / 状态语义改 ARCHITECTURE，工具链 / 测试改 DEVELOPMENT，网络 / 数据行为改 PRIVACY。
5. 提交前审阅全部暂存内容并运行仓库检查，禁止真实照片、个人路径与凭据。使用 noreply 提交邮箱。
6. PR 说明问题、最终行为、验证及限制。不要自动安装、发布或推送他人分支；按明确授权操作。

版本号与 build number 在构建脚本维护；不强制每次提交都发布新 App，但发行行为变化时同步版本和 CHANGELOG。不要把个人设计 skill、机器日志或未清理的历史记录加入仓库。
