#if os(macOS)
import AppKit
import SwiftUI
import Testing
import PortalTerminal
@testable import PortalCore
@testable import PortalEngine
@testable import PortalApp

@Test("Viewing an idle terminal clears its blue completion lamp")
@MainActor
func terminalCompletionLamp() {
    #expect(ProjectRow.terminalTone(state: .waiting, activity: .unviewed) == .blue)
    #expect(ProjectRow.terminalTone(state: .waiting, activity: nil) == .off)
    #expect(ProjectRow.terminalTone(state: .active, activity: .running) == .white)
    #expect(ProjectRow.terminalTone(state: nil, activity: .unviewed) == .blue)
    #expect(ProjectRow.terminalTone(state: nil, activity: nil) == .off)
}

@Test("LED sidebar retains both populated and sparse project readouts at narrow widths")
@MainActor
func sidebarRowsRender() throws {
    let model = AppModel(connectToHelper: false)
    var changes = RepositoryWorkingChanges(porcelain: Data(" M file\0".utf8))
    changes.addLineCounts(Data("28\t4\tfile\0".utf8))
    model.localProjects["av"] = PeerProject(name: "av", placement: .checkedOut,
        githubRepositories: ["mxcl/av"], workingChanges: changes)
    model.github.counts["mxcl/av"] = GitHubCounts(stars: 543, issues: 24, pullRequests: 0)
    let preview = VStack(spacing: 0) {
        HStack {
            Text("PROJECTS")
            Spacer()
            HStack(spacing: 0) {
                ForEach(["B", "Δ", "T"], id: \.self) { Text($0).frame(width: 18) }
            }
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(.gray)
        .padding(.horizontal, 12).frame(height: 27)
        ForEach(["av", "git-sync"], id: \.self) { name in
            ProjectRow(name: name, model: model)
                .padding(.horizontal, 12).padding(.vertical, 2)
        }
    }
    .frame(width: 266)
    .background(Color(red: 0.125, green: 0.153, blue: 0.169))
    let renderer = ImageRenderer(content: preview)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    #expect(image.size.width == 266)
    #expect(image.size.height >= 89)
    if let path = ProcessInfo.processInfo.environment["PORTAL_SIDEBAR_PREVIEW_PATH"] {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
