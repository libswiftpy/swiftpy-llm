//
//  Skill.swift
//  swiftpy-llm
//

import SwiftPy
import SwiftPyViews
import SwiftUI
import FoundationModels
import FoundationModelsUtilities

/// Guidance an ``agents.Agent``'s model takes up only when a request needs it,
/// so the rest of the conversation isn't crowded by it.
///
/// ```python
/// from agents import Agent, Skill
///
/// haiku = Skill("haiku", "Answers in a haiku", "Answer in a 5-7-5 haiku.")
/// agent = Agent(skills=[haiku])
/// await agent.respond("Describe autumn as a haiku")
/// ```
@Scriptable
@MainActor
public final class Skill {
    /// The name the model activates the skill by.
    public let name: String

    /// What the skill does. This is what the model reads to decide when to activate it.
    public let description: String

    /// Added to the conversation each time the model activates the skill.
    public let prompt: String

    /// Creates a skill.
    ///
    /// name: A short, unique name the model activates the skill by.
    /// description: What the skill does, for the model to decide when to activate it.
    /// prompt: Text added to the conversation each time the skill is activated.
    public init(name: String, description: String, prompt: String) {
        self.name = name
        self.description = description
        self.prompt = prompt
    }
}

extension Skill {
    nonisolated var skill: FoundationModelsUtilities.Skill {
        let name = name
        return FoundationModelsUtilities.Skill(name: name, description: description, prompt: prompt) {
            Task { @MainActor in Self.displayActivation(of: name) }
        }
    }

    // Without it, the model's turn changes with nothing to show why.
    private static func displayActivation(of name: String) {
        // Flush with the cell, as the tool cards are.
        let view = HStack(spacing: 8) {
            Capsule()
                .fill(Color.purple.gradient)
                .frame(width: 4)
            Label("Activated skill \(name)", systemImage: "lightbulb")
                .font(.caption.bold())
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.purple.opacity(0.1))
        .padding(-8)
        Interpreter.interface.display(AnyView(view))
    }
}
