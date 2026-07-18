import SwiftUI
import SwiftData

struct ReceiptEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var document: ReceiptDocument
    @StateObject private var printCoordinator = PrintCoordinator()
    @State private var showPrinterManagement = false
    @AppStorage("paperang.printDensity") private var printDensity: Double = 100
    private let dayChangeTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ReceiptPaperView(document: document)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 18)

                // Printing is deliberately the last piece of content, so it
                // only appears after the user has reached the bottom.
                PrintActionBar(
                    state: printCoordinator.state,
                    onManage: { showPrinterManagement = true },
                    onPrint: { startPrint() },
                    onCancel: { printCoordinator.cancelPrint() }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .background(PaperangColors.canvas.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            resetForNewDayIfNeeded()
            syncSectionLabels()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                resetForNewDayIfNeeded()
            }
        }
        .onReceive(dayChangeTimer) { _ in
            resetForNewDayIfNeeded()
        }
        .onChange(of: document.updatedAt) { _, _ in
            try? modelContext.save()
        }
        .onChange(of: printCoordinator.state) { _, state in
            if state == .completed {
                modelContext.insert(PrintHistoryEntry(document: document))
                try? modelContext.save()
            }
        }
        .sheet(isPresented: $showPrinterManagement) {
            PrinterManagementSheet()
        }
        .alert("打印提示", isPresented: Binding(
            get: { printCoordinator.errorMessage != nil },
            set: { if !$0 { printCoordinator.errorMessage = nil } }
        )) {
            Button("好") { printCoordinator.errorMessage = nil }
        } message: {
            Text(printCoordinator.errorMessage ?? "")
        }
    }

    private func startPrint() {
        document.touch()
        try? modelContext.save()
        printCoordinator.startPrint(document: document, density: UInt8(clamping: Int(printDensity.rounded())))
    }

    private func resetForNewDayIfNeeded() {
        let today = ReceiptDocument.todayText()
        guard document.dateText != today else { return }

        for section in document.sections {
            for item in section.items {
                modelContext.delete(item)
            }
            section.items.removeAll()
        }
        document.dateText = today
        document.touch()
        try? modelContext.save()
    }

    private func syncSectionLabels() {
        var changed = false
        for section in document.sections {
            let target: String
            switch section.kind {
            case .mustDo: target = "MUST DO"
            case .tryTodo: target = "TRY TODO"
            case .routine: target = "Habits"
            }

            if section.subtitle == "必做" || section.subtitle == "尝试完成" || section.subtitle == "习惯" || section.subtitle == "Habit" {
                section.subtitle = target
                changed = true
            }
        }

        if changed {
            document.touch()
            try? modelContext.save()
        }
    }
}

struct PrintActionBar: View {
    let state: PrintState
    let onManage: () -> Void
    let onPrint: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if state.isActive {
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(PaperangColors.mutedInk)

                Button(role: .destructive, action: onCancel) {
                    Label("取消打印", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .foregroundStyle(.white)
            } else {
                if state != .idle {
                    Text(state.label)
                        .font(.caption)
                        .foregroundStyle(PaperangColors.mutedInk)
                }

                HStack(spacing: 10) {
                    Button(action: onPrint) {
                        Label("打印到喵喵机", systemImage: "printer.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PaperangColors.ink)
                    .foregroundStyle(.white)

                    Button(action: onManage) {
                        Label("管理喵喵机", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(PaperangColors.ink)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

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

struct PrinterManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = PrinterManagementCoordinator()
    @AppStorage("paperang.printDensity") private var printDensity: Double = 100

    var body: some View {
        NavigationStack {
            Form {
                Section("设备状态") {
                    if coordinator.state.isBusy {
                        ProgressView("正在连接喵喵机…")
                    }

                    if let info = coordinator.deviceInfo {
                        Label {
                            Text(info.batteryPercent.map { "\($0)%" } ?? "未知")
                        } icon: {
                            Image(systemName: batterySymbol(for: info.batteryPercent))
                                .foregroundStyle(batteryColor(for: info.batteryPercent))
                        }
                        Text("当前自动关机：\(info.powerOff.label)")
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage = coordinator.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("自动关机时间") {
                    Menu {
                        ForEach(PowerOffDuration.presets) { duration in
                            Button {
                                coordinator.selectedDuration = duration
                            } label: {
                                if coordinator.selectedDuration == duration {
                                    Label(duration.label, systemImage: "checkmark")
                                } else {
                                    Text(duration.label)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("时间")
                            Spacer()
                            Text(coordinator.selectedDuration?.label ?? "请选择")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(coordinator.state.isBusy || coordinator.deviceInfo == nil)

                    if case .unknown = coordinator.selectedDuration {
                        Text("设备返回了未列入预设的原始值；选择一个预设并保存后才会覆盖它。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("保存设置") {
                        coordinator.save()
                    }
                    .disabled(!coordinator.canSave)
                }

                Section("打印效果") {
                    HStack {
                        Text("黑色浓度")
                        Spacer()
                        Text("\(Int(printDensity.rounded()))")
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $printDensity, in: 70...100, step: 5)

                    Text("数值越高通常越黑；老设备可以先试试 100。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("管理喵喵机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            coordinator.load()
        }
        .onDisappear {
            coordinator.cancel()
        }
    }

    private func batterySymbol(for battery: Int?) -> String {
        guard let battery else { return "battery.0" }
        switch battery {
        case 0..<20: return "battery.0"
        case 20..<50: return "battery.25"
        case 50..<80: return "battery.50"
        case 80..<95: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryColor(for battery: Int?) -> Color {
        guard let battery else { return .secondary }
        return battery < 20 ? .red : .green
    }
}

struct ReceiptPaperView: View {
    @Bindable var document: ReceiptDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("品牌名", text: $document.brand)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            TextField("副标题", text: $document.subtitle)
                .font(.system(size: 15, weight: .light, design: .rounded))
                .tracking(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            HStack(spacing: 12) {
                Text(document.dateText)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 29))
            }
            .padding(.top, 24)

            TextField("写一句给自己的话", text: $document.slogan)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(PaperangColors.ink)
                .padding(.top, 8)

            ForEach(document.sections.sorted { $0.order < $1.order }) { section in
                SectionEditorView(section: section)
            }
        }
        .padding(18)
        // 收据卡片撑满可用宽度，分组标题和任务进度列共享同一条右边界。
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperangColors.paper)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }
}

struct SectionEditorView: View {
    @Bindable var section: TodoSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.top, 18)
            HStack(alignment: .firstTextBaseline) {
                TextField("分组", text: $section.title)
                    .font(.system(size: 25, weight: .black, design: .rounded))
                TextField("副标题", text: $section.subtitle)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.trailing)
            }

            ForEach(section.items) { item in
                TodoRow(item: item) {
                    section.items.removeAll { $0.id == item.id }
                    section.items.enumerated().forEach { section.items[$0.offset].order = $0.offset }
                }
            }
            .onMove { offsets, destination in
                section.items.move(fromOffsets: offsets, toOffset: destination)
                section.items.enumerated().forEach { section.items[$0.offset].order = $0.offset }
            }

            Button {
                section.items.append(TodoItem(order: section.items.count))
            } label: {
                Text("＋ 添加任务")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PaperangColors.mutedInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(PaperangColors.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
            }
        }
        // 分组容器也必须占满收据宽度，否则任务行无法把进度列推到右侧。
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TodoRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: TodoItem
    let onDelete: () -> Void
    @State private var showProgressEditor = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { item.isCompleted.toggle() } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(PaperangColors.ink)
            }
            .buttonStyle(.plain)

            TextField("任务", text: $item.text)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .strikethrough(item.isCompleted)
                // 给任务名保留至少约 6 个中文字符的可视空间，避免被右侧列压缩成两三个字。
                .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            TextField("时长/次数", text: $item.detail)
                .font(.system(size: 13, design: .rounded))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(PaperangColors.mutedInk)
                // 与打印端的详情列保持一致，给任务名多留出可视空间。
                .frame(width: 52)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.red.opacity(0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除任务")

            // 让整个进度列贴右，同时保持列内进度条从左侧起画。
            Spacer(minLength: 0)

            TaskProgressView(progress: item.clampedProgress) {
                showProgressEditor = true
            }
        }
        // 任务行撑满收据内容宽度，Spacer 才能把进度列推到最右侧。
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showProgressEditor) {
            ProgressEditorSheet(progress: item.clampedProgress) { newProgress in
                item.progress = newProgress
                try? modelContext.save()
            }
        }
    }
}

/// 收据风格的固定宽度进度按钮；放在任务行右侧，不增加任务行高度。
struct TaskProgressView: View {
    let progress: Double
    let onTap: () -> Void

    private var display: String {
        TaskProgressFormatter.display(progress)
    }

    var body: some View {
        Button(action: onTap) {
            Text(display)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaperangColors.ink)
                .lineLimit(1)
                // 固定列整体贴右；百分比补齐到三位后，进度条起点也保持一致。
                .frame(width: 122, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("任务进度 \(display)")
        .accessibilityHint("点击修改进度")
    }
}

struct ProgressEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draftProgress: Double
    let onSave: (Double) -> Void

    init(progress: Double, onSave: @escaping (Double) -> Void) {
        _draftProgress = State(initialValue: min(max(progress.isFinite ? progress : 0, 0), 1))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 22) {
            Text("Progress")
                .font(.headline)

            Text("\(Int((draftProgress * 100).rounded()))%")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()

            Slider(value: $draftProgress, in: 0...1, step: 0.01)
                .tint(PaperangColors.ink)

            HStack(spacing: 12) {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Button("保存") {
                    onSave(draftProgress)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(PaperangColors.ink)
            }
        }
        .padding(24)
        .presentationDetents([.height(240)])
    }
}
