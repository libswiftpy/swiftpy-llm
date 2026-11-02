//
//  ResponsesLanguageModel.swift
//  swiftpy-llm
//

import Foundation
import FoundationModels
import CoreImage
import UniformTypeIdentifiers

/// A model behind OpenAI's Responses API, streamed into FoundationModels:
/// the shape of `ChatCompletionsLanguageModel`, as GPT-6 calls tools only
/// through Responses.
public struct ResponsesLanguageModel: Sendable, LanguageModel {
    public var name: String
    /// The API's base, `/responses` appended.
    public var url: URL
    public var credential: Credential
    // Tests inject one with a mock protocol.
    var urlSession: URLSession?

    public static let defaultURL = URL(string: "https://api.openai.com/v1")!

    /// What requests are paid with.
    public enum Credential: Sendable, Hashable {
        case apiKey(String)
        /// The ChatGPT account's plan, signed in with ``ChatGPTAccount``.
        case chatGPTPlan
    }

    public init(name: String, credential: Credential, url: URL = defaultURL) {
        self.name = name
        self.credential = credential
        self.url = url
    }

    public init(name: String, apiKey: String, url: URL = defaultURL) {
        self.init(name: name, credential: .apiKey(apiKey), url: url)
    }

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.vision, .toolCalling, .reasoning, .guidedGeneration])
    }

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(modelName: name, url: url, credential: credential, urlSession: urlSession)
    }

    /// An error the API reported.
    public struct APIError: LocalizedError {
        public var message: String
        public var type: String?
        public var code: String?

        public var errorDescription: String? { message }
    }

    public enum RequestError: LocalizedError {
        /// The API key was refused.
        case unauthorized(String)
        /// Out of credits, or at a spend or usage limit: trying again won't help.
        case billing(code: String?, message: String)
        case httpError(statusCode: Int, message: String)
        case invalidStreamData

        public var errorDescription: String? {
            switch self {
            case .unauthorized(let message): message
            case .billing(let code, let message):
                switch code {
                case "credit_balance_exhausted", "insufficient_quota":
                    "Your OpenAI account has no credits left. Add credits at platform.openai.com to continue."
                case "organization_spend_limit_exceeded":
                    "Your OpenAI organization reached its spend limit. Raise it at platform.openai.com to continue."
                case "project_spend_limit_exceeded":
                    "Your OpenAI project reached its spend limit. Raise it in the project's settings at platform.openai.com."
                case "organization_usage_limit_exceeded":
                    "Your OpenAI organization reached its usage limit. Ask OpenAI for a higher one to continue."
                case "subscription_sharing_usage_limit_exceeded":
                    "This app reached its limit on your ChatGPT plan. See ChatGPT Settings → Usage."
                case "subscription_sharing_user_not_eligible":
                    "ChatGPT plan use isn't available for this account or workspace."
                default: message
                }
            case .httpError(let statusCode, let message): "HTTP error \(statusCode): \(message)"
            case .invalidStreamData: "Invalid streaming data received"
            }
        }
    }

    /// The codes OpenAI bills under, which another try doesn't clear.
    static let billingCodes: Set<String> = [
        "credit_balance_exhausted", "insufficient_quota",
        "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
        "organization_usage_limit_exceeded",
        "subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible",
    ]

    /// An error the API reported, in a response or in the stream, as the
    /// framework's where it has one; see OpenAI's error codes guide.
    static func error(
        status: Int?,
        type: String?,
        code: String?,
        message: String,
        retryAfter: Date? = nil,
        usesPlan: Bool = false
    ) -> any Error {
        if let code, billingCodes.contains(code) {
            return RequestError.billing(code: code, message: message)
        }
        if type == "insufficient_quota" {
            return RequestError.billing(code: type, message: message)
        }
        if code == "context_length_exceeded" {
            return LanguageModelError.contextSizeExceeded(.init(contextSize: 0, tokenCount: 0, debugDescription: message))
        }
        // Signed in, it's the sign-in that failed, not a key to replace.
        if usesPlan, status == 401 || code == "subscription_sharing_invalid_user" {
            return ChatGPTSignInError.signInExpired
        }
        if status == 401 || code == "invalid_api_key" {
            return RequestError.unauthorized(message)
        }
        // Throttled, overloaded or briefly unavailable: the same request works later.
        if status == 429 || status == 503 || type == "rate_limit_error"
            || ["rate_limit_exceeded", "slow_down", "server_is_overloaded",
                "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"].contains(code) {
            return LanguageModelError.rateLimited(.init(resetDate: retryAfter, debugDescription: message))
        }
        return APIError(message: message, type: type, code: code)
    }

    public struct Executor: LanguageModelExecutor {
        public typealias Model = ResponsesLanguageModel
        private let configuration: Configuration

        public init(configuration: Configuration) {
            self.configuration = configuration
        }

        public struct Configuration: Hashable, Sendable {
            fileprivate let modelName: String
            fileprivate let url: URL
            fileprivate let credential: Credential
            fileprivate let urlSession: URLSession?

            public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
                lhs.modelName == rhs.modelName && lhs.url == rhs.url && lhs.credential == rhs.credential
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(modelName)
                hasher.combine(url)
                hasher.combine(credential)
            }
        }

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ResponsesLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let token: String
            let usesPlan: Bool
            switch configuration.credential {
            case .apiKey(let key):
                (token, usesPlan) = (key, false)
            case .chatGPTPlan:
                (token, usesPlan) = (try await ChatGPTAccount.shared.accessToken(), true)
            }
            let body = try ResponsesRequest(request, model: configuration.modelName, usesPlan: usesPlan)
            var urlRequest = URLRequest(url: configuration.url.appendingPathComponent("responses"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Sorted, as tool schemas encode their keys in a new order each time,
            // which changes the prompt's prefix and misses the cache.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            urlRequest.httpBody = try encoder.encode(body)

            let session = configuration.urlSession ?? URLSession(configuration: .ephemeral)
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw RequestError.invalidStreamData }
            guard http.statusCode == 200 else {
                let data = try await bytes.reduce(into: Data()) { $0.append($1) }
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init).map { Date(timeIntervalSinceNow: $0) }
                throw Self.error(statusCode: http.statusCode, body: data, retryAfter: retryAfter, usesPlan: usesPlan)
            }

            var translator = StreamTranslator(usesPlan: usesPlan)
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard json != "[DONE]", let data = json.data(using: .utf8) else { continue }
                var event: StreamEvent
                do {
                    event = try JSONDecoder().decode(StreamEvent.self, from: data)
                } catch {
                    throw RequestError.invalidStreamData
                }
                event.raw = json
                try await translator.translate(event, into: channel)
            }
        }

        /// A failed request's error.
        static func error(statusCode: Int, body: Data, retryAfter: Date? = nil, usesPlan: Bool = false) -> any Error {
            guard let apiError = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error else {
                // Plan use can be refused before the request starts, as `{"detail": ...}`.
                let detail = (try? JSONDecoder().decode([String: String].self, from: body))?["detail"]
                let message = detail ?? String(decoding: body, as: UTF8.self)
                return statusCode == 401 || statusCode == 429 || statusCode == 503
                    ? ResponsesLanguageModel.error(
                        status: statusCode, type: nil, code: nil, message: message,
                        retryAfter: retryAfter, usesPlan: usesPlan
                    )
                    : RequestError.httpError(statusCode: statusCode, message: message)
            }
            return ResponsesLanguageModel.error(
                status: statusCode, type: apiError.type, code: apiError.code,
                message: apiError.message, retryAfter: retryAfter, usesPlan: usesPlan
            )
        }
    }
}

// MARK: - Request

/// Where a reasoning item's ID and encrypted content are kept, in metadata
/// rather than the signature, so another model's bridge doesn't replay it.
let reasoningMetadataKey = "openai.reasoning"

struct ResponsesRequest: Encodable {
    var model: String
    var instructions: String?
    var input: [InputItem]
    var tools: [Tool]?
    var toolChoice: String?
    var text: TextOptions?
    var reasoning: Reasoning
    var maxOutputTokens: Int?
    // Keeps a conversation's turns on one cache; without it they rarely hit.
    var promptCacheKey: String?
    var stream = true
    var store = false
    var include = ["reasoning.encrypted_content"]

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, tools, text, reasoning, stream, store, include
        case toolChoice = "tool_choice"
        case maxOutputTokens = "max_output_tokens"
        case promptCacheKey = "prompt_cache_key"
    }

    /// What a request signed in with ChatGPT groups its functions under, as
    /// plan use takes no top-level ones.
    static let toolNamespace = "app"

    enum Tool: Encodable {
        case function(FunctionTool)
        case namespace(name: String, description: String, tools: [FunctionTool])

        enum Keys: String, CodingKey { case type, name, description, tools }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .function(let function):
                try function.encode(to: encoder)
            case .namespace(let name, let description, let tools):
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode("namespace", forKey: .type)
                try container.encode(name, forKey: .name)
                try container.encode(description, forKey: .description)
                try container.encode(tools, forKey: .tools)
            }
        }
    }

    struct FunctionTool: Encodable {
        var type = "function"
        var name: String
        var description: String
        var parameters: GenerationSchema
        // Strict needs every property required; a tool's optional ones aren't.
        var strict = false
    }

    struct TextOptions: Encodable {
        var format: Format

        struct Format: Encodable {
            var type = "json_schema"
            var name: String
            var schema: GenerationSchema
            var strict = true
        }
    }

    struct Reasoning: Encodable {
        var effort: String?
        var summary = "auto"
    }

    init(_ request: LanguageModelExecutorGenerationRequest, model: String, usesPlan: Bool = false) throws {
        self.model = model
        var instructions: [String] = []
        input = try Self.items(
            from: request.transcript, instructions: &instructions,
            namespace: usesPlan ? Self.toolNamespace : nil
        )
        self.instructions = instructions.isEmpty ? nil : instructions.joined(separator: "\n\n")
        promptCacheKey = request.transcript.first?.id
        let definitions = request.enabledToolDefinitions
        let functions = definitions.map {
            FunctionTool(name: $0.name, description: $0.description, parameters: $0.parameters)
        }
        if !functions.isEmpty {
            tools = usesPlan
                ? [.namespace(name: Self.toolNamespace, description: "The app's tools.", tools: functions)]
                : functions.map(Tool.function)
        }
        if !definitions.isEmpty {
            toolChoice = switch request.generationOptions.toolCallingMode?.kind {
            case .required: "required"
            case .disallowed: "none"
            default: "auto"
            }
        }
        text = request.schema.map { TextOptions(format: .init(name: $0.name, schema: $0)) }
        reasoning = Reasoning(effort: Self.effort(request.contextOptions.reasoningLevel))
        // Plan use takes no output limit.
        maxOutputTokens = usesPlan ? nil : request.generationOptions.maximumResponseTokens
    }

    /// The level as `reasoning.effort`; none leaves the model's default.
    static func effort(_ level: ContextOptions.ReasoningLevel?) -> String? {
        switch level {
        case .light: "low"
        case .moderate: "medium"
        case .deep: "high"
        // Such as "xhigh" or "max".
        case .custom(let effort): effort
        case nil: nil
        @unknown default: nil
        }
    }

    static func items(
        from transcript: Transcript,
        instructions: inout [String],
        namespace: String? = nil
    ) throws -> [InputItem] {
        var items: [InputItem] = []
        for entry in transcript {
            switch entry {
            case .instructions(let entry):
                instructions.append(text(of: entry.segments))
            case .prompt(let prompt):
                items.append(.message(role: "user", content: try prompt.segments.map(content)))
            case .response(let response):
                items.append(.message(role: "assistant", content: [.outputText(text(of: response.segments))]))
            case .toolCalls(let calls):
                for call in calls {
                    items.append(.functionCall(
                        callID: call.id, name: call.toolName,
                        arguments: stableJSON(call.arguments), namespace: namespace
                    ))
                }
            case .toolOutput(let output):
                items.append(.functionCallOutput(callID: output.id, output: text(of: output.segments)))
            case .reasoning(let reasoning):
                // Only OpenAI's own, which the API can check.
                guard let stored = reasoning.metadata[reasoningMetadataKey],
                      let json = try? stored.value(String.self),
                      let item = try? JSONDecoder().decode(StoredReasoning.self, from: Data(json.utf8))
                else { continue }
                let summary = text(of: reasoning.segments)
                items.append(.reasoning(id: item.id, encryptedContent: item.encryptedContent, summary: summary))
            @unknown default:
                continue
            }
        }
        return items
    }

    private static func content(_ segment: Transcript.Segment) throws -> InputItem.Content {
        switch segment {
        case .text(let text):
            return .inputText(text.content)
        case .structure(let structure):
            return .inputText(stableJSON(structure.content))
        case .attachment(let attachment):
            guard case .image(let image) = attachment.content else {
                throw LanguageModelError.unsupportedTranscriptContent(
                    .init(unsupportedContent: [], debugDescription: "Only images can be attached.")
                )
            }
            return .inputImage("data:image/jpeg;base64,\(image.cgImage.jpegData().base64EncodedString())")
        @unknown default:
            throw LanguageModelError.unsupportedTranscriptContent(
                .init(unsupportedContent: [], debugDescription: "Unknown segment type.")
            )
        }
    }

    /// `jsonString` orders keys anew each time; sorted, a replayed turn keeps
    /// the prompt's prefix, and so its cache.
    static func stableJSON(_ content: GeneratedContent) -> String {
        let json = content.jsonString
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
              )
        else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): stableJSON(structure.content)
            default: nil
            }
        }.joined(separator: "\n")
    }
}

struct StoredReasoning: Codable {
    var id: String
    var encryptedContent: String?
}

enum InputItem: Encodable {
    case message(role: String, content: [Content])
    case functionCall(callID: String, name: String, arguments: String, namespace: String?)
    case functionCallOutput(callID: String, output: String)
    case reasoning(id: String, encryptedContent: String?, summary: String)

    enum Content: Encodable {
        case inputText(String)
        case outputText(String)
        case inputImage(String)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .inputText(let text):
                try container.encode("input_text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .outputText(let text):
                try container.encode("output_text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .inputImage(let url):
                try container.encode("input_image", forKey: .type)
                try container.encode(url, forKey: .imageURL)
            }
        }
    }

    enum Keys: String, CodingKey {
        case type, role, content, name, arguments, output, id, summary, text, namespace
        case callID = "call_id"
        case encryptedContent = "encrypted_content"
        case imageURL = "image_url"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .message(let role, let content):
            try container.encode("message", forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case .functionCall(let callID, let name, let arguments, let namespace):
            try container.encode("function_call", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
            try container.encodeIfPresent(namespace, forKey: .namespace)
        case .functionCallOutput(let callID, let output):
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(output, forKey: .output)
        case .reasoning(let id, let encryptedContent, let summary):
            try container.encode("reasoning", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(encryptedContent, forKey: .encryptedContent)
            let parts = summary.isEmpty ? [] : [["type": "summary_text", "text": summary]]
            try container.encode(parts, forKey: .summary)
        }
    }
}

// MARK: - Stream

struct ErrorEnvelope: Decodable {
    var error: Body

    struct Body: Decodable {
        var message: String
        var type: String?
        var code: String?
    }
}

/// One server-sent event: only the fields the translator reads.
struct StreamEvent: Decodable {
    var type: String
    var delta: String?
    var itemID: String?
    var summaryIndex: Int?
    var item: Item?
    var response: Response?
    var message: String?
    var code: String?
    /// An `error` event's details, which some servers nest.
    var error: ErrorEnvelope.Body?
    /// The event as sent, for an error that says nothing else.
    var raw = ""

    enum CodingKeys: String, CodingKey {
        case type, delta, item, response, message, code, error
        case itemID = "item_id"
        case summaryIndex = "summary_index"
    }

    struct Item: Decodable {
        var type: String
        var id: String?
        var callID: String?
        var name: String?
        var arguments: String?
        var encryptedContent: String?

        enum CodingKeys: String, CodingKey {
            case type, id, name, arguments
            case callID = "call_id"
            case encryptedContent = "encrypted_content"
        }
    }

    struct Response: Decodable {
        var usage: Usage?
        var error: ErrorEnvelope.Body?
    }

    struct Usage: Decodable {
        var inputTokens: Int
        var outputTokens: Int
        var inputTokensDetails: InputDetails?
        var outputTokensDetails: OutputDetails?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case inputTokensDetails = "input_tokens_details"
            case outputTokensDetails = "output_tokens_details"
        }

        struct InputDetails: Decodable {
            var cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }

        struct OutputDetails: Decodable {
            var reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }
    }
}

/// Events into channel sends, one entry per kind for the response and tool
/// calls, and one per reasoning item, which the API replays by its ID.
struct StreamTranslator {
    /// Whether the request used the ChatGPT plan, which changes what a 401 means.
    let usesPlan: Bool
    private let responseEntryID = UUID().uuidString
    private let toolCallsEntryID = UUID().uuidString
    /// A function call's item ID to its call ID and name.
    private var calls: [String: (callID: String, name: String)] = [:]
    /// Calls whose arguments came in deltas, so `done` doesn't repeat them.
    private var streamedArguments: Set<String> = []
    private var summaryIndex: [String: Int] = [:]

    init(usesPlan: Bool = false) {
        self.usesPlan = usesPlan
    }

    mutating func translate(_ event: StreamEvent, into channel: LanguageModelExecutorGenerationChannel) async throws {
        switch event.type {
        case "response.output_text.delta":
            guard let delta = event.delta else { return }
            await channel.send(.response(entryID: responseEntryID, action: .appendText(delta, tokenCount: 1)))

        case "response.reasoning_summary_text.delta":
            guard var delta = event.delta, let itemID = event.itemID else { return }
            // A new part of the summary starts a paragraph.
            if let index = event.summaryIndex {
                if let last = summaryIndex[itemID], last != index { delta = "\n\n" + delta }
                summaryIndex[itemID] = index
            }
            await channel.send(.reasoning(entryID: itemID, action: .appendText(delta, tokenCount: 1)))

        case "response.output_item.added":
            guard let item = event.item, item.type == "function_call",
                  let id = item.id, let callID = item.callID, let name = item.name else { return }
            calls[id] = (callID, name)

        case "response.function_call_arguments.delta":
            guard let itemID = event.itemID, let call = calls[itemID], let delta = event.delta else { return }
            streamedArguments.insert(itemID)
            await send(arguments: delta, for: call, into: channel)

        case "response.output_item.done":
            guard let item = event.item, let id = item.id else { return }
            if item.type == "function_call", !streamedArguments.contains(id) {
                let call = calls[id] ?? (item.callID ?? id, item.name ?? "")
                await send(arguments: item.arguments ?? "{}", for: call, into: channel)
            } else if item.type == "reasoning" {
                let stored = StoredReasoning(id: id, encryptedContent: item.encryptedContent)
                let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
                await channel.send(.reasoning(entryID: id, action: .updateMetadata([reasoningMetadataKey: json])))
            }

        case "response.completed", "response.incomplete":
            guard let usage = event.response?.usage else { return }
            // After the content, so the API's totals replace the counted deltas.
            await channel.send(.response(entryID: responseEntryID, action: .updateUsage(
                input: .init(
                    totalTokenCount: usage.inputTokens,
                    cachedTokenCount: usage.inputTokensDetails?.cachedTokens ?? 0
                ),
                output: .init(
                    totalTokenCount: usage.outputTokens,
                    reasoningTokenCount: usage.outputTokensDetails?.reasoningTokens ?? 0
                )
            )))

        case "response.failed":
            let error = event.response?.error
            throw ResponsesLanguageModel.error(
                status: nil, type: error?.type, code: error?.code, message: error?.message ?? event.raw,
                usesPlan: usesPlan
            )

        case "error":
            throw ResponsesLanguageModel.error(
                status: nil,
                type: event.error?.type,
                code: event.code ?? event.error?.code,
                message: event.message ?? event.error?.message ?? event.raw,
                usesPlan: usesPlan
            )

        default:
            return
        }
    }

    private func send(
        arguments: String,
        for call: (callID: String, name: String),
        into channel: LanguageModelExecutorGenerationChannel
    ) async {
        await channel.send(.toolCalls(
            entryID: toolCallsEntryID,
            action: .toolCall(id: call.callID, name: call.name, action: .appendArguments(arguments, tokenCount: 1))
        ))
    }
}

private extension CGImage {
    func jpegData() -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, self, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
