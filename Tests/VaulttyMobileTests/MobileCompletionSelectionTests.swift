import Testing
@testable import VaulttyMobile

@Test("automatic and dismissed completion popovers do not hijack Return")
func unselectedCompletionDoesNotApply() {
    let suggestions = ["first"]

    #expect(mobileSelectedCompletion(suggestions, selectedIndex: nil, isPresented: true) == nil)
    #expect(mobileSelectedCompletion(suggestions, selectedIndex: 0, isPresented: false) == nil)
}
