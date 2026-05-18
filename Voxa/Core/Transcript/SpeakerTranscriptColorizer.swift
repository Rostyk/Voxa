import Foundation
import SwiftUI

struct SpeakerColoredSpan: Hashable, Sendable {
    let text: String
    let speakerId: String?
}

enum SpeakerTranscriptColorizer {

    /// Maps Parakeet token timings onto diarization segments for per-token background colors.
    static func coloredSpans(
        transcript: String,
        tokenTimings: [VoxaTokenTiming],
        speakerSegments: [SpeakerDiarizationSegment]
    ) -> [SpeakerColoredSpan] {
        guard !transcript.isEmpty else { return [] }
        guard !tokenTimings.isEmpty, !speakerSegments.isEmpty else {
            return [SpeakerColoredSpan(text: transcript, speakerId: nil)]
        }

        let orderedSpeakerIDs = orderedUniqueSpeakerIDs(from: speakerSegments)
        var spans: [SpeakerColoredSpan] = []
        spans.reserveCapacity(tokenTimings.count)

        for timing in tokenTimings {
            let piece = timing.token
            guard !piece.isEmpty else { continue }
            let speakerId = speakerId(for: timing, in: speakerSegments)
            spans.append(SpeakerColoredSpan(text: piece, speakerId: speakerId))
        }

        if spans.isEmpty {
            return [SpeakerColoredSpan(text: transcript, speakerId: nil)]
        }
        return spans
    }

    static func orderedUniqueSpeakerIDs(from segments: [SpeakerDiarizationSegment]) -> [String] {
        Array(Set(segments.map(\.speakerId))).sorted()
    }

    /// Token-accurate when Parakeet timings exist; otherwise time-proportional over the transcript.
    static func transcriptSpans(
        transcript: String,
        speakerSegments: [SpeakerDiarizationSegment],
        tokenTimings: [VoxaTokenTiming]?
    ) -> [SpeakerColoredSpan] {
        guard !speakerSegments.isEmpty else {
            return [SpeakerColoredSpan(text: transcript, speakerId: nil)]
        }
        if let tokenTimings, !tokenTimings.isEmpty {
            return coloredSpans(
                transcript: transcript,
                tokenTimings: tokenTimings,
                speakerSegments: speakerSegments
            )
        }
        let duration = max(speakerSegments.map(\.endTimeSeconds).max() ?? 0, 0.01)
        return proportionalSpans(
            transcript: transcript,
            speakerSegments: speakerSegments,
            audioDurationSeconds: duration
        )
    }

    /// Colors Apple live partial text using diarization time ranges (approximate until Fluid STT on commit).
    static func proportionalSpans(
        transcript: String,
        speakerSegments: [SpeakerDiarizationSegment],
        audioDurationSeconds: Float
    ) -> [SpeakerColoredSpan] {
        guard !transcript.isEmpty, audioDurationSeconds > 0, !speakerSegments.isEmpty else {
            return [SpeakerColoredSpan(text: transcript, speakerId: nil)]
        }

        let chars = Array(transcript)
        guard !chars.isEmpty else { return [] }

        var spans: [SpeakerColoredSpan] = []
        var runSpeaker: String?
        var runStart = 0

        for index in 0..<chars.count {
            let time = audioDurationSeconds * Float(index) / Float(max(chars.count - 1, 1))
            let speaker = speakerId(at: time, in: speakerSegments)
            if speaker != runSpeaker, index > 0 {
                let slice = String(chars[runStart..<index])
                if !slice.isEmpty {
                    spans.append(SpeakerColoredSpan(text: slice, speakerId: runSpeaker))
                }
                runStart = index
            }
            runSpeaker = speaker
        }
        let tail = String(chars[runStart...])
        if !tail.isEmpty {
            spans.append(SpeakerColoredSpan(text: tail, speakerId: runSpeaker))
        }
        return spans.isEmpty ? [SpeakerColoredSpan(text: transcript, speakerId: nil)] : spans
    }

    static func liveSpeakerLabel(
        segments: [SpeakerDiarizationSegment],
        audioDurationSeconds: Float
    ) -> String? {
        guard !segments.isEmpty, audioDurationSeconds > 0 else { return nil }
        let unique = Set(segments.map(\.speakerId))
        if unique.count == 1, let id = unique.first {
            return SpeakerDiarizationSegment.displayLabel(for: id)
        }
        if let active = speakerId(at: audioDurationSeconds * 0.98, in: segments) {
            let others = unique.count - 1
            if others > 0 {
                return "\(SpeakerDiarizationSegment.displayLabel(for: active)) + \(others) more"
            }
            return SpeakerDiarizationSegment.displayLabel(for: active)
        }
        return "\(unique.count) speakers"
    }

    private static func speakerId(at time: Float, in segments: [SpeakerDiarizationSegment]) -> String? {
        if let containing = segments.first(where: {
            time >= $0.startTimeSeconds && time <= $0.endTimeSeconds
        }) {
            return containing.speakerId
        }
        return segments.min(by: {
            abs(($0.startTimeSeconds + $0.endTimeSeconds) * 0.5 - time)
                < abs(($1.startTimeSeconds + $1.endTimeSeconds) * 0.5 - time)
        })?.speakerId
    }

    private static func speakerId(
        for timing: VoxaTokenTiming,
        in segments: [SpeakerDiarizationSegment]
    ) -> String? {
        let midpoint = (timing.startTimeSeconds + timing.endTimeSeconds) * 0.5
        if let containing = segments.first(where: {
            midpoint >= $0.startTimeSeconds && midpoint <= $0.endTimeSeconds
        }) {
            return containing.speakerId
        }
        return segments.max(by: { overlapScore($0, timing) < overlapScore($1, timing) })?.speakerId
    }

    private static func overlapScore(_ segment: SpeakerDiarizationSegment, _ timing: VoxaTokenTiming) -> Float {
        let start = max(segment.startTimeSeconds, timing.startTimeSeconds)
        let end = min(segment.endTimeSeconds, timing.endTimeSeconds)
        return max(0, end - start)
    }
}
