//
//  History.swift
//  swiftpy-llm
//

import SwiftPy
import FoundationModels
import FoundationModelsUtilities

/// How an ``agents.Agent`` keeps a long conversation within its model's
/// context. The options apply in the order they are listed here.
///
/// ```python
/// from agents import Agent, History
///
/// agent = Agent(history=History(drop_completed_tool_calls=True, rolling_window=10))
/// ```
@Scriptable
@MainActor
public final class History {
    /// Whether tool calls and their results leave the conversation once answered.
    public let dropCompletedToolCalls: Bool

    /// How many of the latest entries the model sees, or None for all of them.
    public let rollingWindow: Int?

    /// How many entries make the model summarize the conversation into one, or None to never summarize.
    public let summarizeAfter: Int?

    /// Creates the history options.
    ///
    /// drop_completed_tool_calls: Remove tool calls and their results once answered. Defaults to False.
    /// rolling_window: Let the model see only this many of the latest prompts, responses and tool calls; the agent's instructions stay. Defaults to None.
    /// summarize_after: Once the conversation has more entries than this, the agent's model summarizes it into one. Defaults to None.
    public init(dropCompletedToolCalls: Bool = false, rollingWindow: Int? = nil, summarizeAfter: Int? = nil) throws {
        if let rollingWindow, rollingWindow < 1 {
            throw PythonError.ValueError("rolling_window must be at least 1")
        }
        if let summarizeAfter, summarizeAfter < 1 {
            throw PythonError.ValueError("summarize_after must be at least 1")
        }
        self.dropCompletedToolCalls = dropCompletedToolCalls
        self.rollingWindow = rollingWindow
        self.summarizeAfter = summarizeAfter
    }
}

extension History {
    /// The outermost modifier runs first, so they are applied in reverse.
    nonisolated func apply(
        to profile: some LanguageModelSession.DynamicProfile,
        summarizer: any FoundationModels.LanguageModel
    ) -> LanguageModelSession.AnyDynamicProfile {
        var profile = LanguageModelSession.AnyDynamicProfile(erasing: profile)
        if let summarizeAfter {
            profile = .init(erasing: profile.summarizeHistory(entryThreshold: summarizeAfter, model: summarizer))
        }
        if let rollingWindow {
            // Not the utilities' `rollingWindow`: it drops the instructions too.
            profile = .init(erasing: profile.historyTransform { history in
                let instructions = history.prefix { if case .instructions = $0 { true } else { false } }
                return Array(instructions) + history.dropFirst(instructions.count).suffix(rollingWindow)
            })
        }
        if dropCompletedToolCalls {
            profile = .init(erasing: profile.droppingCompletedToolCalls())
        }
        return profile
    }
}
