import Foundation

enum SpeechStorage {
    #if targetEnvironment(simulator)
        static let isSimulator = true
    #else
        static let isSimulator = false
    #endif

    /// Conservative admission limits, not measured peak usage or model download sizes.
    /// Simulator's CPU-only BNNS compilation expands Turbo beyond its 626 MB weights.
    /// A 3.6 GiB free volume reproduced ENOSPC followed by an uncatchable native abort.
    static func requiredFreeBytes(for model: SpeechModel, onSimulator: Bool = isSimulator) -> Int64 {
        switch model {
        case .tiny: 100_000_000
        case .base: 250_000_000
        case .small: 500_000_000
        case .largeV3Turbo: onSimulator ? 8_000_000_000 : 2_000_000_000
        }
    }

    static func availableBytes(at directory: URL) throws -> Int64? {
        // Do not count purgeable space: Core ML's preallocation may fail before it is reclaimed.
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        return available.map(Int64.init)
    }

    static func validate(availableBytes: Int64?, model: SpeechModel, onSimulator: Bool = isSimulator) throws {
        guard let availableBytes else {
            throw AppFailure(L10n.tr("空き容量を確認できませんでした。モデルを読み込む前に、端末のストレージを確認してください。"))
        }
        let required = requiredFreeBytes(for: model, onSimulator: onSimulator)
        guard availableBytes >= required else {
            let requiredText = ByteCountFormatter.string(fromByteCount: required, countStyle: .decimal)
            let availableText = ByteCountFormatter.string(fromByteCount: max(0, availableBytes), countStyle: .decimal)
            throw AppFailure(
                L10n.tr(
                    "空き容量が不足しています。%@は作業領域の確保のため、%@以上の空き容量がある場合に実行できます（現在%@）。空きを増やして再試行するか、設定で小さいモデルを選んでください。",
                    String(describing: model.label),
                    String(describing: requiredText),
                    String(describing: availableText),
                ),
            )
        }
    }
}
