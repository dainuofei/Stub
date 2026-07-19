import SwiftUI

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
