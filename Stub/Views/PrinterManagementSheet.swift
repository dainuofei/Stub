import SwiftUI

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
