import Combine
import Foundation

enum PrintState: Equatable {
    case idle
    case scanning
    case connecting
    case preparing
    case printing
    case feeding
    case completed
    case cancelled
    case failed

    var label: String {
        switch self {
        case .idle: return "准备就绪"
        case .scanning: return "正在寻找喵喵机…"
        case .connecting: return "正在连接…"
        case .preparing: return "正在准备纸条…"
        case .printing: return "正在打印…"
        case .feeding: return "正在留出裁切余量…"
        case .completed: return "打印完成"
        case .cancelled: return "已取消"
        case .failed: return "打印失败"
        }
    }

    var isReady: Bool {
        switch self {
        case .idle, .completed, .cancelled, .failed: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .scanning, .connecting, .preparing, .printing, .feeding: return true
        default: return false
        }
    }
}

@MainActor
final class PrintCoordinator: ObservableObject {
    @Published private(set) var state: PrintState = .idle
    @Published var errorMessage: String?
    private var activePrinter: P1Printer?
    private var printTask: Task<Void, Never>?

    // 打印任务在前台主动启动；取消时同时通知 P1Printer，停止 BLE 扫描、
    // 断开设备并释放 credit/响应等待，避免下一次打印被旧任务占用。
    func startPrint(document: ReceiptDocument, density: UInt8 = 95) {
        guard state.isReady else { return }
        errorMessage = nil
        printTask?.cancel()
        printTask = Task { [weak self] in
            await self?.performPrint(document: document, density: density)
        }
    }

    func cancelPrint() {
        guard state.isActive else { return }
        activePrinter?.cancel()
        printTask?.cancel()
    }

    private func performPrint(document: ReceiptDocument, density: UInt8) async {
        let printer = P1Printer()
        activePrinter = printer
        state = .scanning
        do {
            try Task.checkCancellation()
            let raster = RasterRenderer.render(document: document)
            state = .connecting
            state = .preparing
            state = .printing
            try await printer.print(
                raster: raster,
                density: density,
                feedLines: UInt16(P1Protocol.appFeedLines)
            )
            state = .feeding
            state = .completed
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = .failed
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        activePrinter = nil
        printTask = nil
    }
}
