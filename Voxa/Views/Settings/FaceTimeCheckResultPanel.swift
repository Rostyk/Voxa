import SwiftUI

struct FaceTimeCheckResultPanel: View {
    let result: FaceTimeSettingsCheckResult
    var isSelectingVoxaMic: Bool = false
    var onSelectVoxaMic: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(result.statusRows) { row in
                HStack(alignment: .top, spacing: 12) {
                    statusIcon(row.status)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title)
                            .font(.subheadline.weight(.semibold))
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if row.id == "mic", row.status == .warning, let onSelectVoxaMic {
                            Button {
                                onSelectVoxaMic()
                            } label: {
                                if isSelectingVoxaMic {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Selecting…")
                                    }
                                } else {
                                    Text("Do it for me")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isSelectingVoxaMic)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(rowBackground(row.status))
                }
            }
        }
    }

    private func statusIcon(_ status: FaceTimeCheckStatus) -> some View {
        let name: String
        let color: Color
        switch status {
        case .ok:
            name = "checkmark.circle.fill"
            color = .green
        case .warning:
            name = "exclamationmark.triangle.fill"
            color = .orange
        case .fail:
            name = "xmark.circle.fill"
            color = .red
        case .unknown:
            name = "questionmark.circle.fill"
            color = .secondary
        }
        return Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(color)
    }

    private func rowBackground(_ status: FaceTimeCheckStatus) -> Color {
        switch status {
        case .ok: return Color.green.opacity(0.08)
        case .warning: return Color.orange.opacity(0.08)
        case .fail: return Color.red.opacity(0.08)
        case .unknown: return Color.primary.opacity(0.04)
        }
    }

}
