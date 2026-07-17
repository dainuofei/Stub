
# Stub

> 把每天的待办事项，变成一张值得保存的小票。

Stub 是一款融合极简主义与复古票据美学的 iOS 待办应用。

它希望重新定义数字待办清单：  
不只是完成任务，而是通过热敏打印机将计划变成真实存在的纸质记录，为日常生活增加一点仪式感。

目前 Stub 支持 Paperang P1（喵喵机）热敏打印机，将你的 ToDo List 转化为精致的小票。

## ✨ 特性

- 🧾 复古票据风格的待办清单
- 🌱 极简、无干扰的任务管理体验
- 🖨️ 支持 Paperang 热敏打印机直接打印
- 🔵 基于 CoreBluetooth 的原生 BLE 通信
- 💾 本地优先存储，无需账号
- 🔒 无服务器、无追踪

## 效果展示



## 🛠️ 技术栈

- SwiftUI
- SwiftData
- CoreBluetooth
- iOS 17+

## Paperang 协议研究

Stub 中的 Paperang 通信部分基于官方 App 逆向实现。

目前涉及：

- BLE 特征通信
- 数据帧协议
- 打印数据传输
- 写入流控制
- 设备认证流程

## 🚀 开始使用

### 环境要求

- Xcode 16+
- iOS 17+

### 编译运行

1. 克隆项目

```bash
git clone https://github.com/dainuofei/Stub.git
```

2. 使用 Xcode 打开项目

```
open Stub.xcodeproj
```

3. 选择开发团队并运行到真机

> 由于需要蓝牙连接打印机，请使用真实 iPhone 测试。

### 打包 IPA 导入 AltStore

默认生成未签名 IPA，由 AltStore 在 iPhone 上完成签名：

```sh
./scripts/build_ipa.sh
```

生成文件为 `dist/Stub.ipa`。在 iPhone 的“文件”App 中找到它，选择“共享”并发送到 AltStore。

如果希望由 Xcode 自动签名并导出开发版 IPA：

```sh
SIGNING_MODE=auto ./scripts/build_ipa.sh
```

脚本会自动选择 `/Applications/Xcode.app`，也可以通过 `DEVELOPER_DIR` 指定其他 Xcode。

## 💡 设计理念

现代软件让记录变得越来越容易，但也让信息越来越容易被遗忘。

Stub 希望通过一个简单的小票，让数字计划重新拥有实体感：

> 写下它，打印它，然后开始行动。

## 为什么叫 Stub？

Stub 原意是「票根、存根」。

它代表一张被留下来的小纸片：
记录过去，也提醒未来。
