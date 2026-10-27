//
//  ResponsesTests.swift
//  swiftpy-llm
//

import Testing
import Foundation
import FoundationModels
import Agents
@testable import OpenAI

/// Answers requests to "mock-openai.test" with canned server-sent events.
final class MockResponses: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((_ body: [String: Any], _ count: Int) -> (status: Int, body: String))?
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var authorizations: [String] = []

    static func reset(_ handler: @escaping (_ body: [String: Any], _ count: Int) -> (status: Int, body: String)) {
        self.handler = handler
        bodies = []
        authorizations = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock-openai.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            data = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) }
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.bodies.append(body)
        Self.authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        let (status, text) = Self.handler?(body, Self.bodies.count) ?? (200, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func events(_ events: [String]) -> String {
    events.map { "event: x\ndata: \($0)\n" }.joined(separator: "\n")
}

private let completed = #"{"type":"response.completed","response":{"usage":{"input_tokens":120,"output_tokens":30,"input_tokens_details":{"cached_tokens":100},"output_tokens_details":{"reasoning_tokens":12}}}}"#

private func mockModel() -> ResponsesLanguageModel {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockResponses.self]
    var model = ResponsesLanguageModel(name: "gpt-test", apiKey: "sk-test", url: URL(string: "https://mock-openai.test/v1")!)
    model.urlSession = URLSession(configuration: configuration)
    return model
}

struct WeatherTool: FoundationModels.Tool {
    let name = "get_weather"
    let description = "The weather in a city"

    @Generable
    struct Arguments {
        var city: String
    }

    func call(arguments: Arguments) async throws -> String {
        "Sunny in \(arguments.city)"
    }
}

extension OpenAISuite {
    @Suite(.serialized)
    struct ResponsesTests {
        @Test func streamsTextAndUsage() async throws {
            MockResponses.reset { _, _ in
                (200, events([
                    #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"Hello"}"#,
                    #"{"type":"response.output_text.delta","item_id":"msg_1","delta":" world"}"#,
                    completed,
                ]))
            }
            let session = LanguageModelSession(model: mockModel(), instructions: "Be brief.")
            let response = try await session.respond(to: "Hi")
            #expect(response.content == "Hello world")
            #expect(session.usage.input.cachedTokenCount == 100)

            let body = try #require(MockResponses.bodies.first)
            #expect(body["model"] as? String == "gpt-test")
            #expect(body["instructions"] as? String == "Be brief.")
            #expect(body["stream"] as? Bool == true)
            #expect(body["store"] as? Bool == false)
            #expect(body["prompt_cache_key"] as? String == session.transcript.first?.id)
            #expect(body["temperature"] == nil)
            let input = try #require(body["input"] as? [[String: Any]])
            #expect(input.first?["role"] as? String == "user")
            let content = try #require(input.first?["content"] as? [[String: Any]])
            #expect(content.first?["type"] as? String == "input_text")
            #expect(content.first?["text"] as? String == "Hi")
        }

        @Test func callsAToolAndSendsBackItsOutputAndReasoning() async throws {
            MockResponses.reset { _, count in
                if count == 1 {
                    (200, events([
                        #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"Check the weather."}"#,
                        #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","encrypted_content":"opaque"}}"#,
                        #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":""}}"#,
                        #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"city\":"}"#,
                        #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"\"Paris\"}"}"#,
                        #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}"#,
                        completed,
                    ]))
                } else {
                    (200, events([#"{"type":"response.output_text.delta","item_id":"msg_2","delta":"It's sunny."}"#, completed]))
                }
            }
            let session = LanguageModelSession(model: mockModel(), tools: [WeatherTool()])
            let response = try await session.respond(to: "Weather in Paris?")
            #expect(response.content == "It's sunny.")

            let first = try #require(MockResponses.bodies.first)
            let tools = try #require(first["tools"] as? [[String: Any]])
            #expect(tools.first?["name"] as? String == "get_weather")
            #expect(tools.first?["type"] as? String == "function")
            #expect(first["tool_choice"] as? String == "auto")

            let second = try #require(MockResponses.bodies.last?["input"] as? [[String: Any]])
            let types = second.map { $0["type"] as? String }
            #expect(types == ["message", "reasoning", "function_call", "function_call_output"])
            #expect(second[1]["id"] as? String == "rs_1")
            #expect(second[1]["encrypted_content"] as? String == "opaque")
            #expect(second[2]["call_id"] as? String == "call_1")
            #expect(second[2]["name"] as? String == "get_weather")
            #expect(second[3]["call_id"] as? String == "call_1")
            #expect(second[3]["output"] as? String == "Sunny in Paris")
        }

        @Test func asksForTheReasoningLevelsEffort() async throws {
            MockResponses.reset { _, _ in
                (200, events([#"{"type":"response.output_text.delta","item_id":"m","delta":"ok"}"#, completed]))
            }
            let session = LanguageModelSession(model: mockModel())
            _ = try await session.respond(to: "Think", contextOptions: ContextOptions(reasoningLevel: .deep))
            let reasoning = try #require(MockResponses.bodies.first?["reasoning"] as? [String: Any])
            #expect(reasoning["effort"] as? String == "high")
            #expect(reasoning["summary"] as? String == "auto")

            #expect(ResponsesRequest.effort(.light) == "low")
            #expect(ResponsesRequest.effort(.custom("max")) == "max")
            #expect(ResponsesRequest.effort(nil) == nil)
        }

        @Test func aRefusedKeyIsToldApart() async throws {
            MockResponses.reset { _, _ in
                (401, #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","code":"invalid_api_key"}}"#)
            }
            let session = LanguageModelSession(model: mockModel())
            do {
                _ = try await session.respond(to: "Hi")
                Issue.record("A refused key didn't throw")
            } catch {
                #expect(await Agents.LanguageModel.chatGPTRejectsKey(error), "\(error)")
            }

            let limited = ResponsesLanguageModel.Executor.error(statusCode: 429, body: Data(#"{"error":{"message":"Slow down."}}"#.utf8))
            guard case .rateLimited = limited as? LanguageModelError else {
                Issue.record("\(limited)")
                return
            }
        }

        @Test func anErrorEventsNestedMessageIsShown() async throws {
            MockResponses.reset { _, _ in
                (200, events([#"{"type":"error","error":{"type":"invalid_request_error","code":"bad","message":"Invalid schema for function 'run'."}}"#]))
            }
            let session = LanguageModelSession(model: mockModel())
            do {
                _ = try await session.respond(to: "Hi")
                Issue.record("The error event didn't throw")
            } catch let error as ResponsesLanguageModel.APIError {
                #expect(error.message == "Invalid schema for function 'run'.")
                #expect(error.code == "bad")
            }
        }

        @Test func errorsFollowOpenAIsCodes() async throws {
            func error(_ status: Int, _ json: String) -> any Error {
                ResponsesLanguageModel.Executor.error(statusCode: status, body: Data(json.utf8))
            }
            // Out of credits: said plainly, and not worth another try.
            let credits = error(429, #"{"error":{"type":"insufficient_quota","code":"credit_balance_exhausted","message":"No credits."}}"#)
            guard case .billing = credits as? ResponsesLanguageModel.RequestError else {
                Issue.record("\(credits)")
                return
            }
            #expect(credits.localizedDescription.contains("no credits left"))
            let spend = error(429, #"{"error":{"type":"insufficient_quota","code":"project_spend_limit_exceeded","message":"Limit."}}"#)
            #expect(spend.localizedDescription.contains("project reached its spend limit"))

            for (status, json) in [
                (429, #"{"error":{"type":"rate_limit_error","code":"slow_down","message":"Slow down."}}"#),
                (503, #"{"error":{"type":"service_unavailable_error","code":"server_is_overloaded","message":"Overloaded."}}"#),
            ] {
                let throttled = error(status, json)
                guard case .rateLimited = throttled as? LanguageModelError else {
                    Issue.record("\(throttled)")
                    continue
                }
            }

            let long = error(400, #"{"error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"Too long."}}"#)
            guard case .contextSizeExceeded = long as? LanguageModelError else {
                Issue.record("\(long)")
                return
            }

            #expect(await Agents.LanguageModel.chatGPTRejectsKey(error(401, #"{"error":{"message":"Bad key.","code":"invalid_api_key"}}"#)))
            let region = error(403, #"{"error":{"message":"Country, region, or territory not supported"}}"#)
            #expect(region.localizedDescription == "Country, region, or territory not supported")
        }

        @Test func anOutOfCreditsStreamIsBilling() async throws {
            MockResponses.reset { _, _ in
                (200, events([#"{"type":"error","error":{"type":"insufficient_quota","code":"insufficient_quota","message":"You exceeded your current quota."}}"#]))
            }
            let session = LanguageModelSession(model: mockModel())
            do {
                _ = try await session.respond(to: "Hi")
                Issue.record("The error event didn't throw")
            } catch {
                #expect(error.localizedDescription.contains("no credits left"), "\(error)")
            }
        }

        @Test func aFailedStreamThrowsItsMessage() async throws {
            MockResponses.reset { _, _ in
                (200, events([#"{"type":"response.failed","response":{"error":{"code":"server_error","message":"Something broke."}}}"#]))
            }
            let session = LanguageModelSession(model: mockModel())
            await #expect(throws: ResponsesLanguageModel.APIError.self) {
                _ = try await session.respond(to: "Hi")
            }
        }
    }
}
