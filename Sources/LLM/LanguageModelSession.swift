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
    public init(instructions: String? = nil) {
        self.session = FoundationModels.LanguageModelSession(instructions: instructions)
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
    public func respond(_ prompt: String? = nil) async throws -> String {
        guard let prompt else {
            throw PythonError.AssertionError("Prompt is required")
        }

        let response = Response()
        Interpreter.onDisplay(AnyView(ResponseContent(response: response)))

        for try await snapshot in session.streamResponse(to: prompt) {
            response.content = snapshot.content
        }

        return response.content
    }
}

@Observable
private class Response {
    var content: String = ""
}

private struct ResponseContent: View {
    @State var response: Response

    var body: some View {
        LogContainerView(tint: .indigo) {
            Text(response.content)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
