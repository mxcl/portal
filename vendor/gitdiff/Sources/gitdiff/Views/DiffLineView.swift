//
//  DiffLineView.swift
//  gitdiff
//
//  Created by Tornike Gomareli on 18.06.25.
//

import SwiftUI

/// View for rendering a single diff line with GitHub-style formatting
struct DiffLineView: View {
  let line: DiffLine
  var lineNumberDigits = 2

  @Environment(\.diffConfiguration) private var configuration

  private var backgroundColor: Color {
    switch line.type {
    case .added:
      return configuration.theme.addedBackground
    case .removed:
      return configuration.theme.removedBackground
    case .context:
      return configuration.theme.contextBackground
    case .header:
      return configuration.theme.headerBackground
    }
  }

  private var foregroundColor: Color {
    switch line.type {
    case .added:
      return configuration.theme.addedText
    case .removed:
      return configuration.theme.removedText
    case .context:
      return configuration.theme.contextText
    case .header:
      return configuration.theme.headerText
    }
  }

  private var linePrefix: String {
    switch line.type {
    case .added:
      return "+"
    case .removed:
      return "-"
    case .context, .header:
      return " "
    }
  }

  /// For ``DiffConfiguration/LineNumberStyle/single``, show the most
  /// relevant number for the line type: new for added/context, old for
  /// removed. This matches how terminal tools like `git diff --color` and
  /// Pi's own renderer present a compact gutter, where each line has at
  /// most one number and the prefix carries the kind.
  private var singleColumnLineNumber: String {
    switch line.type {
    case .added, .context, .header:
      return line.newLineNumber.map(String.init)
        ?? line.oldLineNumber.map(String.init)
        ?? ""
    case .removed:
      return line.oldLineNumber.map(String.init) ?? ""
    }
  }

  private func lineNumber(_ number: String) -> some View {
    ZStack(alignment: .trailing) {
      Text(String(repeating: "8", count: max(lineNumberDigits, number.count))).hidden()
      Text(number)
    }
    .font(.system(size: configuration.fontSize * 0.85, design: configuration.fontFamily))
    .monospacedDigit()
    .fixedSize()
    .foregroundColor(configuration.theme.lineNumberText)
    .padding(.horizontal, 4)
    .background(configuration.theme.lineNumberBackground)
  }

  var body: some View {
    HStack(spacing: 0) {
      switch configuration.lineNumberStyle {
      case .hidden:
        EmptyView()
      case .single:
        lineNumber(singleColumnLineNumber)
      case .dual:
        lineNumber(line.oldLineNumber.map(String.init) ?? "")
        lineNumber(line.newLineNumber.map(String.init) ?? "")
      }

      HStack(alignment: .top, spacing: 0) {
        Text(linePrefix)
          .font(
            .system(
              size: configuration.fontSize, weight: configuration.fontWeight,
              design: configuration.fontFamily)
          )
          .foregroundColor(foregroundColor)
          .padding(.leading, configuration.contentPadding.leading)

        Text(line.content)
          .font(
            .system(
              size: configuration.fontSize, weight: configuration.fontWeight,
              design: configuration.fontFamily)
          )
          .foregroundColor(foregroundColor)
          .padding(.leading, 4)
          .padding(.trailing, configuration.contentPadding.trailing)
          .fixedSize(horizontal: !configuration.wordWrap, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(backgroundColor)
    }
  }
}

#Preview {
  VStack(spacing: 0) {
    DiffLineView(
      line: DiffLine(
        type: .context,
        content: "struct ContentView: View {",
        oldLineNumber: 3,
        newLineNumber: 3
      )
    )

    DiffLineView(
      line: DiffLine(
        type: .added,
        content: "    let title = \"Hello World\"",
        oldLineNumber: nil,
        newLineNumber: 4
      )
    )

    DiffLineView(
      line: DiffLine(
        type: .context,
        content: "    var body: some View {",
        oldLineNumber: 4,
        newLineNumber: 5
      )
    )

    DiffLineView(
      line: DiffLine(
        type: .removed,
        content: "        Text(\"Hello, World!\")",
        oldLineNumber: 5,
        newLineNumber: nil
      )
    )

    DiffLineView(
      line: DiffLine(
        type: .added,
        content: "        Text(title)",
        oldLineNumber: nil,
        newLineNumber: 6
      )
    )
  }
}
