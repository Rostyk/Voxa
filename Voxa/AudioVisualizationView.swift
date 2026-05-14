import SwiftUI

protocol AnalyzeItem: Identifiable {
    var id: UUID { get }
}

struct AudioBar: AnalyzeItem {
    let id = UUID()
    let level: AudioLevel
}

struct AudioChunk: AnalyzeItem {
    let id = UUID()
    let bars: [AudioLevel]
    let chunkId: Int
    let confidence: Double
    let isVerifiedChunk: Bool

    var highlightColor: Color {
        if isVerifiedChunk {
            return .green
        }
        let displayPercentage = (confidence - 0.5) / 0.5 * 100
        return displayPercentage >= 70 ? .red : .orange
    }
}

struct AudioVisualizationView: View {
    let barCount: CGFloat
    let windowDuration: TimeInterval
    let audioLevels: [AudioLevel]
    let aiGeneratedChunks: [Int: Double]
    let verifiedIdentityChunks: [Int: Double]
    let currentChunk: Int
    let predictionState: PredictionState

    @State private var barWidth: CGFloat = 0

    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let spacePerBar = availableWidth / barCount
            let calculatedBarWidth = max(1.0, spacePerBar - barSpacing)
            let actualMaxBars = Int(barCount)

            LazyHStack(alignment: .center, spacing: barSpacing) {
                autoModeViewWithAnalyzeItems(maxBars: actualMaxBars)
            }
            .onAppear {
                barWidth = calculatedBarWidth
            }
            .onChange(of: geometry.size.width) { _, _ in
                barWidth = calculatedBarWidth
            }
        }
        .frame(height: 60)
    }

    private func autoModeViewWithAnalyzeItems(maxBars: Int) -> some View {
        let analyzeItems = createSlidingAnalyzeItems(maxBars: maxBars)

        return ForEach(analyzeItems, id: \.id) { item in
            if let audioBar = item as? AudioBar {
                renderAudioBar(audioBar: audioBar)
            } else if let audioChunk = item as? AudioChunk {
                renderAudioChunk(audioChunk: audioChunk)
            }
        }
    }

    private func renderAudioBar(audioBar: AudioBar) -> some View {
        let normalizedLevel = min(audioBar.level.value, 1.0)
        let compressedLevel = pow(normalizedLevel, 0.4)
        let height = max(3, min(55, CGFloat(compressedLevel) * 50))

        return RoundedRectangle(cornerRadius: 1)
            .fill(.blue)
            .frame(width: barWidth, height: height)
            .opacity(0.8)
    }

    private func renderAudioChunk(audioChunk: AudioChunk) -> some View {
        let chunkWidth = CGFloat(audioChunk.bars.count) * (barWidth + barSpacing) - barSpacing

        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.3))
                .frame(width: chunkWidth, height: 60)

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(audioChunk.bars) { level in
                    let normalizedLevel = min(level.value, 1.0)
                    let compressedLevel = pow(normalizedLevel, 0.4)
                    let height = max(3, min(55, CGFloat(compressedLevel) * 50))

                    RoundedRectangle(cornerRadius: 1)
                        .fill(audioChunk.highlightColor)
                        .frame(width: barWidth, height: height)
                        .opacity(0.9)
                }
            }
        }
    }

    private func createSlidingAnalyzeItems(maxBars: Int) -> [any AnalyzeItem] {
        let levelsToShow = min(maxBars, audioLevels.count)
        let recentLevels = Array(audioLevels.suffix(levelsToShow))

        var analyzeItems: [any AnalyzeItem] = []
        var currentChunkBars: [AudioLevel] = []
        var currentChunkId: Int? = nil
        var currentChunkConfidence: Double = 0.0

        for level in recentLevels {
            let fakeChunkConfidence = aiGeneratedChunks[level.chunkId]
            let verifiedChunkConfidence = verifiedIdentityChunks[level.chunkId]
            let chunkConfidence = fakeChunkConfidence ?? verifiedChunkConfidence
            let isAIGenerated = chunkConfidence != nil

            if isAIGenerated {
                if currentChunkId == level.chunkId {
                    currentChunkBars.append(level)
                } else {
                    if !currentChunkBars.isEmpty, let chunkId = currentChunkId {
                        let wasVerified = verifiedIdentityChunks[chunkId] != nil && aiGeneratedChunks[chunkId] == nil
                        analyzeItems.append(AudioChunk(bars: currentChunkBars, chunkId: chunkId, confidence: currentChunkConfidence, isVerifiedChunk: wasVerified))
                    }

                    currentChunkBars = [level]
                    currentChunkId = level.chunkId
                    currentChunkConfidence = chunkConfidence ?? 0.0
                }
            } else {
                if !currentChunkBars.isEmpty, let chunkId = currentChunkId {
                    let wasVerified = verifiedIdentityChunks[chunkId] != nil && aiGeneratedChunks[chunkId] == nil
                    analyzeItems.append(AudioChunk(bars: currentChunkBars, chunkId: chunkId, confidence: currentChunkConfidence, isVerifiedChunk: wasVerified))
                    currentChunkBars = []
                    currentChunkId = nil
                    currentChunkConfidence = 0.0
                }

                analyzeItems.append(AudioBar(level: level))
            }
        }

        if !currentChunkBars.isEmpty, let chunkId = currentChunkId {
            let wasVerified = verifiedIdentityChunks[chunkId] != nil && aiGeneratedChunks[chunkId] == nil
            analyzeItems.append(AudioChunk(bars: currentChunkBars, chunkId: chunkId, confidence: currentChunkConfidence, isVerifiedChunk: wasVerified))
        }

        let totalBarsRepresented = analyzeItems.reduce(0) { total, item in
            if let chunk = item as? AudioChunk {
                return total + chunk.bars.count
            } else {
                return total + 1
            }
        }

        let emptyBarsNeeded = maxBars - totalBarsRepresented
        for _ in 0..<emptyBarsNeeded {
            analyzeItems.insert(AudioBar(level: AudioLevel(value: 0.0, chunkId: 0)), at: 0)
        }

        return analyzeItems
    }
}
