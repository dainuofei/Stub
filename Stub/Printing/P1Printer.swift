import CoreBluetooth
import Combine
import Foundation

enum P1PrinterError: LocalizedError {
    case bluetoothUnavailable
    case scanTimeout
    case connectionFailed
    case missingCharacteristics
    case flowTimeout
    case responseTimeout(UInt8, UInt8)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "请在系统设置中打开蓝牙权限。"
        case .scanTimeout: return "附近没有发现喵喵机 P1，请确认设备已开机。"
        case .connectionFailed: return "连接喵喵机失败，请重试。"
        case .missingCharacteristics: return "喵喵机协议特征不完整。"
        case .flowTimeout: return "喵喵机没有响应流控信号。"
        case .responseTimeout(let command, let sequence):
            return String(format: "喵喵机响应超时（命令 0x%02X，序号 %d）。", command, sequence)
        case .disconnected: return "打印过程中喵喵机断开了。"
        }
    }
}

/// Paperang P1 的 CoreBluetooth 驱动。
///
/// 连接流程必须在 App 内完成：扫描名称为 Paperang 的 BLE 外设，订阅
/// FF01/FF03/辅助通知，再通过 FF02 进行无响应写入。P1 不需要也不应该
/// 先在 iOS“设置 > 蓝牙”里配对。
@MainActor
final class P1Printer: NSObject, ObservableObject {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    // FF02 是唯一的写入通道；FF01 收协议响应，FF03 负责写入 credit 流控。
    private var writeCharacteristic: CBCharacteristic?
    private var replyCharacteristic: CBCharacteristic?
    private var flowCharacteristic: CBCharacteristic?
    private var auxNotifyCharacteristic: CBCharacteristic?

    // 这些 continuation 把 CoreBluetooth 的回调式事件桥接成 async/await。
    // cancel() 必须逐一唤醒它们，否则取消打印后任务会悬挂。
    private var centralReady: CheckedContinuation<Void, Error>?
    private var scanContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var characteristicsContinuation: CheckedContinuation<Void, Error>?
    private var flowReadyContinuation: CheckedContinuation<Void, Error>?
    private var notifyCount = 0
    // FF03 的 0x02 响应会告知块大小，0x01 响应会发放可写 credit。
    private var flowChunkSize: Int?
    private var flowCredits = 0
    private var creditWaiters: [CheckedContinuation<Void, Never>] = []
    // FF01 通知是字节流，不保证按协议帧边界到达。
    private var replyBuffer = Data()
    private var receivedFrames: [P1Frame] = []
    private var replyWaiters: [String: CheckedContinuation<P1Frame, Error>] = [:]
    private var isCancelled = false

    /// 连接、初始化、按 credit 发送图像，最后等待最终走纸响应。
    func print(raster: Data, density: UInt8 = 95, feedLines: UInt16 = UInt16(P1Protocol.defaultFeedLines)) async throws {
        try await connect()
        defer { disconnect() }
        let sessionKey = UInt32.random(in: 0...UInt32.max)
        _ = try await initialize(sessionKey: sessionKey, density: density)
        let writes = P1Protocol.printWrites(raster: raster, sessionKey: sessionKey, density: density, feedLines: feedLines, chunkSize: P1Protocol.bleChunkBytes)
        for packet in writes {
            try await writeWithCredit(packet)
        }
        let finalSequence = finalFeedSequence(for: writes)
        _ = try await waitForReply(command: P1Protocol.Command.feedLine, sequence: finalSequence)
    }

    func readDeviceInfo() async throws -> P1DeviceInfo {
        try await connect()
        defer { disconnect() }
        let sessionKey = UInt32.random(in: 0...UInt32.max)
        let result = try await initialize(sessionKey: sessionKey)
        return P1DeviceInfo(
            batteryPercent: result.batteryPercent,
            powerOff: PowerOffDuration.from(rawValue: result.powerOffRaw ?? 0)
        )
    }

    func setPowerOffTime(_ duration: PowerOffDuration) async throws -> P1DeviceInfo {
        try await connect()
        defer { disconnect() }
        let sessionKey = UInt32.random(in: 0...UInt32.max)
        let result = try await initialize(sessionKey: sessionKey)

        // 设置 0x1E 的响应在部分 P1 固件上会丢失，不能把它当成成功判据；
        // 写入后重新读取 0x1F，并以 0x20 的回读值确认设置结果。
        let setSequence: UInt8 = 9
        let setFrame = P1Protocol.frame(
            command: P1Protocol.Command.setPowerOffTime,
            sequence: setSequence,
            payload: P1Protocol.powerOffPayload(duration),
            seed: sessionKey
        )
        try await writeWithCredit(setFrame)

        let querySequence: UInt8 = 10
        let queryFrame = P1Protocol.frame(
            command: P1Protocol.Command.getPowerOffTime,
            sequence: querySequence,
            payload: P1Protocol.queryPayload(),
            seed: sessionKey
        )
        try await writeWithCredit(queryFrame)
        let queryReply = try await waitForReply(command: P1Protocol.Command.getPowerOffTime, sequence: querySequence)
        let confirmedRaw = P1Protocol.uint16Payload(queryReply.payload) ?? duration.rawValue

        return P1DeviceInfo(
            batteryPercent: result.batteryPercent,
            powerOff: PowerOffDuration.from(rawValue: confirmedRaw)
        )
    }

    func cancel() {
        // 无响应写入已经交给 BLE 控制器的数据无法撤回，但取消后不再发送新帧。
        // 同时停止扫描、断开外设并清理所有等待中的 continuation。
        isCancelled = true
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }

        centralReady?.resume(throwing: CancellationError())
        centralReady = nil
        scanContinuation?.resume(throwing: CancellationError())
        scanContinuation = nil
        connectionContinuation?.resume(throwing: CancellationError())
        connectionContinuation = nil
        characteristicsContinuation?.resume(throwing: CancellationError())
        characteristicsContinuation = nil
        flowReadyContinuation?.resume(throwing: CancellationError())
        flowReadyContinuation = nil
        replyWaiters.values.forEach { $0.resume(throwing: CancellationError()) }
        replyWaiters.removeAll()
        creditWaiters.forEach { $0.resume() }
        creditWaiters.removeAll()
    }

    func connect() async throws {
        // 官方 App 的连接顺序：等待蓝牙可用 → 按名称扫描 → 连接 →
        // 发现 FF00/辅助服务 → 订阅三个通知 → 等待 FF03 报告 100 字节块大小。
        isCancelled = false
        central = CBCentralManager(delegate: self, queue: .main)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if central.state == .poweredOn {
                continuation.resume()
            } else {
                centralReady = continuation
            }
        }

        peripheral = try await scan()
        peripheral?.delegate = self
        guard let peripheral else { throw P1PrinterError.connectionFailed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectionContinuation = continuation
            central.connect(peripheral, options: nil)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristicsContinuation = continuation
            peripheral.discoverServices([P1Protocol.service, P1Protocol.auxService])
        }
        try await waitForFlowReady()
        guard let flowChunkSize, flowChunkSize == P1Protocol.bleChunkBytes else {
            throw P1PrinterError.flowTimeout
        }
    }

    func disconnect() {
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        writeCharacteristic = nil
        replyCharacteristic = nil
        flowCharacteristic = nil
        auxNotifyCharacteristic = nil
        flowCredits = 0
        flowChunkSize = nil
        creditWaiters.forEach { $0.resume() }
        creditWaiters.removeAll()
        isCancelled = false
    }

    private func scan() async throws -> CBPeripheral {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheral, Error>) in
            scanContinuation = continuation
            // P1 不总是在广播包中携带 FF00，因此不能只按服务 UUID 扫描；
            // 先扫描全部 BLE 外设，再按本地名称 Paperang 过滤，和官方 App 一致。
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finishScanWithTimeout()
            }
        }
    }

    private func finishScanWithTimeout() {
        guard let scanContinuation else { return }
        self.scanContinuation = nil
        central.stopScan()
        scanContinuation.resume(throwing: P1PrinterError.scanTimeout)
    }

    private func waitForFlowReady() async throws {
        if flowChunkSize != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flowReadyContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.timeoutFlowReady()
            }
        }
    }

    private func timeoutFlowReady() {
        guard let continuation = flowReadyContinuation else { return }
        flowReadyContinuation = nil
        continuation.resume(throwing: P1PrinterError.flowTimeout)
    }

    private func initialize(sessionKey: UInt32, density: UInt8 = 95) async throws -> (batteryPercent: Int?, powerOffRaw: UInt16?) {
        // 初始化中的每一条控制帧都需要等待对应响应，避免旧设备在前一条
        // 命令尚未处理完时丢弃下一条。响应由 command + sequence 双重匹配。
        let writes = P1Protocol.initializationWrites(sessionKey: sessionKey, density: density)
        try await writeWithCredit(writes[0])
        var batteryPercent: Int?
        var powerOffRaw: UInt16?
        let commands: [(UInt8, UInt8)] = [
            (P1Protocol.Command.setCRCKey, 1),
            (0x0A, 2), (0x30, 3), (0x1C, 4),
            (0x10, 5), (0x1F, 6), (0x04, 7),
            (P1Protocol.Command.setDensity, 8),
        ]
        for (packet, command) in zip(writes.dropFirst(), commands) {
            try await writeWithCredit(packet)
            let reply = try await waitForReply(command: command.0, sequence: command.1)
            if command.0 == P1Protocol.Command.getBatteryStatus {
                batteryPercent = reply.payload.first.map(Int.init)
            } else if command.0 == P1Protocol.Command.getPowerOffTime {
                powerOffRaw = P1Protocol.uint16Payload(reply.payload)
            }
        }
        return (batteryPercent, powerOffRaw)
    }

    private func writeWithCredit(_ data: Data) async throws {
        guard let peripheral, let writeCharacteristic else { throw P1PrinterError.disconnected }
        guard data.count <= P1Protocol.bleChunkBytes else { throw P1PrinterError.missingCharacteristics }
        // FF02 是 withoutResponse 写入，但仍受 FF03 credit 限制；
        // 不等待 credit 会出现“走纸正常、图像空白”的典型故障。
        try await waitForCredit()
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        guard peripheral.state == .connected else { throw P1PrinterError.disconnected }
        peripheral.writeValue(data, for: writeCharacteristic, type: .withoutResponse)
    }

    private func waitForCredit() async throws {
        try Task.checkCancellation()
        if flowCredits > 0 {
            flowCredits -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            creditWaiters.append(continuation)
        }
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
    }

    private func receiveCredits(_ count: Int) {
        flowCredits += count
        while flowCredits > 0 && !creditWaiters.isEmpty {
            flowCredits -= 1
            creditWaiters.removeFirst().resume()
        }
    }

    private func waitForReply(command: UInt8, sequence: UInt8) async throws -> P1Frame {
        // 先检查已缓存帧，再注册等待者，兼容响应先于 continuation 注册到达的情况。
        let expected = P1Protocol.replyCommands[command] ?? command
        let key = replyKey(command: expected, sequence: sequence)
        if let index = receivedFrames.firstIndex(where: { $0.command == expected && $0.sequence == sequence }) {
            return receivedFrames.remove(at: index)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<P1Frame, Error>) in
            replyWaiters[key] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.timeoutReply(key: key, command: expected, sequence: sequence)
            }
        }
    }

    private func timeoutReply(key: String, command: UInt8, sequence: UInt8) {
        guard let continuation = replyWaiters.removeValue(forKey: key) else { return }
        continuation.resume(throwing: P1PrinterError.responseTimeout(command, sequence))
    }

    private func replyKey(command: UInt8, sequence: UInt8) -> String { "\(command)-\(sequence)" }

    private func handleFrames(_ data: Data) {
        replyBuffer.append(data)
        let parsed = P1Protocol.parseFrames(replyBuffer)
        replyBuffer = parsed.trailing
        for frame in parsed.frames {
            let key = replyKey(command: frame.command, sequence: frame.sequence)
            if let continuation = replyWaiters.removeValue(forKey: key) {
                continuation.resume(returning: frame)
            } else {
                receivedFrames.append(frame)
            }
        }
    }

    private func handleFlow(_ data: Data) {
        // FF03 流控格式：0x01 count（发放 count 个 credit），
        // 0x02 uint16 little-endian（协商写入块大小）。
        var offset = 0
        while offset < data.count {
            switch data[offset] {
            case 0x01 where offset + 1 < data.count:
                receiveCredits(Int(data[offset + 1]))
                offset += 2
            case 0x02 where offset + 2 < data.count:
                flowChunkSize = Int(data[offset + 1]) | (Int(data[offset + 2]) << 8)
                if flowChunkSize == P1Protocol.bleChunkBytes {
                    flowReadyContinuation?.resume()
                    flowReadyContinuation = nil
                }
                offset += 3
            default:
                offset = data.count
            }
        }
    }

    private func finalFeedSequence(for writes: [Data]) -> UInt8 {
        let stream = writes.dropFirst(2).reduce(into: Data()) { $0.append($1) }
        let frames = P1Protocol.parseFrames(stream).frames
        return frames.last?.sequence ?? 0
    }
}

extension P1Printer: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if central.state == .poweredOn {
                self.centralReady?.resume()
                self.centralReady = nil
            } else if central.state == .unauthorized || central.state == .unsupported {
                self.centralReady?.resume(throwing: P1PrinterError.bluetoothUnavailable)
                self.centralReady = nil
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let name = (advertisedName ?? peripheral.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.lowercased().hasPrefix("paperang") else { return }
            self.scanContinuation?.resume(returning: peripheral)
            self.scanContinuation = nil
            self.central.stopScan()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            self?.connectionContinuation?.resume()
            self?.connectionContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            self?.connectionContinuation?.resume(throwing: error ?? P1PrinterError.connectionFailed)
            self?.connectionContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // 断连时释放所有响应等待者，让上层显示失败并完成清理。
        Task { @MainActor [weak self] in
            self?.replyWaiters.values.forEach { $0.resume(throwing: P1PrinterError.disconnected) }
            self?.replyWaiters.removeAll()
        }
    }
}

extension P1Printer: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard error == nil else {
                self?.characteristicsContinuation?.resume(throwing: error ?? P1PrinterError.missingCharacteristics)
                self?.characteristicsContinuation = nil
                return
            }
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, error == nil else { return }
            // 只保存抓包确认过的特征；其余特征不参与打印协议。
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case P1Protocol.ff01: replyCharacteristic = characteristic
                case P1Protocol.ff02: writeCharacteristic = characteristic
                case P1Protocol.ff03: flowCharacteristic = characteristic
                case P1Protocol.auxNotify: auxNotifyCharacteristic = characteristic
                default: break
                }
            }
            guard writeCharacteristic != nil, replyCharacteristic != nil, flowCharacteristic != nil, auxNotifyCharacteristic != nil else { return }
            for characteristic in [replyCharacteristic, flowCharacteristic, auxNotifyCharacteristic].compactMap({ $0 }) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, error == nil, characteristic.isNotifying else { return }
            notifyCount += 1
            // FF01、FF03、辅助通知都成功订阅后，连接阶段才算完成。
            if notifyCount == 3 {
                characteristicsContinuation?.resume()
                characteristicsContinuation = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor [weak self] in
            guard let self, error == nil else { return }
            if characteristic.uuid == P1Protocol.ff03 {
                handleFlow(data)
            } else if characteristic.uuid == P1Protocol.ff01 {
                handleFrames(data)
            }
        }
    }
}
