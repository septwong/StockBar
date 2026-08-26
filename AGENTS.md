# StockBar Agent Guide

本文件约束在此仓库中工作的自动化开发代理。用户的明确指令始终优先。

## 项目基线

- 原生 macOS 菜单栏应用，入口为 `StockBarApp + AppDelegate`。
- 使用 `StockBar.xcodeproj`、文件系统同步分组、xcconfig 和 Swift Package Manager；不要引入 XcodeGen。
- 最低部署版本为 macOS 13.0，Swift 5，strict concurrency 为 minimal。
- 主要分层为 `App`、`Domain`、`Data`、`Infrastructure`、`MenuBar`、`Popover`、`Settings`、`Onboarding` 和 `Resources`。
- GRDB 版本范围为 `6.29.0..<7.0.0`，以 `Package.resolved` 为可复现锁定依据。

## 必须保持的产品决策

- Release：`StockBar` / `vip.eztool.StockBar`。
- Debug：`StockBar-Dev` / `vip.eztool.StockBar.debug`。
- 测试 Bundle ID：`vip.eztool.StockBarTests`。
- 数据目录分别使用 `StockBar` 和 `StockBar-Dev`，数据库名为 `stockbar.sqlite`，偏好键使用 `stockbar.` 前缀。
- 不探测、复制或迁移其他应用的数据库及偏好设置。
- 保持 `LSUIElement` 菜单栏应用形态，不默认创建普通主窗口。
- 自动更新使用 Sparkle，稳定版默认定期检查更新，菜单栏与“关于”页面均保留手动检查入口；Debug 构建不自动检查。
- 不修改任何位于当前仓库之外的源项目。

## 品牌资产

- 当前品牌为方案 B：白色圆角磁贴与蓝色圆角柱状 S 标识。
- 图标母版位于 `scripts/assets/StockBarIconMaster.png`，圆角磁贴外部必须具有真实透明通道。
- 修改母版后运行 `make icons`，不要手工遗漏某个 AppIcon 尺寸。
- 菜单栏标识由 `StockBar/MenuBar/MenuBarIcon.swift` 以系统动态单色绘制；Dock 与应用内品牌展示保留清爽蓝 application icon。

## 修改与验证

- 需求或固定决策变化时，同步更新本地 `docs/MIGRATION_PLAN.md` 的状态、验收项和变更记录；`docs/` 已被 Git 忽略。
- 优先使用 `rg` 搜索；保留用户已有且与任务无关的改动。
- 常规验证依次运行：

```bash
make icons
make build
make test
git diff --check
```

- Release 相关变更至少使用 `CODE_SIGNING_ALLOWED=NO` 完成 Release 构建。
- 品牌或身份变更后，搜索旧品牌名称、旧 Bundle ID 和原仓库地址；除迁移历史与第三方声明外不应残留。
- 暂不启用自动 Release workflow；本地发布脚本生成通用二进制、DMG、ZIP、签名 appcast 和校验和。没有 Developer ID 时使用 ad-hoc 签名并明确安装提示。

## 构建产物与工作区整洁

- 开发、测试和重启时保留 `build/dd` 与 `build/SourcePackages`，不日常执行 `make clean`。
- 只清理 Spotlight 中重复的 `StockBar.app` / `StockBar-Dev.app`，当前使用的一份可以保留。
- 发布完成后删除不需要的旧版或备份 DMG/ZIP；不删除 `/Applications/StockBar.app` 或用户数据。

## Git

- 不自动创建提交；仅在用户明确要求时提交。
- 不提交 `build/`、DerivedData、密钥、`.env` 或个人 Xcode 用户状态。
- 提交前检查 staged diff，确保没有把无关用户改动带入提交。
