import AVFoundation
import AppKit
import SwiftUI
import VoxaSDK

struct ContentView: View {
    @State private var callViewModel = CallViewModel.shared
    @State private var micGranted = false
    @State private var systemAudioGranted = false
    @State private var permissionMessage: String?
    @State private var permissionPhase = "Requesting permissions…"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voxa")
                .font(.title.weight(.bold))

            if let permissionMessage {
                Text(permissionMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !micGranted || !systemAudioGranted {
                Text(permissionPhase)
                    .foregroundStyle(.secondary)
            }

            if micGranted && systemAudioGranted {
                processTitle

                HStack(spacing: 8) {
                    if callViewModel.isRecording {
                        Circle()
                            .fill(.green)
                            .frame(width: 10, height: 10)
                            .opacity(0.9)
                    }
                    Text(callViewModel.isRecording ? "Listening" : "Waiting for call app…")
                        .font(.subheadline.weight(.semibold))
                }

                if let recorder = callViewModel.recorder, callViewModel.isRecording {
                    AudioVisualizationView(
                        barCount: 100,
                        windowDuration: 30,
                        audioLevels: recorder.currentAudioLevels,
                        aiGeneratedChunks: recorder.aiGeneratedChunks,
                        verifiedIdentityChunks: recorder.verifiedIdentityChunks,
                        currentChunk: recorder.chunkCounter,
                        predictionState: recorder.predictionState
                    )
                    .frame(height: 60)
                    .frame(maxWidth: .infinity)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 280)
        .task {
            await requestPermissionsAndStart()
        }
    }

    private var processTitle: some View {
        let names = callViewModel.activeMicrophoneProcesses.map(\.name)
        let title = names.isEmpty ? "No mic app detected" : names.joined(separator: ", ")
        return Text(title)
            .font(.headline)
            .lineLimit(2)
    }

    private func requestPermissionsAndStart() async {
        NSApp.activate(ignoringOtherApps: true)

        let mic = await AVAudioApplication.requestRecordPermission()
        print("[ContentView] mic permission result=\(mic)")
        await MainActor.run {
            micGranted = mic
            if !mic {
                permissionMessage = "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone for Voxa."
                return
            }
        }

        // Let the mic alert dismiss before system-audio TCC; otherwise the second prompt can be suppressed.
        try? await Task.sleep(for: .milliseconds(750))

        print("[ContentView] requesting system audio capture TCC…")
        let systemOK = await requestSystemAudioCapturePermission()
        print("[ContentView] system audio capture aggregate result=\(systemOK)")
        await MainActor.run {
            systemAudioGranted = systemOK
            if !systemOK {
                permissionMessage = "System audio capture was denied. Enable Voxa under System Settings → Privacy & Security → Audio Recording."
                return
            }
            permissionPhase = ""
            permissionMessage = nil
            callViewModel.activate()
        }
    }

    private func requestSystemAudioCapturePermission() async -> Bool {
        let session = VoxaSystemAudio()

        let initial = session.getSystemAudioPermissionStatus()
        print("[ContentView] system audio initial status=\(initial.rawValue)")

        switch initial {
        case .authorized:
            print("[ContentView] system audio already authorized")
            return true
        case .denied:
            print("[ContentView] system audio already denied (preflight)")
            return false
        case .unknown:
            break
        }

        return await withCheckedContinuation { continuation in
            var completed = false

            session.requestSystemAudioPermission { status in
                print("[ContentView] system audio onStatusChange status=\(status.rawValue)")
                guard !completed else { return }
                if status == .authorized {
                    completed = true
                    continuation.resume(returning: true)
                } else if status == .denied {
                    completed = true
                    continuation.resume(returning: false)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard !completed else { return }
                completed = true
                let s = session.getSystemAudioPermissionStatus()
                print("[ContentView] system audio permission timeout fallback status=\(s.rawValue)")
                continuation.resume(returning: s == .authorized)
            }
        }
    }
}

#Preview {
    ContentView()
}
