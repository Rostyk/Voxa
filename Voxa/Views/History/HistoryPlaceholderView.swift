import AppKit
import SwiftUI

struct HistoryPlaceholderView: View {
    @State private var historyStore = CallHistoryStore.shared
    @State private var selectedRecordID: UUID?

    private var selectedRecord: CallHistoryRecord? {
        if let selectedRecordID,
           let selected = historyStore.records.first(where: { $0.id == selectedRecordID }) {
            return selected
        }
        return historyStore.records.first
    }

    var body: some View {
        HStack(spacing: 0) {
            callList

            Divider()
                .overlay(VoxaColors.panelStroke)

            if let selectedRecord {
                CallHistoryDetailView(record: selectedRecord, historyStore: historyStore)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            historyStore.reload()
            if selectedRecordID == nil {
                selectedRecordID = historyStore.records.first?.id
            }
        }
        .onChange(of: historyStore.records) { _, records in
            guard !records.isEmpty else {
                selectedRecordID = nil
                return
            }
            if let selectedRecordID,
               records.contains(where: { $0.id == selectedRecordID }) {
                return
            }
            selectedRecordID = records.first?.id
        }
    }

    private var callList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 8)
                Button {
                    NSWorkspace.shared.open(historyStore.historyFolderURL)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open call history JSON folder in Finder")
            }

            if historyStore.records.isEmpty {
                Text("Past calls and transcripts will appear here.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(historyStore.records) { record in
                            Button {
                                selectedRecordID = record.id
                            } label: {
                                CallHistoryRow(record: record, isSelected: selectedRecordID == record.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let error = historyStore.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No call selected")
                .font(.title3.weight(.semibold))
            Text("Select a saved call to see its translated transcript.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CallHistoryRow: View {
    let record: CallHistoryRecord
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.displayTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(record.timeframeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text("\(record.turns.count) bubbles")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? VoxaColors.sidebarSelection : Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(isSelected ? 0.12 : 0.06), lineWidth: 1)
        }
    }
}

private struct CallHistoryDetailView: View {
    let record: CallHistoryRecord
    let historyStore: CallHistoryStore
    @State private var isEditingTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                titleHeader

                HStack(spacing: 8) {
                    Text(record.timeframeText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(record.turns) { turn in
                        ConversationTurnBubbleView(
                            turn: turn,
                            speechLocaleIdentifier: record.speechLocaleIdentifier,
                            speakerDiarizationEnabled: true
                        )
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var titleHeader: some View {
        if isEditingTitle {
            TextField(
                record.displayTitle,
                text: Binding(
                    get: { record.manualTitle ?? "" },
                    set: { historyStore.setManualTitle($0, for: record.id) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.title2.weight(.semibold))
            .onSubmit {
                isEditingTitle = false
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.displayTitle)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(2)

                Button {
                    isEditingTitle = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Rename call")

                Spacer(minLength: 0)
            }
        }
    }
}
