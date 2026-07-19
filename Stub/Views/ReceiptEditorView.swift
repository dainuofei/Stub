import SwiftUI
import SwiftData

struct ReceiptEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var document: ReceiptDocument
    @StateObject private var printCoordinator = PrintCoordinator()
    @State private var showPrinterManagement = false
    @State private var photoSaveState: PhotoSaveState = .idle
    @State private var photoSaveError: String?
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
                    photoSaveState: photoSaveState,
                    onManage: { showPrinterManagement = true },
                    onSave: { saveToPhotos() },
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
        .alert("保存到相册", isPresented: Binding(
            get: { photoSaveError != nil },
            set: { if !$0 { photoSaveError = nil } }
        )) {
            Button("好") { photoSaveError = nil }
        } message: {
            Text(photoSaveError ?? "")
        }
    }

    private func startPrint() {
        document.touch()
        try? modelContext.save()
        printCoordinator.startPrint(document: document, density: UInt8(clamping: Int(printDensity.rounded())))
    }

    private func saveToPhotos() {
        guard photoSaveState != .saving else { return }
        photoSaveState = .saving
        photoSaveError = nil

        Task { @MainActor in
            do {
                let photoImage = RasterRenderer.renderImage(document: document, scale: 3)
                try await PhotoLibrarySaver.save(photoImage)
                photoSaveState = .saved
            } catch is CancellationError {
                photoSaveState = .idle
            } catch {
                photoSaveState = .failed
                photoSaveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
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
