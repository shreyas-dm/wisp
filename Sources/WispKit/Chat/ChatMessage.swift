import Foundation

/// A single message in a conversation with the model.
public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var role: Role
    /// Plain text content. For user turns this is the transcript plus any
    /// screen-context block the prompt builder attached.
    public var text: String
    /// JPEG images attached to this turn (screenshot fallback). Kept only for
    /// the turn they were captured in; history compaction drops them.
    public var images: [AttachedImage]

    public init(role: Role, text: String, images: [AttachedImage] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

/// An image attachment, always JPEG, already downscaled by the capturer.
public struct AttachedImage: Codable, Sendable, Equatable {
    public var jpegData: Data
    public init(jpegData: Data) {
        self.jpegData = jpegData
    }
}

/// A full request sent to a provider.
public struct LLMChatRequest: Sendable {
    public var systemPrompt: String
    public var messages: [ChatMessage]
    public var maxOutputTokens: Int
    public var temperature: Double?

    public init(systemPrompt: String, messages: [ChatMessage], maxOutputTokens: Int = 1024, temperature: Double? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }
}
