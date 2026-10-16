//
//  Adapted from macgit (Commit+), Copyright (C) 2026 Thanh Tran.
//  Licensed under the GNU Affero General Public License v3 or later.
//
import Foundation
import AppKit
import PortalCore
import Testing
import SwiftUI
@testable import PortalGraph

@Test("commit graph renders a merge across rows")
func commitGraphMerge() {
    func commit(_ oid: String, parents: [String] = []) -> RepositoryCommit {
        RepositoryCommit(oid: oid, parents: parents, author: "", date: .distantPast, message: oid)
    }

    let model = CommitGraphGenerator.generate(
        commits: [commit("merge", parents: ["main", "feature"]),
                  commit("feature", parents: ["root"]),
                  commit("main", parents: ["root"]),
                  commit("root")],
        headOID: "merge"
    )

    #expect(model.dots.count == 4)
    #expect(model.links.count == 1)
    #expect(model.laneCount >= 2)
    #expect(model.rowSlices.count == 4)
    #expect(model.dots.first?.type == .head)
}

@Test("Orange follows the active branch instead of the first lane", arguments: [false, true])
func activeBranchColor(includeStaging: Bool) throws {
    func commit(_ oid: String, _ parents: [String] = []) -> RepositoryCommit {
        RepositoryCommit(oid: oid, parents: parents, author: "", date: .distantPast, message: oid)
    }
    let commits = [commit("preserve", ["root"]), commit("descendant", ["main"]),
                   commit("main", ["older", "merged"]), commit("merged", ["root"]),
                   commit("older", ["root"]), commit("root"), commit("isolated")]
    let graph = CommitGraphGenerator.generate(commits: commits, headOID: "main", includeStaging: includeStaging,
                                              branchNames: ["descendant": ["codex/preserve"], "main": ["main"]])
    for oid in ["main", "older", "root"] {
        #expect(graph.colorIndex(for: oid) == 0)
    }
    for oid in ["preserve", "descendant", "merged", "isolated"] {
        #expect(graph.colorIndex(for: oid) != 0)
    }
    #expect(graph.paths.first?.colorIndex != 0)
    let branchPath = try #require(graph.paths.first { $0.points.first == graph.dots[1].center })
    #expect(branchPath.colorIndex != 0)
    let mainDot = try #require(graph.dots.first { $0.type == .head })
    #expect(branchPath.points.last == mainDot.center)
    #expect(graph.paths.contains { !$0.isDashed && $0.points.first == mainDot.center && $0.colorIndex == 0 })
    #expect(graph.links.allSatisfy { $0.colorIndex != 0 })
    #expect(graph.branchLabels.contains { $0.colorIndex == 0 })
    #expect(graph.branchLabels.contains { $0.colorIndex != 0 })
    if includeStaging {
        #expect(graph.colorIndex(for: CommitGraphGenerator.workingChangesID) == 0)
        let staging = try #require(graph.paths.first { $0.isDashed })
        #expect(staging.colorIndex == 0)
    }
    let switched = CommitGraphGenerator.generate(commits: commits, headOID: "preserve", includeStaging: includeStaging)
    #expect(switched.colorIndex(for: "preserve") == 0)
    #expect(switched.colorIndex(for: "main") != 0)
    #expect(switched.colorIndex(for: "descendant") != 0)
}

@Test("wide histories preserve native lane spacing")
func wideHistoryLaneSpacing() {
    let root = RepositoryCommit(oid: "root", parents: [], author: "", date: .distantPast, message: "root")
    let tips = (0..<18).map {
        RepositoryCommit(oid: "tip-\($0)", parents: [root.oid], author: "", date: .distantPast, message: "tip")
    }
    let model = CommitGraphGenerator.generate(commits: tips + [root], headOID: nil)

    let firstWidth = BranchGraphRowCanvas.graphWidth(model: model, commitOID: tips[0].oid)
    let lastWidth = BranchGraphRowCanvas.graphWidth(model: model, commitOID: tips.last!.oid)
    #expect(model.dots.allSatisfy { $0.colorIndex != 0 })
    #expect(firstWidth == 32)
    #expect(abs(lastWidth - firstWidth - 17 * 24) < 0.001)
}

@Test("Hovered branch labels render above content in narrower graph rows", arguments: [false, true])
@MainActor func hoveredBranchOverlappingContent(hovered: Bool) throws {
    let commit = RepositoryCommit(oid: "tip", parents: [], author: "", date: .distantPast, message: "tip")
    var model = CommitGraphGenerator.generate(commits: [commit], headOID: nil)
    let outline = Path(CGRect(x: 40, y: 10, width: 8, height: 10))
    model.branchLabels = [GraphBranchLabel(outline: outline, hoverOutline: outline, colorIndex: 0)]
    let content = HStack(spacing: 0) {
        BranchGraphRowCanvas(model: model, rowIndex: 0, commitOID: "tip", hoveredLabel: .constant(hovered ? 0 : nil))
        Color.white.frame(width: 100, height: 44)
    }
    let image = try #require(ImageRenderer(content: content).cgImage)
    let bitmap = NSBitmapImageRep(cgImage: image)
    // This column lies beyond the 32-point graph width, inside the adjacent content.
    let hasLabel = (0..<bitmap.pixelsHigh).contains { y in
        guard let color = bitmap.colorAt(x: 48, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return color.alphaComponent > 0.5 && min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8
    }
    #expect(hasLabel == hovered)
    #expect(bitmap.pixelsWide == 132)
}

@Test("staging sits immediately above HEAD after other branches, including clean and unborn checkouts")
func workingChangesGraph() throws {
    let commits = [
        RepositoryCommit(oid: "other", parents: ["root"], author: "", date: .distantPast, message: "other"),
        RepositoryCommit(oid: "head", parents: ["root"], author: "", date: .distantPast, message: "head"),
        RepositoryCommit(oid: "root", parents: [], author: "", date: .distantPast, message: "root"),
    ]
    let graph = CommitGraphGenerator.generate(commits: commits, headOID: "head", includeStaging: true)
    #expect(graph.rowSlices.count == 4)
    let stagingIndex = CommitGraphGenerator.stagingRowIndex(commits: commits, headOID: "head")
    #expect(stagingIndex == 1)
    let changes = graph.dots[stagingIndex]
    let head = graph.dots[2]
    #expect(changes.center.y == 1.5)
    #expect(changes.type == .default)
    #expect(head.type == .head)
    #expect(changes.lane == head.lane)
    #expect(graph.paths.contains { $0.points.first == changes.center && $0.points.contains { $0.y >= head.center.y } })
    #expect(graph.rowSlices[1].pathIndices.contains { graph.paths[$0].points.first == changes.center })
    let mirror = CommitGraphGenerator.generate(commits: commits, headOID: "head")
    #expect(mirror.rowSlices.count == 3)
    #expect(mirror.paths.allSatisfy { !$0.isDashed })
    let unborn = CommitGraphGenerator.generate(commits: [], headOID: nil, includeStaging: true)
    #expect(unborn.dots.count == 1)
    #expect(unborn.paths.isEmpty)
}

@Test("Only the staging connector is dashed, including when HEAD has a visible descendant", arguments: [false, true])
func stagingConnectorIsDashed(hasDescendant: Bool) throws {
    let commits = (hasDescendant ? [RepositoryCommit(oid: "tip", parents: ["head"], author: "", date: .distantPast, message: "tip")] : []) + [
        RepositoryCommit(oid: "head", parents: ["root"], author: "", date: .distantPast, message: "head"),
        RepositoryCommit(oid: "root", parents: [], author: "", date: .distantPast, message: "root"),
    ]
    let graph = CommitGraphGenerator.generate(commits: commits, headOID: "head", includeStaging: true)
    let index = CommitGraphGenerator.stagingRowIndex(commits: commits, headOID: "head")
    let dashed = graph.paths.filter(\.isDashed)
    #expect(dashed.count == 1)
    let connector = try #require(dashed.first)
    #expect(connector.points.first == graph.dots[index].center)
    #expect(connector.points.last == graph.dots[index + 1].center)
    #expect(graph.paths.contains { !$0.isDashed && $0.points.last == graph.dots.last?.center })
}

@Test("Each host staging row connects to its own HEAD, including hosts sharing HEAD")
func multipleHostStaging() throws {
    func commit(_ id: String, _ parents: [String] = []) -> RepositoryCommit {
        RepositoryCommit(oid: id, parents: parents, author: "", date: .distantPast, message: id)
    }
    let staging = [commit("working-changes", ["tip"]),
                   commit("working-changes:pangolin", ["old"]),
                   commit("working-changes:other", ["old"])]
    let rows = CommitGraphGenerator.insertingStaging(staging,
        into: [commit("tip", ["old"]), commit("old", ["root"]), commit("root")])
    #expect(rows.map(\.oid) == ["working-changes", "tip", "working-changes:pangolin",
                               "working-changes:other", "old", "root"])
    let graph = CommitGraphGenerator.generate(commits: rows, headOID: "tip")
    let dashed = graph.paths.filter(\.isDashed)
    #expect(dashed.count == 3)
    for row in staging {
        let index = try #require(rows.firstIndex { $0.oid == row.oid })
        let head = try #require(rows.firstIndex { $0.oid == row.parents.first })
        #expect(dashed.contains { $0.points.first == graph.dots[index].center && $0.points.last == graph.dots[head].center })
    }
    let missing = CommitGraphGenerator.insertingStaging([commit("working-changes:missing", ["absent"])], into: rows)
    #expect(missing.first?.oid == "working-changes:missing")
}

@Test("Branch labels omit HEADs and tags and follow lanes across row boundaries")
func branchLabels() {
    let refs = ["refs/heads/main", "refs/remotes/peer/feature", "refs/remotes/peer/HEAD", "HEAD", "refs/tags/v1"]
        .map { RepositoryReference(fullName: $0, oid: "0") }
    #expect(refs.filter(\.isGraphBranch).map(\.name) == ["main", "peer/feature"])
    let commits = (0..<10).map {
        RepositoryCommit(oid: "\($0)", parents: $0 < 9 ? ["\($0 + 1)"] : [],
                         author: "", date: .distantPast, message: "")
    }
    let model = CommitGraphGenerator.generate(commits: commits, headOID: "0",
        branchNames: ["0": ["main", "peer/feature"], "5": ["older"]])
    #expect(model.branchLabels.count == 2)
    let bounds = model.branchLabels[0].outline.boundingRect
    #expect(!bounds.isEmpty)
    #expect(bounds.maxY > BranchGraphRowCanvas.rowHeight)
    #expect(bounds.maxY < 10 * BranchGraphRowCanvas.rowHeight)
    #expect(bounds.maxX < BranchGraphRowCanvas.laneWidth + BranchGraphRowCanvas.trailingPadding)
}

@Test("Nearby primary lane tips stay separate by using opposite sides")
func nearbyBranchLabels() throws {
    let commits = (0..<10).map {
        RepositoryCommit(oid: "\($0)", parents: $0 < 9 ? ["\($0 + 1)"] : [],
                         author: "", date: .distantPast, message: "")
    }
    let names = ["0": ["codex/history-complete-windows"], "3": ["main"]]
    let model = CommitGraphGenerator.generate(commits: commits, headOID: "0", branchNames: names)
    let main = CommitGraphGenerator.generate(commits: commits, headOID: "0", branchNames: ["3": ["main"]])
    #expect(model.branchLabels.count == 2)
    let upper = try #require(model.branchLabels.first).outline.boundingRect
    let lower = try #require(model.branchLabels.last).outline.boundingRect
    #expect(upper.minY >= 0.5 * BranchGraphRowCanvas.rowHeight)
    #expect(upper.maxY > 3.5 * BranchGraphRowCanvas.rowHeight)
    #expect(abs(model.branchLabels[0].hoverOutline.boundingRect.maxY - upper.maxY) < 0.01)
    #expect(model.branchLabels[0].hoverOutline == model.branchLabels[0].outline)
    #expect(upper.maxX < lower.minX)
    #expect(model.branchLabels.last?.outline == main.branchLabels.first?.outline)
    let combined = CommitGraphGenerator.generate(commits: commits, headOID: "0",
        branchNames: ["0": ["main", "codex/history-complete-windows"]])
    #expect(combined.branchLabels.count == 1)
}

@Test("Uncontested tags and matching branch copies use short names")
func matchingReferenceNames() {
    for tags in [false, true] {
        let names = tags
            ? ["refs/tags/releases/v1", "refs/sync/origin/tags/releases/v1", "refs/sync/pangolin/tags/releases/v1"]
            : ["refs/heads/feature/main", "refs/remotes/origin/feature/main", "refs/remotes/pangolin/feature/main"]
        let short = tags ? "releases/v1" : "feature/main"
        let matching = names.map { RepositoryReference(fullName: $0, oid: "a") }
        #expect(RepositoryReference.graphNames(matching, hosts: [], sourceMachine: "Maliwan", tags: tags) == [short])
        let peers = Array(matching.dropFirst())
        #expect(RepositoryReference.graphNames(peers, hosts: [], sourceMachine: "Maliwan",
                                              allReferences: peers, tags: tags) == [short])
        let divergentPeers = [peers[0], RepositoryReference(fullName: peers[1].fullName, oid: "b")]
        for peer in divergentPeers {
            #expect(RepositoryReference.graphNames([peer], hosts: [], sourceMachine: "Maliwan",
                                                  allReferences: divergentPeers, tags: tags) == [peer.name])
        }
        #expect(RepositoryReference.graphNames([matching[0]], hosts: [], sourceMachine: "Maliwan", tags: tags)
                == [tags ? short : "maliwan/\(short)"])
        #expect(RepositoryReference.graphNames([matching[0]], hosts: [], sourceMachine: "Maliwan",
                                              tags: tags, expanded: true) == ["maliwan/\(short)"])
        let divergent = Array(matching.prefix(2)) + [RepositoryReference(fullName: names[2], oid: "b")]
        let prefix = tags ? "tags/" : ""
        #expect(RepositoryReference.graphNames(Array(divergent.prefix(2)), hosts: [], sourceMachine: "Maliwan",
                                              allReferences: divergent, tags: tags)
                == ["maliwan/\(short)", "origin/\(prefix)\(short)"])
        #expect(RepositoryReference.graphNames([divergent[2]], hosts: [], sourceMachine: "Maliwan",
                                              allReferences: divergent, tags: tags)
                == ["pangolin/\(prefix)\(short)"])
        let other = RepositoryReference(fullName: tags ? "refs/tags/other" : "refs/heads/other", oid: "a")
        #expect(RepositoryReference.graphNames(matching + [other], hosts: [], sourceMachine: "Maliwan", tags: tags)
                == [short, tags ? "other" : "maliwan/other"])
    }
}

@Test("Branches matching this host collapse despite a differing destination and expand on hover")
func partiallyMatchingBranchNames() {
    let refs = [RepositoryReference(fullName: "refs/heads/feature/main", oid: "0"),
                RepositoryReference(fullName: "refs/remotes/pangolin/feature/main", oid: "0"),
                RepositoryReference(fullName: "refs/remotes/origin/feature/main", oid: "3")]
    let grouped = Dictionary(grouping: refs, by: \.oid)
    let names = grouped.mapValues {
        RepositoryReference.graphNames($0, hosts: [], sourceMachine: "maliwan",
                                       allReferences: refs, localMachine: "maliwan")
    }
    let expanded = grouped.mapValues {
        RepositoryReference.graphNames($0, hosts: [], sourceMachine: "maliwan", expanded: true)
    }
    #expect(names == ["0": ["feature/main"], "3": ["origin/feature/main"]])
    #expect(expanded["0"] == ["maliwan/feature/main", "pangolin/feature/main"])
    #expect(RepositoryReference.graphNames(Array(refs.prefix(2)), hosts: [], sourceMachine: "maliwan",
                                          allReferences: refs, localMachine: "atlas")
            == ["maliwan/feature/main", "pangolin/feature/main"])
    #expect(RepositoryReference.graphNames(Array(refs.prefix(2)), hosts: [], sourceMachine: "maliwan",
                                          allReferences: refs, localMachine: "pangolin") == ["feature/main"])
    let allMatching = refs.map { RepositoryReference(fullName: $0.fullName, oid: "0") }
    #expect(RepositoryReference.graphNames(allMatching, hosts: [], sourceMachine: "maliwan", expanded: true)
            == ["maliwan/feature/main", "pangolin/feature/main", "origin/feature/main"])
    #expect(RepositoryReference(fullName: "refs/remotes/my-mac/feature/main", oid: "0")
        .isPeerBranch(from: "My_Mac"))
    let commits = (0..<10).map {
        RepositoryCommit(oid: "\($0)", parents: $0 < 9 ? ["\($0 + 1)"] : [],
                         author: "", date: .distantPast, message: "")
    }
    let compact = CommitGraphGenerator.generate(commits: commits, headOID: "0", branchNames: names)
    let graph = CommitGraphGenerator.generate(commits: commits, headOID: "0", branchNames: names,
                                              hoverBranchNames: expanded, preferredHost: "maliwan")
    #expect(graph.branchLabels[0].outline == compact.branchLabels[0].outline)
    #expect(graph.branchLabels[0].hoverOutline != compact.branchLabels[0].hoverOutline)
    #expect(graph.branchLabels[0].hoverOutline.boundingRect.height > graph.branchLabels[0].outline.boundingRect.height)
    // Expansion uses the remaining room below before extending above the tip.
    #expect(graph.branchLabels[0].hoverOutline.boundingRect.maxY > graph.branchLabels[0].outline.boundingRect.maxY)
    #expect(graph.branchLabels[0].hoverOutline.boundingRect.maxY < graph.branchLabels[1].outline.boundingRect.minY)
    #expect(graph.branchLabels[1].hoverOutline == compact.branchLabels[1].hoverOutline)
}

@Test("Long lanes keep upward labels beside their tip")
func longLaneLabelStartsAtTip() {
    let commits = (0..<500).map {
        RepositoryCommit(oid: "\($0)", parents: $0 < 499 ? ["\($0 + 1)"] : [],
                         author: "", date: .distantPast, message: "")
    }
    let graph = CommitGraphGenerator.generate(commits: commits, headOID: "0",
        branchNames: ["0": ["maliwan/master", "origin/master"]])
    #expect(graph.branchLabels[0].outline.boundingRect.minY < 32)
    let preferred = CommitGraphGenerator.generate(commits: commits, headOID: "0",
        branchNames: ["0": ["origin/master", "maliwan/master"]], preferredHost: "maliwan")
    #expect(preferred.branchLabels[0].outline == graph.branchLabels[0].outline)
}

@Test("A short merged lane uses its incoming curve for the complete branch name")
func mergedLaneLabel() {
    func commit(_ id: String, _ parents: [String]) -> RepositoryCommit {
        RepositoryCommit(oid: id, parents: parents, author: "", date: .distantPast, message: "")
    }
    let commits = [commit("merge", ["root", "feature"]), commit("feature", ["root"]), commit("root", [])]
    let graph = CommitGraphGenerator.generate(commits: commits,
        headOID: "merge", branchNames: ["feature": ["maliwan/main"]])
    #expect(graph.branchLabels[0].outline.boundingRect.minY < 44)
    let long = CommitGraphGenerator.generate(commits: commits + [commit("older", [])],
        headOID: "merge", branchNames: ["merge": ["maliwan/main"]])
    var shortElements = 0, fullElements = 0
    graph.branchLabels[0].outline.forEach { _ in shortElements += 1 }
    long.branchLabels[0].outline.forEach { _ in fullElements += 1 }
    #expect(shortElements == fullElements)
}

@Test("Tag badges include local and peer tags but exclude branches, stash and expired refs")
func graphTagReferences() {
    let names = ["refs/tags/v1", "refs/tags/releases/v2", "refs/sync/pangolin/tags/v1",
                 "refs/heads/tags/topic", "refs/remotes/origin/main", "refs/sync/pangolin/stash",
                 "refs/sync/pangolin/expired/123/1/tags/v1", "HEAD"]
    #expect(names.filter { RepositoryReference(fullName: $0, oid: "a").isGraphTag } == Array(names.prefix(3)))
}

@Test("Label clearance follows the path normal on horizontal bends")
func curvedLabelClearance() {
    var path = Path()
    path.move(to: CGPoint(x: 0, y: 100))
    path.addLine(to: CGPoint(x: 100, y: 100))
    let label = GraphBranchLabel.outline("MALIWAN/MAIN", along: path)
    #expect(label.boundingRect.maxY < 94)
    #expect(label.boundingRect.minY > 84)
}

@Test("Long curved labels retain every glyph and leave a gap at the lower tip")
func longLabelDoesNotEllipsize() {
    var short = Path()
    short.move(to: CGPoint(x: 0, y: 0))
    short.addLine(to: CGPoint(x: 0, y: 50))
    var long = Path()
    long.move(to: CGPoint(x: 0, y: 0))
    long.addLine(to: CGPoint(x: 0, y: 300))
    let name = "MALIWAN/CODEX/GIT-FOR-EVERYONE"
    let compact = GraphBranchLabel.outline(name, along: short)
    let roomy = GraphBranchLabel.outline(name, along: long)
    var compactElements = 0, roomyElements = 0
    compact.forEach { _ in compactElements += 1 }
    roomy.forEach { _ in roomyElements += 1 }
    #expect(compactElements == roomyElements)
    #expect(compact.boundingRect.maxY <= 46)
    #expect(compact.boundingRect.minY < 0)
}

@Test("Distant branch tips on one lane keep labels beside their own commits")
func distantBranchLabelsStayAtTheirCommits() {
    let commits = (0..<100).map {
        RepositoryCommit(oid: "\($0)", parents: $0 < 99 ? ["\($0 + 1)"] : [],
                         author: "", date: .distantPast, message: "")
    }
    let graph = CommitGraphGenerator.generate(commits: commits, headOID: "0",
        branchNames: ["0": ["main"], "70": ["origin/codex/issue-242-dismiss-approval-notifications"]])
    #expect(graph.branchLabels.count == 2)
    let distant = graph.branchLabels.filter { $0.outline.boundingRect.minY > 69 * BranchGraphRowCanvas.rowHeight }
    #expect(distant.count == 1)
    #expect(distant.first.map { $0.outline.boundingRect.minY < 71 * BranchGraphRowCanvas.rowHeight } == true)
}

@Test("auxiliary tips receive visible labels and duplicate worktree names remain distinguishable")
func auxiliaryHistoryLabels() {
    let root = RepositoryCommit(oid: "root", parents: [], author: "", date: .distantPast, message: "base")
    let tip = RepositoryCommit(oid: "tip", parents: ["root"], author: "", date: .distantPast, message: "detached")
    let saved = RepositoryCommit(oid: "saved", parents: ["root"], author: "", date: .distantPast, message: "snapshot")
    let ref = RepositoryReference(fullName: "refs/codex/snapshots/7d93887b2ca1", oid: "saved")
    let backup = RepositoryCommit(oid: "backup", parents: ["root"], author: "", date: .distantPast, message: "before squash")
    let backupRef = RepositoryReference(fullName: "refs/backup/before-related-squash", oid: "backup")
    let snapshot = RepositorySnapshot(commits: [tip, saved, backup, root], references: [ref, backupRef], head: nil, branches: [],
        detachedWorktrees: ["tip": ["/tmp/checkout", "/tmp/one/project", "/tmp/two/project"]])
    #expect(snapshot.auxiliaryHistoryLabels["tip"] == [
        "checkout (detached)", "/tmp/one/project (detached)", "/tmp/two/project (detached)"
    ])
    let graph = CommitGraphGenerator.generate(commits: snapshot.commits, headOID: nil,
                                             branchNames: snapshot.auxiliaryHistoryLabels)
    #expect(snapshot.auxiliaryHistoryLabels["saved"] == ["Codex snapshot 7d93887b"])
    #expect(snapshot.auxiliaryHistoryLabels["backup"] == ["Backup before-related-squash"])
    #expect(graph.branchLabels.count == 3)
    #expect(graph.branchLabels.allSatisfy { !$0.outline.isEmpty })
}

@Test("Primary lane labels prefer the right and use the left to avoid truncation", arguments: ["0", "3"])
func primaryLaneLabelsUseAvailableSpace(headOID: String) {
    let commits = (0..<12).map {
        RepositoryCommit(oid: "\($0)", parents: $0 < 11 ? ["\($0 + 1)"] : [],
                         author: "", date: .distantPast, message: "")
    }
    let names = ["0": ["codex/history-complete-windows"], "3": ["main"], "8": ["older"]]
    let graph = CommitGraphGenerator.generate(commits: commits, headOID: headOID, branchNames: names,
        hoverBranchNames: ["0": ["maliwan/codex/history-complete-windows", "origin/codex/history-complete-windows"]])
    #expect(graph.branchLabels.count == 3)
    let moved = graph.branchLabels[0]
    for outline in [moved.outline, moved.hoverOutline] {
        #expect(!outline.isEmpty)
        #expect(outline.boundingRect.maxX < BranchGraphRowCanvas.laneWidth / 2 - 7)
        #expect(outline.boundingRect.minX + BranchGraphRowCanvas.leadingPadding >= 0)
    }
    #expect(moved.outline.boundingRect.height > 3 * BranchGraphRowCanvas.rowHeight)
    #expect(moved.hoverOutline.boundingRect.minY >= 0.5 * BranchGraphRowCanvas.rowHeight)
    #expect(moved.hoverOutline.boundingRect.maxY > moved.outline.boundingRect.maxY)
    #expect(moved.hoverOutline.boundingRect.maxY < CGFloat(commits.count) * BranchGraphRowCanvas.rowHeight)
    for label in graph.branchLabels.dropFirst() {
        #expect(label.outline.boundingRect.minX > BranchGraphRowCanvas.laneWidth / 2)
    }
    let roomy = CommitGraphGenerator.generate(commits: commits, headOID: "0", branchNames: ["0": names["0"]!])
    #expect(roomy.branchLabels[0].outline.boundingRect.minX > BranchGraphRowCanvas.laneWidth / 2)
}

@Test("Crowded primary lane labels use both sides and still truncate when both are full")
func crowdedPrimaryLaneLabels() {
    let commits = (0..<8).map {
        RepositoryCommit(oid: "\($0)", parents: $0 < 7 ? ["\($0 + 1)"] : [],
                         author: "", date: .distantPast, message: "")
    }
    let names = Dictionary(uniqueKeysWithValues: commits.prefix(6).map {
        ($0.oid, ["codex/a-long-branch-name-that-cannot-fit-between-adjacent-commits"])
    })
    let graph = CommitGraphGenerator.generate(commits: commits, headOID: "0", branchNames: names)
    #expect(graph.branchLabels.count == names.count)
    #expect(graph.branchLabels.allSatisfy { !$0.outline.isEmpty })
    #expect(graph.branchLabels.contains { $0.outline.boundingRect.maxX < 12 })
    #expect(graph.branchLabels.contains { $0.outline.boundingRect.minX > 12 })
    #expect(graph.branchLabels.contains { $0.hoverOutline.boundingRect.height > $0.outline.boundingRect.height })
    for (index, label) in graph.branchLabels.enumerated() {
        for other in graph.branchLabels.dropFirst(index + 1) {
            #expect(!label.outline.boundingRect.intersects(other.outline.boundingRect))
        }
    }
}

@Test("Branch label hit targets preserve each name through uppercase rendering and hover")
func branchLabelHitTargets() throws {
    let commits = (0..<12).map { index in
        RepositoryCommit(oid: "c\(index)", parents: index < 11 ? ["c\(index + 1)"] : [],
                         author: "", date: .distantPast, message: "commit")
    }
    let names = ["feature/Case", "main"]
    let expanded = ["host/feature/Case", "host/main"]
    let model = CommitGraphGenerator.generate(commits: commits, headOID: "c0",
        branchNames: ["c0": names], hoverBranchNames: ["c0": expanded])
    let label = try #require(model.branchLabels.first)
    for hovered in [false, true] {
        let targets = hovered ? label.hoverReferences : label.references
        #expect(Set(targets.map(\.name)) == Set(hovered ? expanded : names))
        for target in targets {
            #expect(!target.outline.isEmpty)
            let rect = target.outline.boundingRect
            let hit = stride(from: rect.minY, through: rect.maxY, by: 1).contains { y in
                stride(from: rect.minX, through: rect.maxX, by: 1).contains { x in
                    label.reference(at: CGPoint(x: x, y: y), hovered: hovered) == target.name
                }
            }
            #expect(hit)
        }
        #expect(label.reference(at: CGPoint(x: -1000, y: -1000), hovered: hovered) == nil)
    }
}

private struct BranchClickProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@Test("Branch clicks insert without selecting their commit row", arguments: [false, true])
@MainActor func branchClickDoesNotSelectRow(hovered: Bool) throws {
    NSApplication.shared.finishLaunching()
    let commit = RepositoryCommit(oid: "tip", parents: [], author: "", date: .distantPast, message: "tip")
    var model = CommitGraphGenerator.generate(commits: [commit], headOID: nil)
    let outline = Path(CGRect(x: 4, y: 4, width: 16, height: 32))
    let hoverOutline = outline.offsetBy(dx: 36, dy: 0)
    model.branchLabels = [GraphBranchLabel(outline: outline, hoverOutline: hoverOutline, colorIndex: 0,
        references: [("main", outline)], hoverReferences: [("main", hoverOutline)])]
    var selection: String?
    var inserted: [String] = []
    let probe = NSView()
    let root = List(selection: Binding(get: { selection }, set: { selection = $0 })) {
        HStack {
            BranchGraphRowCanvas(model: model, rowIndex: 0, commitOID: "tip", hoveredLabel: .constant(hovered ? 0 : nil)) {
                inserted.append($0)
                selection = nil
            }
            .background(BranchClickProbe(view: probe))
            Text("Commit subject").frame(width: 160, height: 44)
        }.tag("tip")
    }
    let window = NSWindow(contentViewController: NSHostingController(rootView: root))
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 300, height: 160))
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    window.makeKey()
    func click(_ point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.postEvent(event, atStart: false)
        }
        let deadline = Date().addingTimeInterval(0.1)
        while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
    // Hit the left edge of the label's stroked outline.
    try click(probe.convert(NSPoint(x: hovered ? 44 : 8, y: probe.bounds.midY), to: nil))
    #expect(inserted == ["main"])
    #expect(selection == nil)
    try click(probe.convert(NSPoint(x: 100, y: probe.bounds.midY), to: nil))
    #expect(selection == "tip")
    #expect(inserted == ["main"])
}

@Test("Branch hover reaches labels covered by reference buttons")
@MainActor func branchHoverThroughReferenceButtons() throws {
    NSApplication.shared.finishLaunching()
    let commit = RepositoryCommit(oid: "tip", parents: [], author: "", date: .distantPast, message: "tip")
    var model = CommitGraphGenerator.generate(commits: [commit], headOID: nil)
    let outline = Path(CGRect(x: 4, y: 4, width: 16, height: 32))
    let hoverOutline = outline
    model.branchLabels = [GraphBranchLabel(outline: outline, hoverOutline: hoverOutline, colorIndex: 0,
        references: [("main", outline)], hoverReferences: [("main", hoverOutline)])]
    var hoveredLabel: Int?
    let probe = NSView()
    let root = List {
        HStack {
            BranchGraphRowCanvas(model: model, rowIndex: 0, commitOID: "tip", hoveredLabel: Binding(get: { hoveredLabel }, set: { hoveredLabel = $0 }))
            .background(BranchClickProbe(view: probe))
            Text("Commit subject").frame(width: 160, height: 44)
        }.tag("tip")
    }
    let window = NSWindow(contentViewController: NSHostingController(rootView: root))
    window.acceptsMouseMovedEvents = true
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 300, height: 160))
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    let originalPointer = NSEvent.mouseLocation
    let screenHeight = try #require(NSScreen.screens.first).frame.height
    defer {
        window.orderOut(nil)
        CGWarpMouseCursorPosition(CGPoint(x: originalPointer.x, y: screenHeight - originalPointer.y))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    window.makeKey()
    func move(_ point: NSPoint) throws {
        let screenPoint = window.convertPoint(toScreen: point)
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y))
        let localEvent = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        NSApp.postEvent(localEvent, atStart: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let deadline = Date().addingTimeInterval(0.1)
        while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
    try move(probe.convert(NSPoint(x: 8, y: probe.bounds.midY), to: nil))
    #expect(hoveredLabel == 0)
    try move(probe.convert(NSPoint(x: 30, y: probe.bounds.midY), to: nil))
    #expect(hoveredLabel == nil)
}
