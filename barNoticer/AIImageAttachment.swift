import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct AIImageAttachment: Identifiable, Equatable, Sendable {
    static let maxCount = 4
    static let maxSourceBytes = 20 * 1_024 * 1_024
    static let maxPixelSize = 2_048

    private final class PreviewBox: @unchecked Sendable {
        let image: NSImage?
        init(data: Data) {
            self.image = NSImage(data: data)
        }
    }

    let id = UUID()
    let name: String
    let data: Data
    let dataURL: String
    private let previewBox: PreviewBox

    var preview: NSImage? { previewBox.image }

    static func == (lhs: AIImageAttachment, rhs: AIImageAttachment) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.data == rhs.data
    }

    init(data: Data, name: String) throws {
        guard data.count <= Self.maxSourceBytes else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { throw ImportError.invalidImage }

        // Downsample before decoding the full bitmap, strip metadata, and use
        // JPEG so screenshots, HEIC, and other local formats share a wire format.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.invalidImage }
        let encoded = output as Data
        self.data = encoded
        self.name = name
        self.dataURL = "data:image/jpeg;base64," + encoded.base64EncodedString()
        self.previewBox = PreviewBox(data: encoded)
    }

    init(url: URL) throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxSourceBytes else { throw ImportError.tooLarge }
        try self.init(data: Data(contentsOf: url), name: url.lastPathComponent)
    }

    enum ImportError: LocalizedError {
        case tooLarge, invalidImage, tooMany

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "单张图片不能超过 20 MB。"
            case .invalidImage: return "无法读取这张图片，请选择有效的图片文件。"
            case .tooMany: return "每次最多添加 4 张图片。"
            }
        }
    }
}
