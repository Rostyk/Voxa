import AppKit
import SwiftUI

/// Shows which apps are using the microphone (FaceTime / avconferenced normalized to “FaceTime” + icon).
struct CallListenerCard: View {
    let processes: [AudioProcess]
    let isListening: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isListening ? Color.red : Color.secondary)
                Text("Call listener")
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 0)
                listeningBadge
            }

            if processes.isEmpty {
                Text("No mic app detected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(processes) { process in
                        processRow(process)
                    }
                }
            }

            Text(
                isListening
                    ? "Capturing system audio from active call apps."
                    : "Waiting for a call app (FaceTime, Zoom, Chrome, …) to use the microphone."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VoxaPanelStyle.blockPadding)
        .voxaPanelBackground()
    }

    private var listeningBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isListening ? Color.red : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            Text(isListening ? "On call" : "Idle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isListening ? Color.red : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    private func processRow(_ process: AudioProcess) -> some View {
        HStack(spacing: 12) {
            AppIconView(image: CallProcessDisplay.icon(for: process))
            VStack(alignment: .leading, spacing: 2) {
                Text(CallProcessDisplay.displayName(for: process))
                    .font(.subheadline.weight(.semibold))
                if process.name != CallProcessDisplay.displayName(for: process) {
                    Text(process.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let bundle = process.bundleID {
                    Text(bundle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AppIconView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
