import SwiftUI

struct LoadingView: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .accessibilityLabel(title)
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
    func loadingOverlay(isPresented: Bool, title: String, message: String? = nil) -> some View {
        disabled(isPresented)
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        LoadingView(title: title, message: message)
                            .padding(24)
                            .frame(maxWidth: 360)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .padding(24)
                    }
                    .accessibilityIdentifier("loading-overlay")
                }
            }
    }
}
