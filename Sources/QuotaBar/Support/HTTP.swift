import Foundation

enum HTTP {
    struct Response {
        let status: Int
        let data: Data

        var bodyPreview: String {
            String(decoding: data.prefix(200), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// Ephemeral session: no cookie jar, no cache; still honours the system proxy settings.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, headers: [String: String]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return Response(status: status, data: data)
    }
}
