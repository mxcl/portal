import Testing
@testable import VaulttyMobile

@Test("automatic and dismissed completion popovers do not hijack Return")
func unselectedCompletionDoesNotApply() {
    let suggestions = ["first"]

    #expect(mobileSelectedCompletion(suggestions, selectedIndex: nil, isPresented: true) == nil)
    #expect(mobileSelectedCompletion(suggestions, selectedIndex: 0, isPresented: false) == nil)
}

@Test("cursor buttons honor application cursor mode")
func cursorButtonsHonorApplicationMode() {
    #expect(mobileCursorKey(finalByte: 0x41, applicationCursor: false) == [0x1b, 0x5b, 0x41])
    #expect(mobileCursorKey(finalByte: 0x41, applicationCursor: true) == [0x1b, 0x4f, 0x41])
}
