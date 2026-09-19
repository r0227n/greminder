import Foundation
import GreminderShare
import Testing
import UniformTypeIdentifiers

@Suite("共有添付の利用可能な表現へのフォールバック")
struct ShareItemFallbackTests {
    @Test("Safari以外のプロパティリストがあっても添付のテキストを取り込む")
    func unrelatedPropertyListDoesNotHideText() async throws {
        let provider = NSItemProvider(
            item: ["unrelated": "metadata"] as NSDictionary,
            typeIdentifier: UTType.propertyList.identifier,
        )
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { done in
            done(Data("買い物\n牛乳".utf8), nil)
            return nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        let drafts = try await ShareItemLoader.drafts(from: [item])
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "買い物")
        #expect(drafts[0].notes == "買い物\n牛乳")
    }

    @Test("非WebのURL表現があっても同じ添付の有効なテキストを失わない")
    func nonWebURLDoesNotHideText() async throws {
        let provider = NSItemProvider(
            item: NSURL(string: "file:///private/unsupported"),
            typeIdentifier: UTType.url.identifier,
        )
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { done in
            done(Data("Shared text".utf8), nil)
            return nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        let drafts = try await ShareItemLoader.drafts(from: [item])
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Shared text")
        #expect(drafts[0].url.isEmpty)
    }
}
