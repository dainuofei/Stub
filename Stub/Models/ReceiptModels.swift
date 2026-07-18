import Foundation
import SwiftData

enum ReceiptSectionKind: String, Codable, CaseIterable, Identifiable {
    case mustDo
    case tryTodo
    case routine

    var id: String { rawValue }

    var defaultTitle: String {
        switch self {
        case .mustDo: return "T1"
        case .tryTodo: return "T2"
        case .routine: return "Routine"
        }
    }

    var defaultSubtitle: String {
        switch self {
        case .mustDo: return "MUST DO"
        case .tryTodo: return "TRY TODO"
        case .routine: return "Habits"
        }
    }
}

@Model
final class ReceiptDocument {
    static let defaultSlogans = [
        "Today's record.",
        "Printed.",
        "Keep this day.",
        "One more line.",
        "Done is enough.",
        "Progress saved.",
        "Ticket issued.",
        "Memory printed.",
        "Nothing fancy.",
        "Begin here.",
        "Keep moving."
    ]

    @Attribute(.unique) var id: UUID
    var brand: String
    var subtitle: String
    var dateText: String
    var slogan: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \TodoSection.document)
    var sections: [TodoSection]

    init(
        brand: String = "THE LIFE STORE",
        subtitle: String = "OPEN 24/7 · EVERYWHERE",
        dateText: String = ReceiptDocument.todayText(),
        slogan: String = ReceiptDocument.defaultSlogans.randomElement() ?? "Begin here.",
        sections: [TodoSection] = ReceiptSectionKind.allCases.enumerated().map {
            TodoSection(kind: $0.element, order: $0.offset)
        }
    ) {
        self.id = UUID()
        self.brand = brand
        self.subtitle = subtitle
        self.dateText = dateText
        self.slogan = slogan
        self.createdAt = .now
        self.updatedAt = .now
        self.sections = sections
    }

    static func todayText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        return formatter.string(from: .now)
    }

    static func makeDefault() -> ReceiptDocument {
        // Start with empty sections so each day can be planned from scratch.
        return ReceiptDocument()
    }

    func touch() {
        updatedAt = .now
    }
}

@Model
final class TodoSection {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var title: String
    var subtitle: String
    var order: Int
    var document: ReceiptDocument?
    @Relationship(deleteRule: .cascade, inverse: \TodoItem.section)
    var items: [TodoItem]

    var kind: ReceiptSectionKind {
        get { ReceiptSectionKind(rawValue: kindRaw) ?? .mustDo }
        set { kindRaw = newValue.rawValue }
    }

    init(
        kind: ReceiptSectionKind,
        order: Int,
        items: [TodoItem] = []
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.title = kind.defaultTitle
        self.subtitle = kind.defaultSubtitle
        self.order = order
        self.items = items
    }
}

@Model
final class TodoItem {
    @Attribute(.unique) var id: UUID
    var text: String
    var detail: String
    var isCompleted: Bool
    // 任务的当前推进程度；新增字段有默认值，旧草稿迁移后从 0% 开始。
    var progress: Double = 0
    var order: Int
    var section: TodoSection?

    init(text: String = "新的任务", detail: String = "", progress: Double = 0, order: Int = 0) {
        self.id = UUID()
        self.text = text
        self.detail = detail
        self.isCompleted = false
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        self.order = order
    }

    /// 进度只允许落在 0...1，避免旧数据或外部修改破坏打印布局。
    var clampedProgress: Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }

    var progressDisplay: String {
        let filledCount = Int((clampedProgress * 10).rounded())
        let bar = String(repeating: "█", count: filledCount)
            + String(repeating: "░", count: 10 - filledCount)
        return "[\(bar)] \(Int((clampedProgress * 100).rounded()))%"
    }
}

@Model
final class PrintHistoryEntry {
    @Attribute(.unique) var id: UUID
    var documentID: UUID
    var printedAt: Date
    var itemCount: Int

    init(document: ReceiptDocument) {
        self.id = UUID()
        self.documentID = document.id
        self.printedAt = .now
        self.itemCount = document.sections.reduce(0) { $0 + $1.items.count }
    }
}
