import Foundation
import UIKit

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let type: MessageType
    var image: UIImage? = nil

    init(id: UUID = UUID(), text: String, type: MessageType, image: UIImage? = nil) {
        self.id = id
        self.text = text
        self.type = type
        self.image = image
    }

    private enum CodingKeys: String, CodingKey { case id, text, type, imageData }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        type = try values.decode(MessageType.self, forKey: .type)
        if let data = try values.decodeIfPresent(Data.self, forKey: .imageData) {
            image = UIImage(data: data)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(text, forKey: .text)
        try values.encode(type, forKey: .type)
        try values.encodeIfPresent(image?.jpegData(compressionQuality: 0.62), forKey: .imageData)
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text
    }
}

enum MessageType: String, Codable {
    case sent
    case received
}
