# Stub 当前上下文

> 最后更新：2026-07-19。本文件记录当前工作状态和继续开发所需信息；稳定架构见 `architecture.md`，长期决策见 `decisions.md`。

## 项目与环境

- 本地仓库：`/Users/freopen/Code/paperang-todo`
- GitHub：`git@github.com:dainuofei/Stub.git`
- 主分支：`main`
- App 名称 / scheme / product：`Stub`
- Bundle ID：`com.freopen.Stub`
- 目标平台：iOS 17+
- 主要真机：iPhone 17 Pro
- 打印机：Paperang P1，BLE 广播名为 `Paperang`
- 安装方式：Xcode 真机调试或未签名 IPA + AltStore；用户有经常开机的 MacBook 用于 AltServer 自动续签。

## 当前产品状态

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

蓝牙打印不依赖官方 App 账号、用户指纹或某一台设备的私有身份。协议来自官方 App 抓包和真机验证。

## 当前未验收工作

工作树中存在未提交修改，继续开发前必须先运行 `git status --short`，不得重置或覆盖：

- `Stub/Printing/RasterRenderer.swift`
- `StubTests/P1ProtocolTests.swift`

这些修改用于解决“App 预览与打印/相册保存的坐标不一致”：

- 渲染边距由 20pt 改为与 SwiftUI 相同的 18pt。
- 进度列宽由 132pt 改为与 `TaskProgressView` 相同的 122pt。
- 口号黑条使用 10pt 内边距、白色 14pt semibold 文本。
- 分组副标题和进度百分比共享 `width - margin` 右边界。
- 口号按字体行高在黑条内垂直居中。
- 勾选框、任务名、详情和进度列共享 32pt 任务行中心。
- 测试增加边距、列宽和任务列中心线断言。

当前状态：本地构建成功，10 项模拟器测试通过，但用户尚未对最新图片/纸条的水平坐标及垂直居中效果进行最终验收。因此不能 commit 或 push。

## 近期问题的根因

屏幕收据由 SwiftUI 排版，打印与相册由 `RasterRenderer` 手工绘制。此前两边使用不同的边距和列宽，造成 `Nothing fancy.`、任务文字、进度列在输出中偏移；手工文字绘制还默认从矩形顶边开始，未复现 SwiftUI 的垂直居中。第一次修复曾将黑色文字绘制到黑条上，已经改回白字；这类视觉改动必须用实际输出验收。

若最新坐标仍不一致，不应继续凭感觉微调。应同时获取：

1. 同一份数据的 App 截图。
2. 同一份数据保存到相册的图片。
3. 必要时对应打印纸照片。

用相同内容比较元素的归一化横坐标，再修改共享布局常量。长期建议抽出一个 `ReceiptLayout` 结构，让 SwiftUI 和 `RasterRenderer` 都引用同一组尺寸。

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

1. 阅读 `AGENTS.md`，遵守“先验收、后提交”。
2. 阅读本目录三个文档并检查 `git status` / `git diff`。
3. 保留任何未验收修改，不得用 reset/checkout 清理。
4. 修改打印布局时同时检查屏幕、相册与纸条。
5. 修改 P1 协议时对照 `protocol-reference/`、现有单元测试和真机行为。
6. 构建与测试通过后只交给用户验收；用户明确确认后才 commit/push/release。
