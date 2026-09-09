import SwiftPy
import SwiftPyViews
import SwiftUI
import FoundationModels

#if swift(>=6.4)
/// A language model an ``agents.Agent`` runs on, in place of the system default.
@Scriptable
@MainActor
@available(anyAppleOS 27.0, *)
public class LanguageModel {
    internal let model: any FoundationModels.LanguageModel

    internal init(model: any FoundationModels.LanguageModel) {
        self.model = model
    }
}

@available(anyAppleOS 27.0, *)
extension LanguageModel {
    public convenience init(_ model: any FoundationModels.LanguageModel) {
        self.init(model: model)
    }
}
#endif

/// A session that holds a conversation with a language model.
@Scriptable
@MainActor
public class Agent {
    internal let session: FoundationModels.LanguageModelSession

    /// Starts a session with the on-device system model.
    ///
    /// instructions: Standing guidance the model follows for every prompt in the session, such as its role and the style to answer in. Defaults to None.
    /// tools: Functions the model may call, each one built by the ``agents.tool`` decorator. Defaults to None.
    public init(instructions: String? = nil, tools: [Tool]? = nil) {
        self.session = FoundationModels.LanguageModelSession(
            tools: tools ?? [],
            instructions: instructions
        )
    }

#if no
    public init(model: PyObject, instructions: String? = nil, tools: [Tool]? = nil) throws(PythonError) {
        guard #available(anyAppleOS 27, *) else {
            throw .AssertionError("This feature is only supported on iOS 27 and above")
        }

        guard let container = LanguageModel(model) else {
            throw .TypeError("Invalid model type")
        }

        session = FoundationModels.LanguageModelSession(
            model: container.model,
            tools: tools ?? [],
            instructions: instructions
        )
    }
#endif

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
        //Interpreter.interface.display(AnyView(PartialResponseContent(response: response)))

        if let generationSchema, let makeModel {
            for try await snapshot in session.streamResponse(to: prompt, schema: generationSchema) {
                response.content = snapshot.content.jsonString
                let model: PyObject = try makeModel(response.content)
                response.model = try py.repr(model.reference)
            }
        } else {
            for try await snapshot in session.streamResponse(to: prompt) {
                response.content = snapshot.content
            }
        }

        response.isComplete = true
        Interpreter.interface.display(AnyView(ResponseContent(response: response)))

        if let makeModel {
            return try makeModel(response.content)
        }

        return PyObject { response.content.toPython($0) }
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
