import SwiftPy
import SwiftPyViews
import SwiftUI
import FoundationModels
import FoundationModelsUtilities

/// A session that holds a conversation with a language model.
@Scriptable
@MainActor
public class Agent {
    private let instructions: String?
    private let tools: [Tool]
    private let skills: [Skill]
    private let history: History?
    // Required by `Skills`, though prompt skills are never recorded in it.
    private let activations = SkillActivations()
    private var session: FoundationModels.LanguageModelSession?
    private var sessionModel: (any FoundationModels.LanguageModel)?
    private var reasons = false
    private var answeredBy: String?

    /// The model the agent runs on.
    public let model: LanguageModel

    /// The model that answered: `"Private Cloud Compute"`, `"On-device"`, or a
    /// Claude model's ID, or `None` before the first response.
    public var modelName: String? { answeredBy }

    /// Starts a session with a language model.
    ///
    /// instructions: Standing guidance the model follows for every prompt in the session, such as its role and the style to answer in. Defaults to None.
    /// tools: Functions the model may call, each one built by the ``agents.tool`` decorator. Defaults to None.
    /// model: The model to run on, such as ``claude.sonnet()``. Defaults to None, a ``agents.SystemLanguageModel``: Private Cloud Compute when it is available, the on-device model otherwise.
    /// skills: Guidance the model takes up only when a request needs it, each a ``agents.Skill``. Defaults to None.
    /// history: How a long conversation is kept within the model's context, a ``agents.History``. Defaults to None, keeping all of it.
    public init(
        instructions: String? = nil,
        tools: [Tool]? = nil,
        model: LanguageModel? = nil,
        skills: [Skill]? = nil,
        history: History? = nil
    ) {
        self.instructions = instructions
        self.tools = tools ?? []
        self.model = model ?? LanguageModel(provider: SystemLanguageModel())
        self.skills = skills ?? []
        self.history = history
    }

    // Resolved on the first response rather than in init, the async place a
    // model may also have to ask for credentials.
    private func resolvedSession() throws(PythonError) -> FoundationModels.LanguageModelSession {
        if let session {
            return session
        }
        let resolved = try model.provider.resolve()
        return start(on: resolved.model, named: resolved.name, reasons: resolved.reasons, history: [])
    }

    private func start(
        on model: any FoundationModels.LanguageModel,
        named name: String,
        reasons: Bool,
        history: [Transcript.Entry]
    ) -> FoundationModels.LanguageModelSession {
        let session = FoundationModels.LanguageModelSession(profile: profile(for: model), history: history)
        self.session = session
        sessionModel = model
        self.reasons = reasons
        answeredBy = name
        return session
    }

    /// Produces a response to a prompt.
    ///
    /// prompt: What to ask the model.
    /// schema: A class decorated with ``modeling.model``, to answer with an instance of it instead of text. Its annotated fields are the structure the model fills in, and defaults on them are offered to the model as defaults. Defaults to None.
    /// reasoning: How much the model thinks before answering: "light", "moderate", or "deep". The on-device model doesn't reason, so it ignores it. Defaults to None, the service's own default.
    ///
    /// Returns a str, or an instance of `schema` where one is given, whose
    /// fields are then read as ordinary attributes. The response streams into
    /// the console as it arrives, and the session keeps every prompt and
    /// response, so a later turn can refer back to an earlier one. Await the
    /// result.
    ///
    /// ```python
    /// from agents import Agent
    /// from modeling import model
    ///
    /// @model
    /// class Recipe:
    ///     title: str
    ///     minutes: int
    ///
    /// agent = Agent()
    ///
    /// text = await agent.respond("Name a pasta dish")
    ///
    /// recipe = await agent.respond("A quick pasta dish", schema=Recipe)
    /// print(recipe.title)
    /// ```
    public func respond(_ prompt: String, schema: PyObject? = nil, reasoning: String? = nil) async throws -> PyObject {
        // Validated before anything is displayed, so a bad schema leaves no
        // "generating" card behind.
        var generationSchema: GenerationSchema?
        var makeModel: PyObject?

        if let schema {
            guard let json: [String: Any] = schema._schema,
                  let factory = schema._from_json else {
                throw PythonError.ValueError("Invalid schema. Use the modeling.model decorator on a class to create one.")
            }

            generationSchema = try GenerationSchema(pythonModelSchema: json)
            makeModel = factory
        }

        let reasoningLevel = try Self.reasoningLevel(named: reasoning)

        let response = Response()
        var session = try resolvedSession()
        let transcript = Array(session.transcript)

        do {
            try await stream(prompt, schema: generationSchema, makeModel: makeModel, reasoning: reasoningLevel, from: session, into: response)
        } catch {
            guard let failed = sessionModel,
                  let fallback = model.provider.fallback(after: error, on: failed) else {
                throw error
            }
            // Continues from the transcript as it was before the failed
            // request, so the prompt is not repeated.
            response.content = ""
            response.model = nil
            session = start(on: fallback.model, named: fallback.name, reasons: false, history: transcript)
            try await stream(prompt, schema: generationSchema, makeModel: makeModel, reasoning: nil, from: session, into: response)
        }

        response.isComplete = true

        if let makeModel {
            return try makeModel(response.content)
        }

        return PyObject { response.content.toPython($0) }
    }
}

extension Agent {
    /// Everything the session is made of, on `model`.
    nonisolated func profile(for model: any FoundationModels.LanguageModel) -> sending LanguageModelSession.AnyDynamicProfile {
        let instructions = instructions
        let tools: [any FoundationModels.Tool] = tools
        let skills = skills.map(\.skill)
        let activations = activations
        let base = LanguageModelSession.Profile {
            if let instructions {
                Instructions(instructions)
            }
            tools
            if !skills.isEmpty {
                Skills(activations: activations, skills: skills)
            }
        }
        let shaped = history?.apply(to: base, summarizer: model) ?? .init(erasing: base)
        return .init(erasing: shaped.model(model))
    }

    /// The reasoning level as the session takes it, checked before anything
    /// is sent. A string rather than the enum: only OS 27 has the enum, and
    /// the on-device model drops it either way.
    private static func reasoningLevel(named name: String?) throws(PythonError) -> String? {
        guard let name else { return nil }
        guard ["light", "moderate", "deep"].contains(name) else {
            throw .ValueError("reasoning must be 'light', 'moderate', or 'deep', not '\(name)'")
        }
        return name
    }

    private func stream(
        _ prompt: String,
        schema: GenerationSchema?,
        makeModel: PyObject?,
        reasoning: String?,
        from session: FoundationModels.LanguageModelSession,
        into response: Response
    ) async throws {
        if let reasoning, reasons {
            let level: ContextOptions.ReasoningLevel = switch reasoning {
            case "light": .light
            case "moderate": .moderate
            default: .deep
            }
            if let schema, let makeModel {
                let options = ContextOptions(includeSchemaInPrompt: true, reasoningLevel: level)
                for try await snapshot in session.streamResponse(to: prompt, schema: schema, contextOptions: options) {
                    response.content = snapshot.content.jsonString
                    let model: PyObject = try makeModel(response.content)
                    response.model = try py.repr(model.reference)
                }
            } else {
                let options = ContextOptions(reasoningLevel: level)
                for try await snapshot in session.streamResponse(to: prompt, contextOptions: options) {
                    response.content = snapshot.content
                }
            }
            return
        }
        if let schema, let makeModel {
            for try await snapshot in session.streamResponse(to: prompt, schema: schema) {
                response.content = snapshot.content.jsonString
                let model: PyObject = try makeModel(response.content)
                response.model = try py.repr(model.reference)
            }
        } else {
            for try await snapshot in session.streamResponse(to: prompt) {
                response.content = snapshot.content
            }
        }
    }
}

@Observable
private class Response {
    var content: String = ""
    var model: String?
    var isComplete = false
}

private struct PartialResponseContent: View {
    @State var response: Response

    var body: some View {
        if !response.isComplete {
            LogContainerView(tint: .yellow) {
                Label("Generating response", systemImage: "sparkles")
                    .font(.caption.bold())
                if response.content.isEmpty {
                    LoadingResponseView()
                } else {
                    ResponseText(response: response)
                }
            }
        } else {
            EmptyView()
        }
    }
}

private struct ResponseContent: View {
    @State var response: Response

    var body: some View {
        if !response.content.isEmpty {
            DisclosureLogContainerView(tint: .green) {
                ResponseText(response: response)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Response", systemImage: "checkmark.circle")
                    .font(.body.bold())
            }
        }
    }
}

private struct LoadingResponseView: View {
    var body: some View {
        Label("Loading model...", systemImage: "hourglass")
            .font(.caption)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
    }
}

private struct ResponseText: View {
    @State var response: Response

    var body: some View {
        MarkdownContent(model: Markdown(text: response.model ?? response.content))
            .animation(.default, value: response.content)
    }
}
