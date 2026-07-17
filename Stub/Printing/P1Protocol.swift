import CoreBluetooth
import Foundation

/// P1 在 FF01 上通知的协议帧。
///
/// 帧的线格式为：`02 | command | sequence | payloadLength(UInt16 LE) |
/// payload | crc32(UInt32 LE) | 03`。CRC 只覆盖 payload，seed 是当前会话密钥。
struct P1Frame: Equatable {
    let command: UInt8
    let sequence: UInt8
    let payload: Data
}

enum PowerOffDuration: Hashable, Identifiable {
    case never
    case minutes(Int)
    case unknown(UInt16)

    static let presets: [PowerOffDuration] = [
        .minutes(3), .minutes(10), .minutes(30), .minutes(60),
        .minutes(180), .minutes(300), .minutes(600), .never
    ]

    var id: String {
        switch self {
        case .never: return "never"
        case .minutes(let value): return "minutes-\(value)"
        case .unknown(let value): return "unknown-\(value)"
        }
    }

    var label: String {
        switch self {
        case .never: return "不自动关闭"
        case .minutes(60): return "1 小时"
        case .minutes(180): return "3 小时"
        case .minutes(300): return "5 小时"
        case .minutes(600): return "10 小时"
        case .minutes(let value): return "\(value) 分钟"
        case .unknown(let value): return "设备自定义值（\(value)）"
        }
    }

    var rawValue: UInt16 {
        switch self {
        case .never: return 0
        // P1 固件保存的是秒，界面为了易用性显示为分钟/小时。
        case .minutes(let value): return UInt16(clamping: value * 60)
        case .unknown(let value): return value
        }
    }

    var isPreset: Bool {
        switch self {
        case .never, .minutes: return true
        case .unknown: return false
        }
    }

    static func from(rawValue: UInt16) -> PowerOffDuration {
        guard rawValue != 0 else { return .never }
        guard rawValue % 60 == 0 else { return .unknown(rawValue) }
        return minutesOrUnknown(Int(rawValue / 60), rawValue: rawValue)
    }

    private static func minutesOrUnknown(_ minutes: Int, rawValue: UInt16) -> PowerOffDuration {
        let known = presets.compactMap { preset -> PowerOffDuration? in
            guard case .minutes(let presetMinutes) = preset else { return nil }
            return presetMinutes == minutes ? preset : nil
        }
        return known.first ?? .unknown(rawValue)
    }
}

struct P1DeviceInfo: Equatable {
    let batteryPercent: Int?
    let powerOff: PowerOffDuration
}

enum P1Protocol {
    // 以下常量来自 Paperang P1 的官方 App 抓包和可重复的真机验证。
    // P1 的图像不是 PNG/JPEG，而是 1 bit 热敏点阵：384 点宽、每行 48 字节。
    static let widthDots = 384
    static let bytesPerRow = 48
    static let rowsPerPacket = 21
    static let imagePayloadBytes = bytesPerRow * rowsPerPacket

    // FF03 会先告知设备接受的写入块大小；P1 实测固定为 100 字节。
    static let bleChunkBytes = 100

    // 设置 CRC 会话密钥时使用的固定种子；之后每个会话会再生成随机 sessionKey。
    static let standardCRCKey: UInt32 = 0x35769521
    // 协议参考实现使用 280（约 5 mm）；App 实际使用稍短的 224（约 4 mm）。
    static let defaultFeedLines = 280
    // P1 走纸单位约为 56 units/mm。
    static let appFeedLines = 224

    // P1 不在系统蓝牙设置中配对，App 通过 FF00 服务主动发现并连接。
    static let service = CBUUID(string: "0000FF00-0000-1000-8000-00805F9B34FB")
    // FF01：协议响应通知；FF02：无响应写入；FF03：写入流控通知。
    static let ff01 = CBUUID(string: "0000FF01-0000-1000-8000-00805F9B34FB")
    static let ff02 = CBUUID(string: "0000FF02-0000-1000-8000-00805F9B34FB")
    static let ff03 = CBUUID(string: "0000FF03-0000-1000-8000-00805F9B34FB")
    // 部分 P1 固件还需要订阅这个辅助通知特征，完成初始化后才能稳定打印。
    static let auxService = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    static let auxNotify = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")
    static let auxWrite = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")

    // 官方 App 在协议帧之前发送的 33 字节认证前导包。
    // 这是从 P1 官方 App 的 BLE 日志中捕获并验证的协议常量，不是账号密码或用户指纹。
    static let capturedAuthPacket = Data(hex: "a50118000117011300011000335364584e3362593271546d6f6a7a7a10cbe4775a")

    enum Command {
        // 命令号来自抓包；0x00 的 payload 是 384 点位图数据。
        static let printData: UInt8 = 0x00
        static let setCRCKey: UInt8 = 0x18
        static let setDensity: UInt8 = 0x19
        static let feedLine: UInt8 = 0x1A
        static let setPaperType: UInt8 = 0x2C
        static let setPrintMode: UInt8 = 0x39
        static let getBatteryStatus: UInt8 = 0x10
        static let setPowerOffTime: UInt8 = 0x1E
        static let getPowerOffTime: UInt8 = 0x1F
    }

    // 请求命令与响应命令并不总是相同，例如电量 0x10 的响应是 0x11，
    // 自动关机读取/设置最终都返回 0x20。
    static let replyCommands: [UInt8: UInt8] = [
        0x0A: 0x0B, 0x30: 0x31, 0x1C: 0x1D,
        0x10: 0x11, 0x1F: 0x20, 0x04: 0x05,
        0x1E: 0x20,
    ]

    static func crc32(_ data: Data, seed: UInt32) -> UInt32 {
        // 这是 P1 使用的 CRC32 变体：初始值和最终值均与 seed 异或，
        // 多项式为反射形式 0xEDB88320。不能直接替换成无 seed 的标准 CRC32。
        var crc = seed ^ 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func frame(command: UInt8, sequence: UInt8, payload: Data, seed: UInt32) -> Data {
        // 序号在一次连接内单调递增；响应帧会复用请求帧的序号，
        // 因此等待响应时必须同时匹配 command 和 sequence。
        var result = Data([0x02, command, sequence])
        result.append(contentsOf: UInt16(payload.count).littleEndianBytes)
        result.append(payload)
        result.append(contentsOf: crc32(payload, seed: seed).littleEndianBytes)
        result.append(0x03)
        return result
    }

    static func queryPayload() -> Data { Data([0x01]) }

    static func powerOffPayload(_ duration: PowerOffDuration) -> Data {
        Data(duration.rawValue.littleEndianBytes)
    }

    static func uint16Payload(_ payload: Data) -> UInt16? {
        guard payload.count >= 2 else { return nil }
        return UInt16(payload[0]) | (UInt16(payload[1]) << 8)
    }

    static func initializationWrites(sessionKey: UInt32, density: UInt8 = 95) -> [Data] {
        // 初始化顺序是官方 App 抓包得到的关键部分：先发送认证前导，
        // 再注册会话 CRC key，最后依次读取设备状态并设置热敏浓度。
        let registration = (sessionKey ^ standardCRCKey).littleEndianBytes
        let controls: [(UInt8, Data)] = [
            (0x0A, Data([0x01])), (0x30, Data([0x01])), (0x1C, Data([0x01])),
            (0x10, Data([0x01])), (0x1F, Data([0x01])), (0x04, Data([0x01])),
        ]
        var writes = [capturedAuthPacket]
        writes.append(frame(command: Command.setCRCKey, sequence: 1, payload: Data(registration), seed: standardCRCKey))
        for (offset, control) in controls.enumerated() {
            writes.append(frame(command: control.0, sequence: UInt8(offset + 2), payload: control.1, seed: sessionKey))
        }
        writes.append(frame(command: Command.setDensity, sequence: 8, payload: Data([density]), seed: sessionKey))
        return writes
    }

    static func printWrites(
        raster: Data,
        sessionKey: UInt32,
        density: UInt8 = 95,
        feedLines: UInt16 = UInt16(defaultFeedLines),
        chunkSize: Int = bleChunkBytes
    ) -> [Data] {
        // 图片发送顺序：设置浓度（重复两次）→纸张类型→预走纸→打印模式→
        // 图像帧→最终走纸。整个协议流再按 FF03 宣布的 100 字节切块。
        precondition(!raster.isEmpty && raster.count % bytesPerRow == 0)
        var sequence: UInt8 = 9
        let density1 = frame(command: Command.setDensity, sequence: sequence, payload: Data([density]), seed: sessionKey)
        sequence &+= 1
        let density2 = frame(command: Command.setDensity, sequence: sequence, payload: Data([density]), seed: sessionKey)
        sequence &+= 1
        let paper = frame(command: Command.setPaperType, sequence: sequence, payload: Data([0, 0]), seed: sessionKey)
        sequence &+= 1
        let prefeed = frame(command: Command.feedLine, sequence: sequence, payload: Data([0, 0]), seed: sessionKey)
        sequence &+= 1

        var images = Data()
        for offset in stride(from: 0, to: raster.count, by: imagePayloadBytes) {
            let end = min(offset + imagePayloadBytes, raster.count)
            images.append(frame(command: Command.printData, sequence: sequence, payload: raster.subdata(in: offset..<end), seed: sessionKey))
            sequence &+= 1
        }
        let mode = frame(command: Command.setPrintMode, sequence: sequence, payload: Data([0x04]), seed: sessionKey)
        sequence &+= 1
        let finalFeed = frame(command: Command.feedLine, sequence: sequence, payload: Data(feedLines.littleEndianBytes), seed: sessionKey)

        var bulk = Data()
        bulk.append(paper)
        bulk.append(prefeed)
        bulk.append(mode)
        bulk.append(images)
        bulk.append(finalFeed)

        var writes = [density1, density2]
        var offset = 0
        while offset < bulk.count {
            let end = min(offset + chunkSize, bulk.count)
            writes.append(bulk.subdata(in: offset..<end))
            offset = end
        }
        return writes
    }

    static func parseFrames(_ data: Data) -> (frames: [P1Frame], trailing: Data) {
        // BLE 通知可能把一帧拆成多次，也可能一次包含多帧。
        // 解析器保留未完成的 trailing，下一次通知到达时继续拼接。
        var frames: [P1Frame] = []
        var offset = 0
        while offset < data.count {
            guard let start = data[offset...].firstIndex(of: 0x02) else { return (frames, Data()) }
            let startOffset = data.distance(from: data.startIndex, to: start)
            guard data.count - startOffset >= 10 else { return (frames, data.subdata(in: startOffset..<data.count)) }
            let command = data[startOffset + 1]
            let sequence = data[startOffset + 2]
            let length = Int(data[startOffset + 3]) | (Int(data[startOffset + 4]) << 8)
            let frameLength = length + 10
            guard data.count - startOffset >= frameLength else { return (frames, data.subdata(in: startOffset..<data.count)) }
            let endOffset = startOffset + frameLength - 1
            guard data[endOffset] == 0x03 else { offset = startOffset + 1; continue }
            frames.append(P1Frame(command: command, sequence: sequence, payload: data.subdata(in: (startOffset + 5)..<(startOffset + 5 + length))))
            offset = startOffset + frameLength
        }
        return (frames, Data())
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
    }
}
