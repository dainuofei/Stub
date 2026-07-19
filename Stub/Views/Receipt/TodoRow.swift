import SwiftUI
import SwiftData

struct TodoRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: TodoItem
    let onDelete: () -> Void
    @State private var showProgressEditor = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                item.toggleCompletionFromCheckbox()
                try? modelContext.save()
            } label: {
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
