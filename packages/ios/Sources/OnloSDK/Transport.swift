import Foundation

public struct OnloHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol OnloHTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> OnloHTTPResponse
}

/// Incremental widget-chat transport. Implementations must yield each decoded
/// SSE event as it arrives; they must not buffer a successful chat response.
public protocol OnloChatSSETransport: OnloHTTPTransport {
    func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

/// Internal success-path correlation for the request ID already returned in
/// the chat response header. It does not alter the public SSE wire contract.
protocol OnloChatRequestCorrelating: Sendable {
    func chatRequestId(for clientMessageId: String) -> String?
    func clearChatRequestId(for clientMessageId: String)
}

/// Foreground stream events are opaque refetch hints. They carry no durable
/// transcript mutation and must be bound by the SDK to current session state.
public protocol OnloForegroundSSETransport: OnloHTTPTransport {
    func streamEvents(for request: URLRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public final class URLSessionOnloTransport: OnloChatSSETransport, OnloForegroundSSETransport, OnloChatRequestCorrelating, @unchecked Sendable {
    private struct ChatEventEnvelope: Decodable {
        let type: String
    }

    private let session: URLSession
    private let chatCorrelationLock = NSLock()
    private var chatRequestIds: [String: String] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: URLRequest) async throws -> OnloHTTPResponse {
        do {
            let (body, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw OnloError.transport(code: "non_http_response")
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            return OnloHTTPResponse(statusCode: response.statusCode, headers: headers, body: body)
        } catch let error as OnloError {
            throw error
        } catch {
            throw OnloError.transport(code: "network_unavailable")
        }
    }

    public func chatEvents(for request: URLRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let clientMessageId = request.httpBody
            .flatMap { try? JSONDecoder().decode(ChatRequest.self, from: $0) }?
            .clientMessageId
        return AsyncThrowingStream { continuation in
            let task = Task {
                var receivedResponse = false
                var requestId: String?
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else { throw OnloError.transport(code: "non_http_response") }
                    receivedResponse = true
                    requestId = Self.requestId(from: response)
                    if let requestId, let clientMessageId {
                        self.storeChatRequestId(requestId, for: clientMessageId)
                    }
                    guard (200...299).contains(response.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            guard body.count < 65_536 else { throw OnloError.invalidResponse }
                            body.append(byte)
                        }
                        // Widget failures intentionally have no v1 envelope.
                        guard let error = try? JSONDecoder().decode(WidgetErrorResponse.self, from: body),
                              !error.error.isEmpty else { throw OnloError.invalidResponse }
                        let attachmentCodes = [
                            "attachment_grant_expired",
                            "invalid_attachment_grant",
                            APIErrorCode.mediaUnavailable.rawValue,
                        ]
                        let safeCode = attachmentCodes.contains(error.error)
                            ? error.error
                            : "widget_http_\(response.statusCode)"
                        if let requestId {
                            throw OnloError.correlatedTransport(code: safeCode, requestId: requestId)
                        }
                        throw OnloError.transport(code: safeCode)
                    }
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                guard let data = payload.data(using: .utf8) else { throw OnloError.invalidResponse }
                                continuation.yield(try Self.decodeChatEvent(data))
                                dataLines.removeAll(keepingCapacity: true)
                            }
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    if !dataLines.isEmpty {
                        let payload = dataLines.joined(separator: "\n")
                        guard let data = payload.data(using: .utf8) else { throw OnloError.invalidResponse }
                        continuation.yield(try Self.decodeChatEvent(data))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: OnloError.transport(code: "cancelled"))
                } catch let error as OnloError {
                    if let requestId, error.requestId == nil {
                        continuation.finish(throwing: OnloError.correlatedTransport(code: error.safeCode, requestId: requestId))
                    } else {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    if let requestId {
                        continuation.finish(throwing: OnloError.correlatedTransport(
                            code: receivedResponse ? "invalid_response" : "network_unavailable",
                            requestId: requestId
                        ))
                    } else {
                        continuation.finish(throwing: receivedResponse ? OnloError.invalidResponse : OnloError.transport(code: "network_unavailable"))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Shared by the live SSE parser and contract-fixture tests so raw server
    /// frames are validated without opening a network connection.
    static func decodeChatEvent(_ data: Data) throws -> ChatEvent {
        do {
            let event = try JSONDecoder().decode(ChatEvent.self, from: data)
            switch event {
            case let .accepted(clientMessageId, messageId, conversationId, acceptedAt, _, processingStatus):
                guard UUID(uuidString: clientMessageId) != nil,
                      !messageId.isEmpty,
                      !conversationId.isEmpty,
                      !acceptedAt.isEmpty,
                      !processingStatus.isEmpty else {
                    throw OnloError.transport(code: "invalid_accepted_event")
                }
            case .text:
                break
            case let .done(conversationId, _, _, _, _):
                guard !conversationId.isEmpty else {
                    throw OnloError.transport(code: "invalid_done_event")
                }
            case let .error(error, _):
                guard !error.isEmpty else {
                    throw OnloError.transport(code: "invalid_error_event")
                }
            }
            return event
        } catch {
            let envelope = try? JSONDecoder().decode(ChatEventEnvelope.self, from: data)
            let type = envelope?.type.lowercased()
            let safeType = type.flatMap {
                ["accepted", "text", "done", "error"].contains($0) ? $0 : nil
            }
            throw OnloError.transport(
                code: safeType.map { "invalid_\($0)_event" } ?? "invalid_response"
            )
        }
    }

    func chatRequestId(for clientMessageId: String) -> String? {
        chatCorrelationLock.lock()
        defer { chatCorrelationLock.unlock() }
        return chatRequestIds[clientMessageId.lowercased()]
    }

    func clearChatRequestId(for clientMessageId: String) {
        chatCorrelationLock.lock()
        defer { chatCorrelationLock.unlock() }
        chatRequestIds[clientMessageId.lowercased()] = nil
    }

    private func storeChatRequestId(_ requestId: String, for clientMessageId: String) {
        chatCorrelationLock.lock()
        defer { chatCorrelationLock.unlock() }
        chatRequestIds[clientMessageId.lowercased()] = requestId
    }

    public func streamEvents(for request: URLRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var requestId: String?
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OnloError.transport(code: "stream_unavailable") }
                    requestId = Self.requestId(from: http)
                    guard (200...299).contains(http.statusCode) else {
                        if let requestId {
                            throw OnloError.correlatedTransport(code: "stream_http_\(http.statusCode)", requestId: requestId)
                        }
                        throw OnloError.transport(code: "stream_unavailable")
                    }
                    var lines: [String] = []
                    for try await line in bytes.lines {
                        if line.isEmpty, !lines.isEmpty {
                            let payload = lines.joined(separator: "\n")
                            guard let data = payload.data(using: .utf8) else { throw OnloError.invalidResponse }
                            continuation.yield(try JSONDecoder().decode(StreamEvent.self, from: data))
                            lines.removeAll(keepingCapacity: true)
                        } else if line.hasPrefix("data:") { lines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                    }
                    if !lines.isEmpty {
                        let payload = lines.joined(separator: "\n")
                        guard let data = payload.data(using: .utf8) else { throw OnloError.invalidResponse }
                        continuation.yield(try JSONDecoder().decode(StreamEvent.self, from: data))
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch let error as OnloError {
                    if let requestId, error.requestId == nil {
                        continuation.finish(throwing: OnloError.correlatedTransport(code: error.safeCode, requestId: requestId))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
                catch {
                    if let requestId {
                        continuation.finish(throwing: OnloError.correlatedTransport(code: "network_unavailable", requestId: requestId))
                    } else {
                        continuation.finish(throwing: OnloError.transport(code: "network_unavailable"))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func requestId(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "X-Onlo-Request-Id")
    }
}

/// Builds every v1 request from the contract routes and documented fields.
/// It never attempts to transform legacy web/prototype endpoints.
public struct OnloRequestFactory: Sendable {
    public let baseURL: URL
    private let encoder: JSONEncoder

    public init(baseURL: URL) throws {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil else {
            throw OnloError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.encoder = JSONEncoder()
    }

    public func session(_ body: SessionRequest) throws -> URLRequest {
        try jsonRequest(path: "/api/sdk/v1/session", method: "POST", body: body, bearerToken: nil)
    }

    public func config(chatToken: String, etag: String?) throws -> URLRequest {
        var request = try authorizedRequest(path: "/api/sdk/v1/config", method: "GET", chatToken: chatToken)
        request.setValue("1", forHTTPHeaderField: "X-Onlo-Config-Schema")
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    public func pushToken(_ body: PushTokenRequest, chatToken: String) throws -> URLRequest {
        if case .register(_, let token, _, _) = body, token.count < 16 {
            throw OnloError.invalidConfiguration
        }
        return try jsonRequest(path: "/api/sdk/v1/push-token", method: "POST", body: body, bearerToken: chatToken)
    }

    public func attachmentIntent(_ body: AttachmentIntentRequest, chatToken: String) throws -> URLRequest {
        guard !body.conversationId.isEmpty,
              !body.filename.isEmpty,
              (1...OnloProtocol.maximumImageBytes).contains(body.byteSize),
              isSHA256(body.sha256) else {
            throw OnloError.invalidConfiguration
        }
        return try jsonRequest(path: "/api/sdk/v1/attachments/intent", method: "POST", body: body, bearerToken: chatToken)
    }

    public func attachmentCompletion(
        intent: String,
        fileData: Data,
        filename: String,
        mimeType: ImageMimeType,
        chatToken: String
    ) throws -> URLRequest {
        guard !intent.isEmpty,
              !filename.isEmpty,
              !fileData.isEmpty,
              fileData.count <= OnloProtocol.maximumImageBytes else {
            throw OnloError.invalidConfiguration
        }

        let boundary = "OnloSDK-" + UUID().uuidString
        var body = Data()
        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"intent\"\r\n\r\n", to: &body)
        append(intent, to: &body)
        append("\r\n--\(boundary)\r\n", to: &body)
        append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(sanitizedFilename(filename))\"\r\n",
            to: &body
        )
        append("Content-Type: \(mimeType.rawValue)\r\n\r\n", to: &body)
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n", to: &body)

        var request = try authorizedRequest(path: "/api/sdk/v1/attachments/complete", method: "POST", chatToken: chatToken)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func widgetAttachmentUpload(
        conversationId: String?,
        previousGrant: String? = nil,
        fileData: Data,
        filename: String,
        mimeType: ImageMimeType,
        chatToken: String
    ) throws -> URLRequest {
        guard !filename.isEmpty,
              !fileData.isEmpty,
              fileData.count <= OnloProtocol.maximumImageBytes else {
            throw OnloError.invalidConfiguration
        }
        let boundary = "OnloSDK-" + UUID().uuidString
        var body = Data()
        if let conversationId, !conversationId.isEmpty {
            append("--\(boundary)\r\n", to: &body)
            append("Content-Disposition: form-data; name=\"conversationId\"\r\n\r\n", to: &body)
            append(conversationId, to: &body)
            append("\r\n", to: &body)
        }
        if let previousGrant, !previousGrant.isEmpty {
            append("--\(boundary)\r\n", to: &body)
            append("Content-Disposition: form-data; name=\"previousGrant\"\r\n\r\n", to: &body)
            append(previousGrant, to: &body)
            append("\r\n", to: &body)
        }
        append("--\(boundary)\r\n", to: &body)
        append(
            "Content-Disposition: form-data; name=\"files\"; filename=\"\(sanitizedFilename(filename))\"\r\n",
            to: &body
        )
        append("Content-Type: \(mimeType.rawValue)\r\n\r\n", to: &body)
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n", to: &body)

        var request = try authorizedRequest(path: "/api/widget/attachments", method: "POST", chatToken: chatToken)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    public func chat(_ body: ChatRequest, chatToken: String) throws -> URLRequest {
        guard !body.sessionId.isEmpty,
              UUID(uuidString: body.clientMessageId) != nil,
              body.attachments?.count ?? 0 <= OnloProtocol.maximumImagesPerMessage else {
            throw OnloError.invalidConfiguration
        }
        for attachment in body.attachments ?? [] {
            guard let type = ImageMimeType(rawValue: attachment.type),
                  attachment.size > 0,
                  attachment.size <= OnloProtocol.maximumImageBytes,
                  !attachment.name.isEmpty,
                  !attachment.url.isEmpty,
                  type.rawValue == attachment.type else {
                throw OnloError.invalidConfiguration
            }
        }
        var request = try jsonRequest(path: "/api/widget/chat", method: "POST", body: body, bearerToken: chatToken)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    public func conversations(chatToken: String, limit: Int? = nil) throws -> URLRequest {
        if let limit, !(1...50).contains(limit) { throw OnloError.invalidConfiguration }
        let query = limit.map { [URLQueryItem(name: "limit", value: String($0))] } ?? []
        return try authorizedRequest(path: "/api/widget/conversations", method: "GET", chatToken: chatToken, query: query)
    }

    public func helpCenter(chatToken: String) throws -> URLRequest {
        try authorizedRequest(path: "/api/widget/articles", method: "GET", chatToken: chatToken)
    }

    public func helpCenterArticle(articleId: String, chatToken: String) throws -> URLRequest {
        guard !articleId.isEmpty else { throw OnloError.invalidConfiguration }
        let encodedArticleID = articleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? articleId
        return try authorizedRequest(
            path: "/api/widget/articles/\(encodedArticleID)",
            method: "GET",
            chatToken: chatToken
        )
    }

    public func transcript(conversationId: String, query: ConversationPageQuery, chatToken: String) throws -> URLRequest {
        guard !conversationId.isEmpty else { throw OnloError.invalidConfiguration }
        let items: [URLQueryItem]
        switch query {
        case .latest(let limit):
            items = try pageQueryItems(limit: limit)
        case .before(let cursor, let limit):
            guard !cursor.isEmpty else { throw OnloError.invalidConfiguration }
            items = [URLQueryItem(name: "before", value: cursor)] + (try pageQueryItems(limit: limit))
        case .after(let cursor, let limit):
            guard !cursor.isEmpty else { throw OnloError.invalidConfiguration }
            items = [URLQueryItem(name: "after", value: cursor)] + (try pageQueryItems(limit: limit))
        }
        return try authorizedRequest(
            path: "/api/widget/conversations/\(conversationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversationId)",
            method: "GET",
            chatToken: chatToken,
            query: items
        )
    }

    public func acknowledgeRead(
        conversationId: String,
        throughMessageId: String,
        chatToken: String
    ) throws -> URLRequest {
        guard !conversationId.isEmpty, !throughMessageId.isEmpty else {
            throw OnloError.invalidConfiguration
        }
        let encodedConversationID = conversationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversationId
        return try jsonRequest(
            path: "/api/widget/conversations/\(encodedConversationID)/read",
            method: "PUT",
            body: ConversationReadRequest(throughMessageId: throughMessageId),
            bearerToken: chatToken
        )
    }

    public func stream(chatToken: String) throws -> URLRequest {
        var request = try authorizedRequest(path: "/api/widget/stream", method: "GET", chatToken: chatToken)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    private func jsonRequest<Body: Encodable>(path: String, method: String, body: Body, bearerToken: String?) throws -> URLRequest {
        var request = try request(path: path, method: method, bearerToken: bearerToken)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func authorizedRequest(path: String, method: String, chatToken: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard !chatToken.isEmpty else { throw OnloError.invalidState }
        return try request(path: path, method: method, bearerToken: chatToken, query: query)
    }

    private func request(path: String, method: String, bearerToken: String?, query: [URLQueryItem] = []) throws -> URLRequest {
        let resolved = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            throw OnloError.invalidConfiguration
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw OnloError.invalidConfiguration }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func pageQueryItems(limit: Int?) throws -> [URLQueryItem] {
        guard let limit else { return [] }
        guard (1...100).contains(limit) else { throw OnloError.invalidConfiguration }
        return [URLQueryItem(name: "limit", value: String(limit))]
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }

    private func sanitizedFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_").replacingOccurrences(of: "\"", with: "_")
    }

    private func append(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }
}

enum OnloResponseDecoder {
    static func envelope<Result: Codable & Sendable>(_ type: Result.Type, from response: OnloHTTPResponse) throws -> APIResponse<Result> {
        let decoder = JSONDecoder()
        let envelope: APIEnvelope<Result>
        do {
            envelope = try decoder.decode(APIEnvelope<Result>.self, from: response.body)
        } catch {
            throw OnloError.invalidResponse
        }

        switch envelope {
        case .success(let success):
            guard success.ok,
                  success.protocolVersion == OnloProtocol.version,
                  success.minimumProtocolVersion <= OnloProtocol.version else {
                throw OnloError.incompatibleProtocol
            }
            return success
        case .failure(let failure):
            guard failure.protocolVersion == OnloProtocol.version,
                  failure.minimumProtocolVersion <= OnloProtocol.version else {
                throw OnloError.incompatibleProtocol
            }
            throw OnloError.remote(APIError(
                code: failure.error.code,
                message: failure.error.message,
                retry: failure.error.retry,
                requestId: failure.requestId
            ))
        }
    }

    static func widget<Result: Decodable & Sendable>(_ type: Result.Type, from response: OnloHTTPResponse) throws -> Result {
        let decoder = JSONDecoder()
        if (200...299).contains(response.statusCode) {
            do { return try decoder.decode(Result.self, from: response.body) }
            catch {
                if let requestId = requestId(in: response) {
                    throw OnloError.correlatedTransport(code: "invalid_response", requestId: requestId)
                }
                throw OnloError.invalidResponse
            }
        }
        let code: String
        if let error = try? decoder.decode(WidgetErrorResponse.self, from: response.body) {
            code = "widget_\(response.statusCode)_\(safeWidgetCode(error.error))"
        } else {
            code = "widget_http_\(response.statusCode)"
        }
        if let requestId = requestId(in: response) {
            throw OnloError.correlatedTransport(code: code, requestId: requestId)
        }
        throw OnloError.transport(code: code)
    }

    private static func requestId(in response: OnloHTTPResponse) -> String? {
        response.headers.first {
            $0.key.caseInsensitiveCompare("x-onlo-request-id") == .orderedSame
        }?.value
    }

    private static func safeWidgetCode(_ value: String) -> String {
        value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" } ? value : "error"
    }
}
