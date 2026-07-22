import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental server-sent-events parser. Byte-oriented so UTF-8 sequences
/// and events split across arbitrary network chunk boundaries are handled
/// correctly. Per the SSE spec: events are dispatched on blank lines,
/// multi-line `data:` fields are joined with "\n", lines starting with ":"
/// are comments, and CRLF/LF line endings are both accepted. `[DONE]`
/// sentinels pass through as ordinary data for the caller to interpret.
public struct SSEParser: Sendable {
    private var lineBuffer: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func consume(_ data: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in data {
            if let event = consumeByte(byte) {
                events.append(event)
            }
        }
        return events
    }

    /// Feed a single byte; returns a completed event when a blank line
    /// closes one.
    public mutating func consumeByte(_ byte: UInt8) -> SSEEvent? {
        guard byte == 0x0A else {
            lineBuffer.append(byte)
            return nil
        }
        if lineBuffer.last == 0x0D {
            lineBuffer.removeLast()
        }
        let line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)
        return processLine(line)
    }

    private mutating func processLine(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            let name = eventName
            let lines = dataLines
            eventName = nil
            dataLines = []
            guard !lines.isEmpty else { return nil }
            return SSEEvent(event: name, data: lines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") {
            return nil
        }
        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var rawValue = String(line[line.index(after: colon)...])
            if rawValue.hasPrefix(" ") {
                rawValue.removeFirst()
            }
            value = rawValue
        } else {
            field = line
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(value)
        case "event":
            eventName = value
        default:
            break // id:/retry:/unknown fields are irrelevant here.
        }
        return nil
    }
}
