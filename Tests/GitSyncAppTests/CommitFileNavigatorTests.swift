#if os(macOS)
import Foundation
import Testing
@testable import GitSyncApp

@Test("File navigation counts partially visible files and responds to scrolling and resizing")
func commitFileVisibility() {
    let frame = CGRect(x: 0, y: 100, width: 300, height: 400)
    #expect(CommitFileNavigator.isVisible(frame, viewportHeight: 600))
    #expect(CommitFileNavigator.isVisible(frame, viewportHeight: 200))
    #expect(!CommitFileNavigator.isVisible(frame, viewportHeight: 100))
    #expect(!CommitFileNavigator.isVisible(frame, viewportHeight: 0))
    #expect(CommitFileNavigator.isVisible(frame.offsetBy(dx: 0, dy: -499), viewportHeight: 200))
    #expect(!CommitFileNavigator.isVisible(frame.offsetBy(dx: 0, dy: -500), viewportHeight: 200))
}
#endif
