# StockBar

StockBar 是一款原生 macOS 菜单栏行情工具，用较少的屏幕空间展示市场行情、持仓盈亏、自选股、指数、汇率和价格预警。

![StockBar App Icon](StockBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png)

## 功能

- 支持 A 股、港股、美股、指数和汇率行情
- 菜单栏滚动、轮播、紧凑和极简显示模式
- 持仓盈亏、自选股与价格预警
- 多数据源优先级、股票搜索与网络状态处理
- 中英文界面、隐私模式、全局快捷键和涨跌配色
- CSV/JSON 导入导出、备份恢复与登录启动

## 系统要求

- macOS 13.0 或更高版本
- Xcode 26 或兼容版本
- Swift 5

## 开发

首次构建会通过 Swift Package Manager 解析 GRDB 6.29.x。

```bash
make build
make test
make run
```

也可以直接打开 `StockBar.xcodeproj` 并运行 `StockBar` scheme。Debug 产品名为 `StockBar-Dev`，Bundle ID 为 `vip.eztool.StockBar.debug`。

常用命令：

```bash
make icons                    # 从品牌母版重新生成全套 AppIcon
make release-build VERSION=0.1.0
make sign                     # 需要在 .env 中配置 DEV_ID
make notarize                 # 需要配置 NOTARY_KEYCHAIN_PROFILE
make dmg
```

## 数据与隐私

StockBar 的数据库和偏好设置与其他应用完全隔离：

- Release 数据目录：`Application Support/StockBar`
- Debug 数据目录：`Application Support/StockBar-Dev`
- 数据库：`stockbar.sqlite`
- UserDefaults 前缀：`stockbar.`

应用会按用户配置访问行情与汇率数据源。项目不包含旧应用的数据迁移逻辑，也不会读取或修改其他应用的数据库和偏好设置。

## 项目文档

- [第三方代码声明](THIRD_PARTY_NOTICES.md)
- [开发代理约定](AGENTS.md)

## 许可证

本仓库包含源自上游项目的 MIT 许可代码，详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。StockBar 项目自身的整体开源许可证尚未确定。
