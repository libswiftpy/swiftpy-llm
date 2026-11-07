//
//  ImageGenerationTests.swift
//  swiftpy-llm
//

import Testing
import Foundation
@testable import OpenAI

extension OpenAISuite {
    @Suite(.serialized)
    struct ImageGenerationTests {
        private let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockResponses.self]
            return URLSession(configuration: configuration)
        }()
        private let image = Data([1, 2, 3, 4])

        private func events(_ events: [String]) -> String {
            events.map { "data: \($0)\n" }.joined(separator: "\n")
        }

        private func generate(_ options: ImageOptions = ImageOptions(), images: [Data] = []) async throws -> Data {
            try await ImageGeneration.generate(
                ImageRequest(prompt: "A fox", images: images, options: options, model: "gpt-6-luna"),
                credential: .apiKey("key"),
                url: URL(string: "https://mock-openai.test/v1")!,
                session: session
            )
        }

        private var imageEvent: String {
            #"{"type":"response.output_item.done","item":{"type":"image_generation_call","id":"ig_1","result":"\#(image.base64EncodedString())"}}"#
        }

        @Test func theImageModelGoesOnTheTool() async throws {
            MockResponses.reset { _, _ in (200, self.events([self.imageEvent])) }

            let result = try await generate(ImageOptions(model: "gpt-image-2.6-sunburst", size: "1536x1024"))

            #expect(result == image)
            let body = try #require(MockResponses.bodies.first)
            #expect(body["model"] as? String == "gpt-6-luna")
            #expect(body["store"] as? Bool == false)
            #expect((body["tool_choice"] as? [String: Any])?["type"] as? String == "image_generation")
            let tool = try #require((body["tools"] as? [[String: Any]])?.first)
            #expect(tool["type"] as? String == "image_generation")
            #expect(tool["model"] as? String == "gpt-image-2.6-sunburst")
            #expect(tool["size"] as? String == "1536x1024")
        }

        @Test func unsetOptionsStayOutOfTheRequest() async throws {
            MockResponses.reset { _, _ in (200, self.events([self.imageEvent])) }

            _ = try await generate()

            let tool = try #require((MockResponses.bodies.first?["tools"] as? [[String: Any]])?.first)
            #expect(tool["model"] as? String == "gpt-image-2.6-flare")
            #expect(Set(tool.keys) == ["type", "model"])
        }

        @Test func referencesFollowThePrompt() async throws {
            MockResponses.reset { _, _ in (200, self.events([self.imageEvent])) }

            _ = try await generate(images: [Data([0xFF, 0xD8, 0x01])])

            let input = try #require(MockResponses.bodies.first?["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            #expect(content.map { $0["type"] as? String } == ["input_text", "input_image"])
            #expect((content[1]["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        }

        @Test func aStreamWithoutAnImageFails() async throws {
            MockResponses.reset { _, _ in (200, self.events([#"{"type":"response.completed","response":{}}"#])) }

            await #expect(throws: ResponsesLanguageModel.APIError.self) { try await generate() }
        }

        @Test func aFailedResponseSaysWhy() async throws {
            let failed = #"{"type":"response.failed","response":{"error":{"code":"moderation_blocked","message":"Blocked"}}}"#
            MockResponses.reset { _, _ in (200, self.events([failed])) }

            do {
                _ = try await generate()
                Issue.record("expected the request to fail")
            } catch {
                #expect(error.localizedDescription.contains("Blocked"))
            }
        }

        @Test func aRefusedKeyIsReported() async throws {
            MockResponses.reset { _, _ in (401, #"{"error":{"message":"Bad key","code":"invalid_api_key"}}"#) }

            await #expect(throws: ResponsesLanguageModel.RequestError.self) { try await generate() }
        }
    }
}
