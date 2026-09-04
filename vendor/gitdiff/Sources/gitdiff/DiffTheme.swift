import SwiftUI

/// Color theme for diff rendering.
///
/// Use built-in themes or create custom themes for different visual styles.
public struct DiffTheme: Equatable, Hashable {
    public let addedBackground: Color
    public let addedText: Color
    public let removedBackground: Color
    public let removedText: Color
    public let contextBackground: Color
    public let contextText: Color
    public let lineNumberBackground: Color
    public let lineNumberText: Color
    public let headerBackground: Color
    public let headerText: Color
    public let fileHeaderBackground: Color
    public let fileHeaderText: Color
    
    public init(
        addedBackground: Color,
        addedText: Color,
        removedBackground: Color,
        removedText: Color,
        contextBackground: Color,
        contextText: Color,
        lineNumberBackground: Color,
        lineNumberText: Color,
        headerBackground: Color,
        headerText: Color,
        fileHeaderBackground: Color,
        fileHeaderText: Color
    ) {
        self.addedBackground = addedBackground
        self.addedText = addedText
        self.removedBackground = removedBackground
        self.removedText = removedText
        self.contextBackground = contextBackground
        self.contextText = contextText
        self.lineNumberBackground = lineNumberBackground
        self.lineNumberText = lineNumberText
        self.headerBackground = headerBackground
        self.headerText = headerText
        self.fileHeaderBackground = fileHeaderBackground
        self.fileHeaderText = fileHeaderText
    }
}

// MARK: - Built-in Themes
public extension DiffTheme {
    /// Light theme (GitHub style)
    static let light = DiffTheme(
        addedBackground: Color(red: 230/255, green: 255/255, blue: 237/255),
        addedText: Color(red: 34/255, green: 134/255, blue: 58/255),
        removedBackground: Color(red: 255/255, green: 238/255, blue: 240/255),
        removedText: Color(red: 207/255, green: 34/255, blue: 46/255),
        contextBackground: Color(red: 246/255, green: 248/255, blue: 250/255),
        contextText: Color(red: 88/255, green: 96/255, blue: 105/255),
        lineNumberBackground: Color(red: 246/255, green: 248/255, blue: 250/255),
        lineNumberText: Color(red: 88/255, green: 96/255, blue: 105/255),
        headerBackground: Color(red: 241/255, green: 248/255, blue: 255/255),
        headerText: Color(red: 5/255, green: 80/255, blue: 174/255),
        fileHeaderBackground: Color(red: 246/255, green: 248/255, blue: 250/255),
        fileHeaderText: Color(red: 36/255, green: 41/255, blue: 47/255)
    )
    
    /// Dark theme
    static let dark = DiffTheme(
        addedBackground: Color(red: 40/255, green: 60/255, blue: 40/255),
        addedText: Color(red: 135/255, green: 215/255, blue: 95/255),
        removedBackground: Color(red: 60/255, green: 40/255, blue: 40/255),
        removedText: Color(red: 245/255, green: 135/255, blue: 145/255),
        contextBackground: Color(red: 30/255, green: 30/255, blue: 30/255),
        contextText: Color(red: 212/255, green: 212/255, blue: 212/255),
        lineNumberBackground: Color(red: 38/255, green: 38/255, blue: 40/255),
        lineNumberText: Color(red: 133/255, green: 133/255, blue: 133/255),
        headerBackground: Color(red: 40/255, green: 40/255, blue: 60/255),
        headerText: Color(red: 156/255, green: 220/255, blue: 254/255),
        fileHeaderBackground: Color(red: 37/255, green: 37/255, blue: 38/255),
        fileHeaderText: Color(red: 204/255, green: 204/255, blue: 204/255)
    )
    
    /// GitLab theme
    static let gitlab = DiffTheme(
        addedBackground: Color(red: 221/255, green: 244/255, blue: 221/255),
        addedText: Color(red: 24/255, green: 128/255, blue: 56/255),
        removedBackground: Color(red: 253/255, green: 234/255, blue: 235/255),
        removedText: Color(red: 217/255, green: 30/255, blue: 24/255),
        contextBackground: Color(red: 250/255, green: 250/255, blue: 250/255),
        contextText: Color(red: 51/255, green: 50/255, blue: 56/255),
        lineNumberBackground: Color(red: 250/255, green: 250/255, blue: 250/255),
        lineNumberText: Color(red: 134/255, green: 134/255, blue: 134/255),
        headerBackground: Color(red: 236/255, green: 236/255, blue: 239/255),
        headerText: Color(red: 31/255, green: 30/255, blue: 36/255),
        fileHeaderBackground: Color(red: 241/255, green: 241/255, blue: 245/255),
        fileHeaderText: Color(red: 31/255, green: 30/255, blue: 36/255)
    )
    
    /// Default theme (alias for light)
    static let `default` = light
    
    // Deprecated theme aliases for backward compatibility
    @available(*, deprecated, renamed: "light")
    static let github = light
    
    @available(*, deprecated, message: "Use .light or .dark instead")
    static let vsCodeLight = light
    
    @available(*, deprecated, message: "Use .light or .dark instead")
    static let vsCodeDark = dark
    
    @available(*, deprecated, message: "Use .light or .dark instead")
    static let xcodeLight = light
    
    @available(*, deprecated, message: "Use .light or .dark instead")
    static let xcodeDark = dark
}
