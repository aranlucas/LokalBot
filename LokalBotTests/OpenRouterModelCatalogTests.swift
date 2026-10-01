import XCTest
@testable import LokalBot

final class OpenRouterModelCatalogTests: XCTestCase {
    private actor Server {
        enum Reply {
            case endpoints(Data)
            case status(Int)
            case failure
        }
        var replies: [Reply]
        var requests: [URLRequest] = []

        init(_ replies: [Reply]) { self.replies = replies }
        func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw URLError(.timedOut) }
            switch replies.removeFirst() {
            case .endpoints(let data): return (data, response(request, 200))
            case .status(let code): return (Data(), response(request, code))
            case .failure: throw URLError(.notConnectedToInternet)
            }
        }
        func recorded() -> [URLRequest] { requests }
        private func response(_ request: URLRequest, _ code: Int) -> URLResponse {
            HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    private let base = URL(string: "https://openrouter.ai/api/v1")!
    private let approved = ["https://openrouter.ai"]

    private func endpoints(_ windows: [(context: Int?, prompt: Int?)]) -> Data {
        let list = windows.map { window -> [String: Any] in
            var endpoint: [String: Any] = ["provider_name": "Fixture"]
            if let context = window.context { endpoint["context_length"] = context }
            if let prompt = window.prompt { endpoint["max_prompt_tokens"] = prompt }
            return endpoint
        }
        return (try? JSONSerialization.data(withJSONObject: ["data": ["id": "acme/long-context", "endpoints": list]])) ?? Data()
    }

    private func defaults() -> UserDefaults {
        let name = "OpenRouterModelCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func catalog(_ server: Server, defaults: UserDefaults, clock: Clock = Clock()) -> OpenRouterModelCatalog {
        OpenRouterModelCatalog(fetch: { try await server.answer($0) }, defaults: defaults, now: { clock.now })
    }

    func testReadsTheSmallestPublishedWindowSendingOnlyTheModelID() async throws {
        let server = Server([.endpoints(endpoints([(262_144, nil), (1_048_576, 200_000), (1_000_000, nil)]))])
        let tokens = await catalog(server, defaults: defaults())
            .contextTokens(model: "acme/long-context", baseURL: base, approvedOrigins: approved)
        XCTAssertEqual(tokens, 200_000, "a prompt cap below the context bounds the window")
        let requests = await server.recorded()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models/acme/long-context/endpoints")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testSendsNothingWithoutApprovalToOtherServersOrForUnsafeModelIDs() async throws {
        let server = Server([])
        let catalog = catalog(server, defaults: defaults())
        let unapproved = await catalog.contextTokens(model: "acme/long-context", baseURL: base, approvedOrigins: [])
        XCTAssertNil(unapproved)
        let openAI = await catalog.contextTokens(model: "acme/long-context",
            baseURL: URL(string: "https://api.openai.com/v1")!, approvedOrigins: ["https://api.openai.com"])
        XCTAssertNil(openAI)
        let local = await catalog.contextTokens(model: "acme/long-context",
            baseURL: URL(string: "http://localhost:1234/v1")!, approvedOrigins: [])
        XCTAssertNil(local)
        for model in ["", "acme", "../secrets", "acme/..", "acme/a/b", "acme/a b", "acme/a?x=1", "acme/a#b", "/acme"] {
            let tokens = await catalog.contextTokens(model: model, baseURL: base, approvedOrigins: approved)
            XCTAssertNil(tokens, model)
        }
        let requests = await server.recorded()
        XCTAssertTrue(requests.isEmpty)
    }

    func testKeepsTheLastPublishedWindowWhenALookupFails() async throws {
        let store = defaults()
        let first = await catalog(Server([.endpoints(endpoints([(1_000_000, nil)]))]), defaults: store)
            .contextTokens(model: "acme/long-context", baseURL: base, approvedOrigins: approved)
        XCTAssertEqual(first, 1_000_000)
        // A relaunched app whose lookup fails keeps the same window, so the
        // meeting's part plan and partial notes survive.
        for reply in [Server.Reply.failure, .status(404), .status(500), .endpoints(endpoints([]))] {
            let tokens = await catalog(Server([reply]), defaults: store)
                .contextTokens(model: "acme/long-context", baseURL: base, approvedOrigins: approved)
            XCTAssertEqual(tokens, 1_000_000)
        }
        let unknown = await catalog(Server([.failure]), defaults: defaults())
            .contextTokens(model: "acme/long-context", baseURL: base, approvedOrigins: approved)
        XCTAssertNil(unknown)
    }

    func testLooksAgainOnceADay() async throws {
        let clock = Clock()
        let server = Server([.endpoints(endpoints([(1_000_000, nil)])), .endpoints(endpoints([(131_072, nil)]))])
        let catalog = catalog(server, defaults: defaults(), clock: clock)
        let first = await catalog.contextTokens(model: "acme/long-context", baseURL: base, approvedOrigins: approved)
        clock.now += 3_600
        let cached = await catalog.contextTokens(model: "acme/long-context", baseURL: base, approvedOrigins: approved)
        XCTAssertEqual([first, cached], [1_000_000, 1_000_000])
        let afterAnHour = await server.recorded().count
        XCTAssertEqual(afterAnHour, 1)
        clock.now += 86_400
        let refreshed = await catalog.contextTokens(model: "acme/long-context", baseURL: base, approvedOrigins: approved)
        XCTAssertEqual(refreshed, 131_072)
    }

    func testUnusableAnswersAreUnknownNotOptimistic() {
        XCTAssertNil(OpenRouterModelCatalog.smallestWindow(inEndpoints: endpoints([])))
        XCTAssertNil(OpenRouterModelCatalog.smallestWindow(inEndpoints: endpoints([(1_000_000, nil), (nil, nil)])))
        XCTAssertNil(OpenRouterModelCatalog.smallestWindow(inEndpoints: endpoints([(0, nil)])))
        XCTAssertNil(OpenRouterModelCatalog.smallestWindow(inEndpoints: Data("not json".utf8)))
        XCTAssertEqual(OpenRouterModelCatalog.smallestWindow(inEndpoints: endpoints([(8_192, 0)])), 8_192)
    }

    func testPublishedWindowWinsThenTheVerifiedTableThen16K() async throws {
        func limit(_ model: String, _ reply: Server.Reply, approvedOrigins: [String]? = nil) async -> (Int, Int) {
            var config = AppSettings()
            config.summarizerBackend = .openAICompatible
            config.openAIBaseURL = base.absoluteString
            config.openAIModel = model
            config.approvedRemoteInferenceOrigins = approvedOrigins ?? approved
            let server = Server([reply])
            let tokens = await MeetingSummaryGenerator.contextTokenLimit(
                for: config, catalog: catalog(server, defaults: defaults()))
            return (tokens, await server.recorded().count)
        }
        let published = await limit("acme/long-context", .endpoints(endpoints([(1_000_000, nil)])))
        XCTAssertEqual(published.0, 1_000_000)
        let smallerThanTable = await limit("z-ai/glm-5.3-flash", .endpoints(endpoints([(131_072, nil)])))
        XCTAssertEqual(smallerThanTable.0, 131_072)
        let smallModel = await limit("acme/small", .endpoints(endpoints([(8_192, nil)])))
        XCTAssertEqual(smallModel.0, 8_192, "a published window below 16K is honored")
        let tableFallback = await limit("qwen/qwen3.8-flash", .failure)
        XCTAssertEqual(tableFallback.0, 1_000_000)
        let unknown = await limit("acme/long-context", .failure)
        XCTAssertEqual(unknown.0, 16_384)
        let unapproved = await limit("acme/long-context", .endpoints(endpoints([(1_000_000, nil)])), approvedOrigins: [])
        XCTAssertEqual(unapproved.0, 16_384)
        XCTAssertEqual(unapproved.1, 0, "an unapproved origin is never contacted")
    }
}
