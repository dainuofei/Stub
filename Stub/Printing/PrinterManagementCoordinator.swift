import Combine
import Foundation

enum PrinterManagementState {
    case idle
    case loading
    case loaded
    case saving
    case failed

    var isBusy: Bool {
        switch self {
        case .loading, .saving: return true
        default: return false
        }
    }
}

@MainActor
final class PrinterManagementCoordinator: ObservableObject {
    @Published private(set) var state: PrinterManagementState = .idle
    @Published private(set) var deviceInfo: P1DeviceInfo?
    @Published var selectedDuration: PowerOffDuration?
    @Published var errorMessage: String?

    private var operationTask: Task<Void, Never>?
    private var activePrinter: P1Printer?

    var canSave: Bool {
        guard let selectedDuration else { return false }
        return selectedDuration.isPreset && state == .loaded
    }

    func cancel() {
        activePrinter?.cancel()
        operationTask?.cancel()
    }

    func load() {
        guard operationTask == nil else { return }
        state = .loading
        errorMessage = nil
        let printer = P1Printer()
        activePrinter = printer
        operationTask = Task { [weak self] in
            do {
                let info = try await printer.readDeviceInfo()
                self?.deviceInfo = info
                self?.selectedDuration = info.powerOff
                self?.state = .loaded
            } catch is CancellationError {
                self?.state = .failed
                self?.errorMessage = "已取消连接。"
            } catch {
                self?.state = .failed
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            printer.disconnect()
            self?.activePrinter = nil
            self?.operationTask = nil
        }
    }

    func save() {
        guard canSave, let selectedDuration else { return }
        operationTask?.cancel()
        state = .saving
        errorMessage = nil
        let printer = P1Printer()
        activePrinter = printer
        operationTask = Task { [weak self] in
            do {
                let info = try await printer.setPowerOffTime(selectedDuration)
                self?.deviceInfo = info
                self?.selectedDuration = info.powerOff
                self?.state = .loaded
            } catch is CancellationError {
                self?.state = .failed
                self?.errorMessage = "设置已取消。"
            } catch {
                self?.state = .failed
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            printer.disconnect()
            self?.activePrinter = nil
            self?.operationTask = nil
        }
    }
}
