import AVFoundation
import AppKit
import Speech
import SwiftUI
import VoxaSDK

struct ContentView: View {
    @State private var callViewModel = CallViewModel.shared
    @State private var conversationViewModel = ConversationViewModel()
    @State private var micGranted = false
    @State private var systemAudioGranted = false
    @State private var permissionMessage: String?
    @State private var permissionPhase = "Requesting permissions…"

    var body: some View {
        Group {
            if let permissionMessage {
                permissionGate(message: permissionMessage)
            } else if !micGranted || !systemAudioGranted {
                permissionGate(message: permissionPhase)
            } else {
                AppShellView(
                    callViewModel: callViewModel,
                    conversationViewModel: conversationViewModel
                )
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .voxaShellBackground()
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

    private func permissionGate(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voxa")
                .font(.title.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .voxaShellBackground()
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
