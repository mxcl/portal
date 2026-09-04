import AppKit
import SwiftUI
import Testing
@testable import gitdiff

@MainActor @Test func lineNumbersStayOnOneLine() {
  func height(_ number: Int) -> CGFloat {
    let view = NSHostingView(rootView:
      DiffLineView(line: DiffLine(type: .context, content: "x",
                                 oldLineNumber: number, newLineNumber: number))
        .diffConfiguration(.codeReview)
        .frame(width: 500)
    )
    return view.fittingSize.height
  }
  let baseline = height(99)
  for number in [100, 999, 1000, 10000, 1000000] {
    #expect(height(number) == baseline, "Line \(number) must not wrap")
  }
}
