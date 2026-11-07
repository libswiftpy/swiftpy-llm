//
//  ImageGeneration.swift
//  swiftpy-llm
//

import Foundation
import SwiftPy

/// What an image is generated with. What's left `nil` stays out of the request:
/// options differ by image model, and sending one it lacks is an error.
public struct ImageOptions: Sendable {
    public static let defaultModel = "gpt-image-2.6-flare"

    public var model: String
    public var size: String?
    public var quality: String?
    public var complexity: String?
    public var background: String?

    public init(
        model: String = defaultModel,
        size: String? = nil,
        quality: String? = nil,
        complexity: String? = nil,
        background: String? = nil
    ) {
        self.model = model
        self.size = size
        self.quality = quality
        self.complexity = complexity
        self.background = background
    }
}

/// A request of its own, with only the prompt: sent within a conversation, each
/// image would pay for its instructions, tools and history again.
struct ImageRequest: Encodable {
    struct Tool: Encodable {
        var type = "image_generation"
        var model: String
        var size: String?
        var quality: String?
        var complexity: String?
        var background: String?
    }

    struct ToolChoice: Encodable {
        var type = "image_generation"
    }

    var model: String
    var instructions = "Generate the image the user asks for."
    var input: [InputItem]
    var tools: [Tool]
    var toolChoice = ToolChoice()
    var stream = true
    var store = false

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, tools, stream, store
        case toolChoice = "tool_choice"
    }

    init(prompt: String, images: [Data], options: ImageOptions, model: String) {
        self.model = model
        let references = images.map { InputItem.Content.inputImage(Self.dataURL($0)) }
        input = [.message(role: "user", content: [.inputText(prompt)] + references)]
        tools = [Tool(
            model: options.model,
            size: options.size,
            quality: options.quality,
            complexity: options.complexity,
            background: options.background
        )]
    }

    private static func dataURL(_ image: Data) -> String {
        let type = image.starts(with: [0xFF, 0xD8]) ? "jpeg" : "png"
        return "data:image/\(type);base64,\(image.base64EncodedString())"
    }
}

enum ImageGeneration {
    /// The image a request made, encoded as the API returned it.
    static func generate(
        _ request: ImageRequest,
        credential: ResponsesLanguageModel.Credential,
        url: URL = ResponsesLanguageModel.defaultURL,
        session: URLSession? = nil
    ) async throws -> Data {
        let token: String
        let usesPlan: Bool
        switch credential {
        case .apiKey(let key):
            (token, usesPlan) = (key, false)
        case .chatGPTPlan:
            (token, usesPlan) = (try await ChatGPTAccount.shared.accessToken(), true)
        }

        var urlRequest = URLRequest(url: url.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (bytes, response) = try await (session ?? .images).bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ResponsesLanguageModel.RequestError.invalidStreamData
        }
        guard http.statusCode == 200 else {
            let data = try await bytes.reduce(into: Data()) { $0.append($1) }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init).map { Date(timeIntervalSinceNow: $0) }
            throw ResponsesLanguageModel.Executor.error(
                statusCode: http.statusCode, body: data, retryAfter: retryAfter, usesPlan: usesPlan
            )
        }

        var image: Data?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard json != "[DONE]", let data = json.data(using: .utf8) else { continue }
            guard let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else {
                throw ResponsesLanguageModel.RequestError.invalidStreamData
            }
            switch event.type {
            case "response.output_item.done":
                if event.item?.type == "image_generation_call", let result = event.item?.result {
                    image = Data(base64Encoded: result)
                }
            case "response.failed", "error":
                let error = event.response?.error ?? event.error
                throw ResponsesLanguageModel.error(
                    status: nil, type: error?.type, code: error?.code ?? event.code,
                    message: error?.message ?? event.message ?? json, usesPlan: usesPlan
                )
            default:
                break
            }
        }
        guard let image else {
            throw ResponsesLanguageModel.APIError(message: "OpenAI returned no image.", type: nil, code: nil)
        }
        return image
    }
}

private extension URLSession {
    /// An image can take minutes between events.
    static let images: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        return URLSession(configuration: configuration)
    }()
}

extension ChatGPTLanguageModel {
    /// An image from `prompt`, with `images` as references or to edit. This model
    /// only starts the image tool, so a cheap one does; `options` names the image model.
    /// Always on the API key: OpenAI doesn't offer image generation on a ChatGPT plan.
    public func generateImage(
        prompt: String,
        images: [Data] = [],
        options: ImageOptions = ImageOptions()
    ) async throws -> Data {
        guard let key = apiKey?.value, !key.isEmpty else {
            throw PythonError.RuntimeError("Generating images needs an OpenAI API key, even when signed in with ChatGPT.")
        }
        return try await ImageGeneration.generate(
            ImageRequest(prompt: prompt, images: images, options: options, model: name),
            credential: .apiKey(key)
        )
    }
}
