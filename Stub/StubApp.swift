import SwiftUI
import SwiftData

@main
struct StubApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: ReceiptDocument.self, TodoSection.self, TodoItem.self, PrintHistoryEntry.self)
        } catch {
            fatalError("Unable to create local Todo storage: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
