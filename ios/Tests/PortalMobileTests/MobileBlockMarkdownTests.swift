import Testing
import PortalMobileCore
@testable import PortalMobile

struct MobileBlockMarkdownTests {
    @Test func testCompletedTranscriptMatchesMacFormat() {
        for output in ["hello", "hello\n"] {
            let block = PortalBlock(command: "echo hello", cwd: "/tmp", output: output, state: .completed(0))
            #expect(mobileBlockMarkdown(block) == "```sh\n$ echo hello\nhello\n# exit code: 0\n```")
        }
    }

    @Test func testRunningAndFailedCommands() {
        #expect(mobileBlockMarkdown(PortalBlock(command: "sleep 10", cwd: nil)) ==
                       "```sh\n$ sleep 10\n```")
        #expect(mobileBlockMarkdown(PortalBlock(command: "false", cwd: nil, state: .completed(1))) ==
                       "```sh\n$ false\n# exit code: 1\n```")
    }
}
