import Foundation

public enum HTTPParseResult: Equatable {
    case incomplete
    case complete(method: String, path: String, body: Data)
    case invalid(status: Int)
}

/// Just enough HTTP/1.1 for one local caller sending one request per connection: a request line,
/// headers, and a body sized by `Content-Length`. No chunked encoding, no keep-alive.
public enum HTTPRequestParser {
    public static let maxBody = 65_536
    static let maxHeaders = 16_384

    public static func parse(_ buffer: Data) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHeaders ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaders else { return .invalid(status: 431) }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else {
            return .invalid(status: 400)
        }
        let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])

        var length = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let parsed = Int(value), parsed >= 0 else { return .invalid(status: 400) }
            length = parsed
        }
        guard length <= maxBody else { return .invalid(status: 413) }

        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .complete(method: String(parts[0]), path: path, body: body)
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body)
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status"
        }
    }
}
