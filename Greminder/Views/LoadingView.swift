import SwiftUI

struct LoadingView: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .accessibilityHidden(true)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func loadingOverlay(
        isPresented: Bool,
        title: String,
        message: String? = nil,
        completionTitle: String? = nil,
    ) -> some View {
        modifier(LoadingOverlayModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            completionTitle: completionTitle,
        ))
    }
}

private struct LoadingOverlayModifier: ViewModifier {
    let isPresented: Bool
    let title: String
    let message: String?
    let completionTitle: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completion: String?

    func body(content: Content) -> some View {
        content
            .disabled(isPresented)
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented || completion != nil {
                    LoadingHUD(title: isPresented ? title : completion ?? title, isComplete: !isPresented)
                        .accessibilityHint(isPresented ? message ?? "" : "")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .allowsHitTesting(isPresented)
                        .accessibilityIdentifier("loading-overlay")
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isPresented || completion != nil)
            .onChange(of: isPresented) { wasPresented, isPresented in
                completion = wasPresented && !isPresented ? completionTitle : nil
            }
            .task(id: completion) {
                guard completion != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                    completion = nil
                } catch is CancellationError {
                    // A new operation or a dismissed screen owns the next presentation.
                } catch {}
            }
            .onDisappear { completion = nil }
    }
}

private struct LoadingHUD: View {
    let title: String
    var isComplete = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 42, weight: .medium))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .scaleEffect(1.25)
                }
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(width: 180)
        .frame(minHeight: 180)
        .background(.black.opacity(reduceTransparency ? 1 : 0.68), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isComplete)
    }
}

#Preview("Loading HUD") {
    LoadingHUD(title: "準備中")
        .padding(40)
}

#Preview("Completed HUD") {
    LoadingHUD(title: "準備完了", isComplete: true)
        .padding(40)
}
