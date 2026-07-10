import SwiftPy
import SwiftUI
import FoundationModels

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

/// An object that represents a session that interacts with a language model.
@Scriptable
@MainActor
public class LanguageModelSession {
    internal let session: FoundationModels.LanguageModelSession

    /// Start a new session with instructions.
    public init(tools: [Tool]? = nil, instructions: String? = nil) {
        self.session = FoundationModels.LanguageModelSession(
            tools: tools ?? [],
            instructions: instructions
        )
    }

    public init(model: PyObject, instructions: String? = nil) throws(PythonError) {
        guard #available(anyAppleOS 27, *) else {
            throw .AssertionError("This feature is only supported on iOS 27 and above")
        }

        guard let container = LanguageModel(model) else {
            throw .TypeError("Invalid model type")
        }

        session = FoundationModels.LanguageModelSession(model: container.model, instructions: instructions)
    }

    /// Produces a response to a prompt.
    public func respond(_ prompt: String) async throws -> String {
        let response = Response()

        for try await snapshot in session.streamResponse(to: prompt) {
            response.content = snapshot.content
        }
        
        Interpreter.onDisplay(AnyView(ResponseContent(response: response)))

        return response.content
    }

    /// Produces a structured response to a prompt conforming to the given schema.
    public func respond(_ prompt: String, schema: PyObject) async throws -> PyObject {
        guard let json: [String: Any] = schema._schema,
              let makeModel = schema._from_json else {
            throw PythonError.ValueError("Invalid schema. Use models.model decorator on a class to create a schema.")
        }

        let response = Response()
        Interpreter.onDisplay(AnyView(ResponseContent(response: response)))

        let generationSchema = try GenerationSchema(pythonModelSchema: json)

        for try await snapshot in session.streamResponse(to: prompt, schema: generationSchema) {
            response.content = snapshot.content.jsonString
            let model: PyObject = try makeModel(response.content)
            response.model = try py.repr(model.reference)
        }

        return try makeModel(response.content)
    }
}

@Observable
private class Response {
    var content: String = ""
    var model: String?
}

private struct ResponseContent: View {
    @State var response: Response

    var body: some View {
        if !response.content.isEmpty {
            LogContainerView(tint: .yellow) {
                Text(response.model ?? response.content)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.default, value: response.content)
            }
        }
    }
}
