import SwiftUI

struct PrintActionBar: View {
    let state: PrintState
    let photoSaveState: PhotoSaveState
    let onManage: () -> Void
    let onSave: () -> Void
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

                // 将两个次要操作并排放在上方，把主要的打印操作单独放在下方，
                // 让打印按钮获得完整宽度并降低误触相邻按钮的概率。
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(action: onSave) {
                            Label(photoSaveState.label, systemImage: "photo.on.rectangle")
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .tint(PaperangColors.ink)
                        .disabled(photoSaveState == .saving)

                        Button(action: onManage) {
                            Label("管理喵喵机", systemImage: "slider.horizontal.3")
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .tint(PaperangColors.ink)
                    }

                    Button(action: onPrint) {
                        Label("打印到喵喵机", systemImage: "printer.fill")
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PaperangColors.ink)
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}
