import SwiftUI

struct FloatingAddButton: View {
    let title: String
    let color: Color
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(color == .yellow ? .black : .white)
                .frame(width: 56, height: 56)
                .background(color, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .help(title)
    }
}
