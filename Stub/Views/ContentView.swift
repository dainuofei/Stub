import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReceiptDocument.updatedAt, order: .reverse) private var documents: [ReceiptDocument]

    var body: some View {
        Group {
            if let document = documents.first {
                ReceiptEditorView(document: document)
            } else {
                ProgressView("正在准备今日收据…")
                    .task { createDefaultDocumentIfNeeded() }
            }
        }
        .tint(.black)
        .background(PaperangColors.canvas.ignoresSafeArea())
    }

    private func createDefaultDocumentIfNeeded() {
        guard documents.isEmpty else { return }
        modelContext.insert(ReceiptDocument.makeDefault())
        try? modelContext.save()
    }
}

enum PaperangColors {
    static let canvas = Color(red: 0.94, green: 0.93, blue: 0.90)
    static let paper = Color.white
    static let ink = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let mutedInk = Color(red: 0.36, green: 0.36, blue: 0.34)
    static let line = Color.black.opacity(0.14)
}
