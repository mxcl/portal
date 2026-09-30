//
//  DiffFileView.swift
//  gitdiff
//
//  Created by Tornike Gomareli on 18.06.25.
//

import SwiftUI

/// View for rendering a single file's diff
public struct DiffFileView: View {
  let file: DiffFile

  @Environment(\.diffOpenFile) private var openFile

  @Environment(\.diffConfiguration) private var configuration

  public init(file: DiffFile) {
    self.file = file
  }

  public var body: some View {
    let largestLineNumber = file.hunks.flatMap(\.lines).flatMap {
      [$0.oldLineNumber, $0.newLineNumber].compactMap { $0 }
    }.max() ?? 0
    let lineNumberDigits = max(2, String(largestLineNumber).count)

    return VStack(alignment: .leading, spacing: 0) {
      if configuration.showFileHeaders {
        HStack {
          Image(systemName: "doc.text")
            .foregroundColor(configuration.theme.fileHeaderText)

          Group {
            if let openFile {
              Button(file.displayName) { openFile(file) }
                .buttonStyle(DiffFileButtonStyle())
                .help("Open local working copy in editor")
            } else {
              Text(file.displayName)
            }
          }
            .font(.system(.headline, design: configuration.fontFamily))
            .fontWeight(.bold)
            .foregroundColor(configuration.theme.fileHeaderText)

          Spacer()

          if file.isBinary {
            Text("Binary file")
              .font(.caption)
              .foregroundColor(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.2))
              .cornerRadius(4)
          }
        }
        .padding()
        .background(configuration.theme.fileHeaderBackground)
      }

      if file.isBinary {
        Text("Binary file not shown")
          .font(.system(size: configuration.fontSize, design: configuration.fontFamily))
          .foregroundColor(.secondary)
          .padding()
      } else {
        ForEach(file.hunks) { hunk in
          VStack(alignment: .leading, spacing: 0) {
            if configuration.showHunkHeaders {
              Text(hunk.header)
                .font(.system(.caption, design: configuration.fontFamily))
                .foregroundColor(configuration.theme.headerText)
                .padding(.horizontal)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(configuration.theme.headerBackground)
            }

            LazyVStack(spacing: configuration.lineSpacing.value) {
              ForEach(hunk.lines) { line in
                DiffLineView(line: line, lineNumberDigits: lineNumberDigits)
              }
            }
            .background(configuration.theme.contextBackground)
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .background(configuration.theme.contextBackground)
    .cornerRadius(6)
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    )
  }
}

private struct DiffFileButtonStyle: ButtonStyle {
  @State private var isHovered = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .modifier(DiffFileButtonFeedback(isHovered: isHovered && isEnabled,
                                       isPressed: configuration.isPressed && isEnabled))
      .onHover { isHovered = $0 }
  }
}

struct DiffFileButtonFeedback: ViewModifier {
  let isHovered: Bool
  let isPressed: Bool

  func body(content: Content) -> some View {
    content
      .underline(isHovered || isPressed)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(Color.accentColor.opacity(isPressed ? 0.3 : (isHovered ? 0.15 : 0)),
                  in: RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
  }
}

#Preview {
  let sampleHunk = DiffHunk(
    oldStart: 1,
    oldCount: 5,
    newStart: 1,
    newCount: 6,
    header: "@@ -1,5 +1,6 @@",
    lines: [
      DiffLine(type: .context, content: "import SwiftUI", oldLineNumber: 1, newLineNumber: 1),
      DiffLine(type: .context, content: "", oldLineNumber: 2, newLineNumber: 2),
      DiffLine(
        type: .context, content: "struct ContentView: View {", oldLineNumber: 3, newLineNumber: 3),
      DiffLine(
        type: .added, content: "    let title = \"Hello World\"", oldLineNumber: nil,
        newLineNumber: 4),
      DiffLine(
        type: .context, content: "    var body: some View {", oldLineNumber: 4, newLineNumber: 5),
      DiffLine(
        type: .removed, content: "        Text(\"Hello, World!\")", oldLineNumber: 5,
        newLineNumber: nil),
      DiffLine(type: .added, content: "        Text(title)", oldLineNumber: nil, newLineNumber: 6),
      DiffLine(type: .added, content: "}", oldLineNumber: nil, newLineNumber: 7),
    ]
  )

  let sampleFile = DiffFile(
    oldPath: "example.swift",
    newPath: "example.swift",
    hunks: [sampleHunk],
    isBinary: false,
    isRenamed: false
  )

  DiffFileView(file: sampleFile)
    .padding()
}
