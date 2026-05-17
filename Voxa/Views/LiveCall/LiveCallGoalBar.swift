import SwiftUI

struct LiveCallGoalBar: View {
    let model: ConversationViewModel
    @State private var showCallGoalSheet = false

    var body: some View {
        @Bindable var caption = model.captionTranslation

        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Call goal")
                    .font(VoxaTypography.liveStatusActive)
                    .foregroundStyle(VoxaTypography.liveStatusActiveColor)
                Text(goalPreview(caption.callGoal))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                showCallGoalSheet = true
            } label: {
                Label("Set goal", systemImage: "target")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 120, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("What you want to achieve on this call — used for translation and suggested actions.")
        }
        .padding(VoxaPanelStyle.blockPadding)
        .voxaPanelBackground()
        .sheet(isPresented: $showCallGoalSheet) {
            callGoalEditorSheet(isPresented: $showCallGoalSheet, goal: $caption.callGoal)
        }
    }

    private func goalPreview(_ goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "No goal set — tap Set goal to guide translations and actions."
        }
        return trimmed
    }

    private func callGoalEditorSheet(isPresented: Binding<Bool>, goal: Binding<String>) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Describe the goal of this call. ChatGPT will translate each callee line and suggest actions (DTMF, phrases to say, or when you should speak).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: goal)
                    .font(.body)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            }
            .padding(16)
            .frame(minWidth: 400, minHeight: 260)
            .navigationTitle("Set goal")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let trimmed = goal.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("[CallGoal] call goal saved chars=\(trimmed.count) preview=\"\(String(trimmed.prefix(80)))\"")
                        isPresented.wrappedValue = false
                    }
                }
            }
        }
    }
}
