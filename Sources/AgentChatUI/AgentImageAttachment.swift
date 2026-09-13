import Foundation
import ImageIO
import RxAgentCore
import SwiftUI
import UniformTypeIdentifiers

/// Imports the bytes while a selected file is accessible, so sending and replay
/// do not depend on the original file remaining in place.
nonisolated enum AgentImageLoader {
    static let maximumInputBytes = 20 * 1024 * 1024
    static let maximumEncodedBytes = 4 * 1024 * 1024

    static func isImageFile(_ url: URL) -> Bool {
        url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func attachment(from url: URL) throws -> AgentAttachment {
        if isImageFile(url) { return try load(url) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        guard url.isFileURL, values.isRegularFile == true || values.isDirectory == true else { throw ImportError.invalidFile }
        return .file(url)
    }

    static func load(_ url: URL) throws -> AgentAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ImportError.invalidImage }
        guard (values.fileSize ?? 0) <= maximumInputBytes else { throw ImportError.tooLarge }
        return try load(Data(contentsOf: url), label: url.lastPathComponent)
    }

    static func load(_ data: Data, label: String = "Pasted image") throws -> AgentAttachment {
        guard data.count <= maximumInputBytes else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImportError.invalidImage }

        let mime = UTType(type as String)?.preferredMIMEType
        if let mime, ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mime),
           data.count <= maximumEncodedBytes, max(width, height) <= 4096 {
            return AgentAttachment(kind: .image(data, mimeType: mime), label: label)
        }

        // Screenshots often arrive as TIFF. Convert to a format every image
        // client understands, applying orientation and bounding the payload.
        guard let image = thumbnail(data, maximumPixelSize: 2048) else { throw ImportError.invalidImage }
        for format in [UTType.png, .jpeg] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= maximumEncodedBytes {
                return AgentAttachment(kind: .image(output as Data, mimeType: format.preferredMIMEType!), label: label)
            }
        }
        throw ImportError.tooLarge
    }

    static func thumbnail(_ data: Data, maximumPixelSize: Int = 128) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary)
    }

    enum ImportError: LocalizedError {
        case invalidImage, invalidFile, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidFile: "This file could not be attached. Choose a file or folder."
            case .invalidImage: "This image could not be opened. Choose another image."
            case .tooLarge: "This image is too large. Choose an image smaller than 20 MB."
            }
        }
    }
}

/// Shared by the draft and transcript, including apps with custom message rows.
public struct AgentAttachmentPreview: View {
    private let attachment: AgentAttachment
    @State private var thumbnail: CGImage?
    @Environment(\.agentTheme) private var theme

    public init(attachment: AgentAttachment) { self.attachment = attachment }

    private var fileSymbol: String {
        if case .file(let url) = attachment.kind,
           (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return "folder"
        }
        return "doc"
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable().scaledToFit()
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.1), in: .rect(cornerRadius: 6))
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Image(systemName: fileSymbol)
            }
            Text(attachment.label ?? "Attachment")
                .font(.caption).lineLimit(1)
        }
        .foregroundStyle(theme.assistantText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-attachment-\(attachment.id)")
        .task(id: attachment.id) {
            if case .image(let data, _) = attachment.kind {
                thumbnail = AgentImageLoader.thumbnail(data)
            }
        }
    }
}

#if os(macOS)
import AppKit

extension AgentImageLoader {
    @MainActor
    static func pastedImages(from pasteboard: NSPasteboard) throws -> [AgentAttachment] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            return try urls.map { try attachment(from: $0) }
        }
        return try (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let data = item.data(forType: .png) ?? item.data(forType: .tiff) else { return nil }
            return try load(data)
        }
    }
}
#endif
