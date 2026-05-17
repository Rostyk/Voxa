import SwiftUI

struct HistoryPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History")
                .font(.title2.weight(.semibold))
            Text("Past calls and transcripts will appear here.")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(VoxaPanelStyle.blockPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
