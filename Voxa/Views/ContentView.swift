import AVFoundation
import AppKit
import Speech
import SwiftUI
import VoxaSDK

struct ContentView: View {
    @State private var callViewModel = CallViewModel.shared
    @State private var conversationViewModel = ConversationViewModel()
    @State private var virtualMicStatus = VoxaVirtualMicFeederStatus.shared
    @State private var micGranted = false
    @State private var systemAudioGranted = false
    @State private var permissionMessage: String?
    @State private var permissionPhase = "Requesting permissions…"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let permissionMessage {
                Text(permissionMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !micGranted || !systemAudioGranted {
                Text(permissionPhase)
                    .foregroundStyle(.secondary)
            }

            if micGranted && systemAudioGranted {
                virtualMicStatusCard
                callStatusCard

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

                    ConversationTranscriptView(model: conversationViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 480, minHeight: 280)
        .task {
            await requestPermissionsAndStart()
        }
        .onChange(of: callViewModel.isRecording) { _, recording in
            guard micGranted, systemAudioGranted else { return }
            guard let recorder = callViewModel.recorder else { return }
            if recording {
                conversationViewModel.bindToRecorder(recorder)
            } else {
                conversationViewModel.unbind(from: recorder)
            }
        }
        .onChange(of: conversationViewModel.state.speechAuthorized) { _, granted in
            guard granted, micGranted, systemAudioGranted else { return }
            guard callViewModel.isRecording, let recorder = callViewModel.recorder else { return }
            conversationViewModel.bindToRecorder(recorder)
        }
        .onAppear {
            guard micGranted, systemAudioGranted else { return }
            if callViewModel.isRecording, let recorder = callViewModel.recorder {
                conversationViewModel.bindToRecorder(recorder)
            }
        }
    }

    private var virtualMicStatusCard: some View {
        let status = virtualMicStatus
        let tint: Color = {
            if status.isHealthy { return .green }
            if status.isRunning { return .orange }
            return .secondary
        }()
        let icon = status.isHealthy ? "mic.fill" : (status.isRunning ? "mic.badge.xmark" : "mic.slash")
        let headline: String = {
            if status.isHealthy {
                return "Virtual mic active"
            }
            if status.isRunning {
                return "Virtual mic active (check settings)"
            }
            return "Virtual mic not running"
        }()
        let subline: String = {
            if let detail = status.detailMessage { return detail }
            if status.isRunning, let name = status.captureDeviceName {
                return "Capturing “\(name)” for Meet / QuickTime. Select “Voxa Virtual Microphone” there."
            }
            return "Starts automatically after microphone access is granted."
        }()

        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(subline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var callStatusCard: some View {
        let names = callViewModel.activeMicrophoneProcesses.map(\.name)
        let hasCallApp = !names.isEmpty
        let headline = hasCallApp ? names.joined(separator: ", ") : "No mic app detected"
        let subline = callViewModel.isRecording ? "Listening" : "Waiting for call app…"
        let headlineIcon = hasCallApp ? "phone.fill" : "mic.slash"
        let headlineTint = hasCallApp ? Color.accentColor : Color.secondary

        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(headlineTint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: headlineIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(headlineTint)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if callViewModel.isRecording {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .stroke(.green.opacity(0.45), lineWidth: 1)
                                    .scaleEffect(1.35)
                            )
                            .accessibilityLabel("Active")
                    } else {
                        Image(systemName: "hourglass")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(subline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
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
        }

        guard systemOK else { return }

        // Speech must be set before activate(): otherwise recording can start, onChange binds
        // while speechAuthorized is still false, bind aborts, and nothing re-triggers bind.
        let speechOK = await requestSpeechAuthorization()
        await MainActor.run {
            conversationViewModel.setSpeechAuthorized(speechOK)
            callViewModel.activate()
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestSystemAudioCapturePermission() async -> Bool {
        let session = VoxaAudioKit()

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
