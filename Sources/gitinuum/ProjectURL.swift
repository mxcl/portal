import Foundation

func projectURL(path: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["-C", directory.path, "rev-parse", "--show-toplevel"]
    let output = Pipe()
    git.standardOutput = output
    git.standardError = FileHandle.nullDevice
    try git.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    git.waitUntilExit()
    guard git.terminationStatus == 0 else {
        throw NSError(domain: "gitinuum", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a Git working repository: \(path)"])
    }
    let root = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    var url = URLComponents()
    url.scheme = "gitsync"
    url.host = "project"
    url.queryItems = [URLQueryItem(name: "name", value: URL(fileURLWithPath: root).lastPathComponent)]
    return url.url!
}
