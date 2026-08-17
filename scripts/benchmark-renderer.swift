import Foundation

private struct BenchmarkCase {
    let name: String
    let input: String
    let iterations: Int
    let usesTerminalScreen: Bool
}

private struct BenchmarkResult {
    let name: String
    let elapsed: TimeInterval
    let outputLength: Int
}

@main
private struct RendererBenchmark {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Ansi.runSelfTests()
            return
        }

        if CommandLine.arguments.contains("--scroll-self-test") {
            let renderer = Ansi.StyledTextRenderer(rows: 3)
            let output = renderer.process("one\r\ntwo\r\nthree\r\nfour\u{1B}[3;1H\u{1B}[2KFOUR")
            precondition(output.plainText == "one\ntwo\nthree\nFOUR")
            let margins = Ansi.StyledTextRenderer(rows: 4)
            let shifted = margins.process("one\r\ntwo\r\nthree\r\nfour\u{1B}[2;4r\u{1B}[2;1H\u{1B}M")
            precondition(shifted.plainText == "one\n\ntwo\nthree")
            return
        }

        if CommandLine.arguments.contains("--large-output-self-test") {
            let output = Ansi.StyledTextRenderer().process(longOutputInput(lines: 6_000)).plainText
            precondition(output.contains("line 0:"))
            precondition(output.contains("line 5999:"))
            precondition(!output.contains("[Trimmed "))
            return
        }

        let cases = [
            BenchmarkCase(
                name: "carriage-return-progress",
                input: progressInput(iterations: 4_000, clearsLine: false),
                iterations: 8,
                usesTerminalScreen: false
            ),
            BenchmarkCase(
                name: "csi-clear-line-progress",
                input: progressInput(iterations: 4_000, clearsLine: true),
                iterations: 8,
                usesTerminalScreen: false
            ),
            BenchmarkCase(
                name: "styled-progress",
                input: styledProgressInput(iterations: 3_000),
                iterations: 8,
                usesTerminalScreen: false
            ),
            BenchmarkCase(
                name: "alternate-screen-rewrite",
                input: alternateScreenInput(iterations: 2_000),
                iterations: 8,
                usesTerminalScreen: true
            ),
            BenchmarkCase(
                name: "long-output",
                input: longOutputInput(lines: 4_000),
                iterations: 5,
                usesTerminalScreen: false
            )
        ]

        for benchmark in cases {
            let result = run(benchmark)
            let milliseconds = result.elapsed * 1_000
            print("\(result.name): \(String(format: "%.2f", milliseconds)) ms, output \(result.outputLength) chars")
        }
    }

    private static func run(_ benchmark: BenchmarkCase) -> BenchmarkResult {
        var outputLength = 0
        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<benchmark.iterations {
            if benchmark.usesTerminalScreen {
                let renderer = Ansi.TerminalScreen(rows: 32, cols: 120)
                let state = renderer.process(benchmark.input)
                outputLength = state.text.count
            } else {
                let renderer = Ansi.StyledTextRenderer()
                let output = renderer.process(benchmark.input)
                outputLength = output.plainText.count
            }
        }

        return BenchmarkResult(
            name: benchmark.name,
            elapsed: CFAbsoluteTimeGetCurrent() - start,
            outputLength: outputLength
        )
    }

    private static func progressInput(iterations: Int, clearsLine: Bool) -> String {
        var output = ""
        output.reserveCapacity(iterations * 40)
        for index in 0..<iterations {
            if clearsLine {
                output += "\u{1B}[2K"
            }
            output += "Downloading \(index)/\(iterations) "
            output += String(repeating: ".", count: index % 40)
            output += "\r"
        }
        output += "\n"
        return output
    }

    private static func styledProgressInput(iterations: Int) -> String {
        var output = ""
        output.reserveCapacity(iterations * 52)
        for index in 0..<iterations {
            let color = 31 + (index % 6)
            output += "\u{1B}[\(color);1mBuilding target \(index)\u{1B}[0m"
            output += "\u{1B}[K\r"
        }
        output += "\n"
        return output
    }

    private static func alternateScreenInput(iterations: Int) -> String {
        var output = "\u{1B}[?1049h"
        output.reserveCapacity(iterations * 90)
        for index in 0..<iterations {
            output += "\u{1B}[H"
            output += "frame \(index)\n"
            output += "cpu \(index % 100)% memory \(index % 2048) MiB\n"
            output += "\u{1B}[3;1H"
            output += String(repeating: "#", count: index % 80)
        }
        output += "\u{1B}[?1049l"
        return output
    }

    private static func longOutputInput(lines: Int) -> String {
        var output = ""
        output.reserveCapacity(lines * 80)
        for index in 0..<lines {
            output += "line \(index): "
            output += String(repeating: "abcdef ", count: 9)
            output += "\n"
        }
        return output
    }
}
