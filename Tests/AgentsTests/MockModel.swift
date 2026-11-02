//
//  MockModel.swift
//  swiftpy-llm
//

import Foundation
import FoundationModels
import Synchronization

/// Answers every prompt with the same text and records the transcripts it is
/// sent, after foundation-models-utilities' test model.
struct MockModel: LanguageModel {
    typealias Executor = MockModelExecutor

    let text: String
    let recorder: TranscriptRecorder

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling])
    }

    var executorConfiguration: MockModelExecutor.Configuration {
        MockModelExecutor.Configuration(text: text, recorder: recorder)
    }
}

struct MockModelExecutor: LanguageModelExecutor {
    struct Configuration: Hashable {
        var text: String
        var recorder: TranscriptRecorder
    }

    let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    nonisolated func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: MockModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        configuration.recorder.record(request.transcript)
        await channel.send(.response(entryID: UUID().uuidString, action: .appendText(configuration.text, tokenCount: 1)))
    }
}

final class TranscriptRecorder: Sendable, Hashable {
    private let recorded = Mutex<[Transcript]>([])

    var transcripts: [Transcript] { recorded.withLock { $0 } }

    func record(_ transcript: Transcript) {
        recorded.withLock { $0.append(transcript) }
    }

    static func == (lhs: TranscriptRecorder, rhs: TranscriptRecorder) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
