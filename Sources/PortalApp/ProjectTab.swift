#if os(macOS)
enum ProjectTab: String, CaseIterable, Identifiable {
    case info, diff, terminal
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .diff: "plus.forwardslash.minus"
        case .terminal: "terminal"
        }
    }
}

#endif
