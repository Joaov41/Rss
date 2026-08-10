import Foundation
import UIKit

struct ChatAttachment: Identifiable {
    let id = UUID()
    let filename: String
    var content: String
    let kind: Kind
    let isTruncated: Bool

    enum Kind {
        case text
        case pdf
        case email

        var systemImageName: String {
            switch self {
            case .text: return "doc.text"
            case .pdf: return "doc.richtext"
            case .email: return "envelope"
            }
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    var imageData: Data?   // JPEG thumbnail for display
    var attachments: [ChatAttachment] = []
    let timestamp = Date()

    enum Role {
        case user
        case assistant
        case system
    }
}
