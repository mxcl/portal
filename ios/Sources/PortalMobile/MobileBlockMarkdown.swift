import PortalMobileCore

func mobileBlockMarkdown(_ block: PortalBlock) -> String {
    var transcript = "```sh\n$ \(block.command)\n"
    if !block.output.isEmpty {
        transcript += block.output
        if !block.output.hasSuffix("\n") {
            transcript += "\n"
        }
    }
    if case .completed(let status) = block.state {
        transcript += "# exit code: \(status)\n"
    }
    return transcript + "```"
}
