import Foundation
import UniformTypeIdentifiers

public enum ShareItemLoader {
    /// Preserve item order, use one usable representation per attachment, and never fetch a URL.
    public static func drafts(from items: [NSExtensionItem]) async throws -> [ShareDraft] {
        var drafts: [ShareDraft] = []
        for item in items {
            var title = item.attributedTitle?.string
            var texts = [item.attributedContentText?.string].compactMap(\.self)
            var urls: [URL] = []
            for provider in item.attachments ?? [] {
                if provider.registeredTypeIdentifiers.contains(UTType.propertyList.identifier) {
                    let value = try await load(provider, type: UTType.propertyList.identifier)
                    if let dictionary = value as? [String: Any],
                       let page = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
                    {
                        title = page["title"] as? String ?? title
                        if let text = page["selection"] as? String, !text.isEmpty { texts.append(text) }
                        if let value = page["url"] as? String, let url = ShareDraft.webURL(value) { urls.append(url) }
                        if !(page["title"] as? String ?? "").isEmpty
                            || !(page["selection"] as? String ?? "").isEmpty
                            || (page["url"] as? String).flatMap(ShareDraft.webURL) != nil { continue }
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let value = try await load(provider, type: UTType.url.identifier)
                    let text = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    let url = (value as? URL) ?? text.flatMap(ShareDraft.webURL)
                    if let url, ShareDraft.webURL(url.absoluteString) != nil {
                        urls.append(url)
                        if title == nil { title = provider.suggestedName }
                        continue
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let value = try await load(provider, type: UTType.plainText.identifier)
                    if let value = value as? String { texts.append(value) }
                    else if let data = value as? Data,
                            let text = String(data: data, encoding: .utf8) { texts.append(text) }
                }
            }
            var seenTexts: Set<String> = []
            let text = texts.filter { seenTexts.insert($0).inserted }.joined(separator: "\n\n")
            if urls.isEmpty, let url = ShareDraft.webURL(text) { urls.append(url) }
            var seenURLs: Set<URL> = []
            urls = urls.filter { seenURLs.insert($0).inserted }
            if urls.isEmpty {
                if title != nil || !text.isEmpty { drafts.append(.received(title: title, text: text, url: nil)) }
            } else {
                for (index, url) in urls.enumerated() {
                    drafts.append(.received(title: index == 0 ? title : nil, text: index == 0 ? text : nil, url: url))
                }
            }
        }
        guard !drafts.isEmpty else { throw ShareInboxError.invalidDraft }
        return drafts
    }

    private static func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: item) }
            }
        }
    }
}
