import SwiftUI

enum AppTheme {
    static let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
    static var surface: Color {
        #if os(macOS)
            Color(nsColor: .textBackgroundColor)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }

    static var sidebar: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var subtle: Color { Color.primary.opacity(0.045) }
    static func tint(_ name: String) -> Color {
        switch name { case "red": .red
        case "green": .green
        case "orange": .orange
        case "yellow": .yellow
        case "mint": .mint
        case "cyan": .cyan
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        case "gray": .gray
        case "indigo": .indigo
        default: blue }
    }

    static func tint(_ selection: TaskSelection, lists: [TaskList] = []) -> Color {
        switch selection {
        case let .list(id): tint(lists.first { $0.id == id }?.tint ?? "blue")
        case .today: blue
        case .scheduled: .red
        case .all: Color(white: 0.36)
        case .completed: Color(white: 0.57)
        }
    }
}
