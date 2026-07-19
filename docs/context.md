# Stub 当前上下文

> 最后更新：2026-07-19。本文件只记录当前工作状态和接手信息；稳定架构见 `architecture.md`，长期决策见 `decisions.md`，协作流程见根目录 `AGENTS.md`。

## 项目与环境

- 本地仓库：`/Users/freopen/Code/paperang-todo`
- 主分支：`main`
- 主要真机：iPhone 17 Pro
- 打印机：Paperang P1，BLE 广播名为 `Paperang`
- 安装方式：Xcode 真机调试或未签名 IPA + AltStore；用户有经常开机的 MacBook 用于 AltServer 自动续签。

## 当前可用基线

已经实现并在此前真机验证过：

- SwiftUI 收据风格 Todo 编辑器和 SwiftData 本地保存。
- 三个分组：T1 / MUST DO、T2 / TRY TODO、Routine / Habits。
- 添加、删除、编辑、排序任务以及时长/次数字段。
- 行内进度条、Slider 编辑进度、勾选自动到 100%。
- 每日自动清空任务、系统日期、随机默认口号。
- Paperang P1 自动扫描、连接、认证、初始化、流控和直接打印。
- 打印取消、电量读取、自动关机读取/设置。
- 保存与打印内容同源的 3 倍高分辨率收据到相册。
- AltStore IPA 脚本和 GitHub Actions Release。

打印渲染的最新已提交基线为 `51e1f20`，`main` 与 `origin/main` 一致。该提交已包含边距、进度列、口号和任务行对齐修正及相应测试，不再属于当前未提交工作。

## 已知技术债

屏幕收据由 SwiftUI 排版，打印与相册由 `RasterRenderer` 手工绘制，存在两套布局逐渐漂移的风险。长期建议抽出 `ReceiptLayout` 共享几何常量；在此之前，修改打印布局时应对比同一数据的 App 截图、相册图和必要时的打印纸照片。

## 常用验证命令

构建测试目标：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build-for-testing -quiet \
  -project Stub.xcodeproj \
  -scheme Stub \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

运行测试：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project Stub.xcodeproj \
  -scheme Stub \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

构建 AltStore IPA：

```sh
./scripts/build_ipa.sh
```

## 继续开发检查清单

1. 如继续调整界面，保留当前工作树修改并重新运行必要的构建和测试。
2. 修改 P1 协议时对照 `protocol-reference/`、现有单元测试和真机行为。
