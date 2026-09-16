import SwiftPy
import SwiftPyViews
import SwiftUI
import FoundationModels

/// A session that holds a conversation with a language model.
@Scriptable
@MainActor
public class Agent {
    private let instructions: String?
    private let tools: [Tool]
    private var session: FoundationModels.LanguageModelSession?
    private var usesPrivateCloudCompute = false
    // Once a request could not reach Private Cloud Compute, agents started
    // soon after go on-device instead of each failing the same way first; a
    // later one tries again, so a dropped connection is not the whole day.
    private static var privateCloudComputeFailedAt: Date?
    private static let privateCloudComputeRetryInterval: TimeInterval = 5 * 60

    private static var privateCloudComputeFailedRecently: Bool {
        guard let failedAt = privateCloudComputeFailedAt else { return false }
        return Date().timeIntervalSince(failedAt) < privateCloudComputeRetryInterval
    }

    private var modelName: String?

    /// The model the session runs on: `"Private Cloud Compute"` or
    /// `"On-device"`, or `None` before the first response.
    public var model: String? { modelName }

    /// Starts a session with a language model. On iOS 27 and later this is
    /// Private Cloud Compute when it is available, otherwise the on-device model.
    ///
    /// instructions: Standing guidance the model follows for every prompt in the session, such as its role and the style to answer in. Defaults to None.
    /// tools: Functions the model may call, each one built by the ``agents.tool`` decorator. Defaults to None.
    public init(instructions: String? = nil, tools: [Tool]? = nil) {
        self.instructions = instructions
        self.tools = tools ?? []
    }

    // Resolved on the first response rather than in init, the async place a
    // model may also have to ask for credentials.
    private func resolvedSession() throws(PythonError) -> FoundationModels.LanguageModelSession {
        if let session {
            return session
        }

#if swift(>=6.4)
        if #available(anyAppleOS 27, *), !Self.privateCloudComputeFailedRecently {
            let cloud = PrivateCloudComputeLanguageModel()
            if cloud.isAvailable {
                let session = FoundationModels.LanguageModelSession(
                    model: cloud,
                    tools: tools,
                    instructions: instructions
                )
                self.session = session
                usesPrivateCloudCompute = true
                modelName = "Private Cloud Compute"
                return session
            }
        }
#endif

        let onDevice = SystemLanguageModel.default
        if case let .unavailable(reason) = onDevice.availability {
            throw .RuntimeError(Self.message(for: reason))
        }

        let session = FoundationModels.LanguageModelSession(
            model: onDevice,
            tools: tools,
            instructions: instructions
        )
        self.session = session
        usesPrivateCloudCompute = false
        modelName = "On-device"
        return session
    }

    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled."
        case .deviceNotEligible:
            "This device does not support Apple Intelligence."
        case .modelNotReady:
            "The model is not ready yet."
        @unknown default:
            "The model is unavailable."
        }
    }

    /// Continues the conversation on the on-device model, from the transcript
    /// as it was before the failed request so the prompt is not repeated.
    private func fallBackToDevice(transcript: Transcript) -> FoundationModels.LanguageModelSession {
        let session = FoundationModels.LanguageModelSession(
            model: .default,
            tools: tools,
            transcript: transcript
        )
        self.session = session
        usesPrivateCloudCompute = false
        modelName = "On-device"
        return session
    }

    /// The innermost error: the ones around it say "error -1" and little
    /// else, the inner one carries the code that names the cause.
    private static func describe(_ error: any Error) -> String {
        var inner = error as NSError
        while let next = inner.underlyingErrors.first as NSError? {
            inner = next
        }
        return "\(inner.domain) \(inner.code)"
    }

    /// Whether a failure is about reaching the model rather than about what
    /// was asked: the on-device model gives the same answer to the latter.
    private static func canRetryOnDevice(_ error: any Error) -> Bool {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return true
        }
        switch generation {
        case .guardrailViolation, .refusal, .exceededContextWindowSize,
             .unsupportedGuide, .unsupportedLanguageOrLocale, .decodingFailure:
            return false
        default:
            return true
        }
    }

    /// Produces a response to a prompt.
    ///
    /// prompt: What to ask the model.
    /// schema: A class decorated with ``modeling.model``, to answer with an instance of it instead of text. Its annotated fields are the structure the model fills in, and defaults on them are offered to the model as defaults. Defaults to None.
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
    public func respond(_ prompt: String, schema: PyObject? = nil) async throws -> PyObject {
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

        let response = Response()
        var session = try resolvedSession()
        let transcript = session.transcript

        do {
            try await stream(prompt, schema: generationSchema, makeModel: makeModel, from: session, into: response)
        } catch where usesPrivateCloudCompute && Self.canRetryOnDevice(error) {
            // No network, daily quota reached, the service down, or the app
            // not yet entitled. Said on stderr: the on-device answer reads
            // differently, and nothing else shows which model answered.
            Self.privateCloudComputeFailedAt = Date()
            _ = try? py.module("sys")?.throwing.stderr.write(
                "Private Cloud Compute did not answer (\(Self.describe(error))); continuing on the on-device model.\n"
            )
            response.content = ""
            response.model = nil
            session = fallBackToDevice(transcript: transcript)
            try await stream(prompt, schema: generationSchema, makeModel: makeModel, from: session, into: response)
        }

        response.isComplete = true

        if let makeModel {
            return try makeModel(response.content)
        }

        return PyObject { response.content.toPython($0) }
    }
}

extension Agent {
    private func stream(
        _ prompt: String,
        schema: GenerationSchema?,
        makeModel: PyObject?,
        from session: FoundationModels.LanguageModelSession,
        into response: Response
    ) async throws {
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
