//
//  Adapted from macgit (Commit+), Copyright (C) 2026 Thanh Tran.
//  Licensed under the GNU Affero General Public License v3 or later.
//
import Foundation
import GitSyncCore
import Testing
@testable import GitSyncGraph

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

@Test("wide histories preserve native lane spacing")
func wideHistoryLaneSpacing() {
    let root = RepositoryCommit(oid: "root", parents: [], author: "", date: .distantPast, message: "root")
    let tips = (0..<18).map {
        RepositoryCommit(oid: "tip-\($0)", parents: [root.oid], author: "", date: .distantPast, message: "tip")
    }
    let model = CommitGraphGenerator.generate(commits: tips + [root], headOID: nil)

    let firstWidth = BranchGraphRowCanvas.graphWidth(model: model, commitOID: tips[0].oid)
    let lastWidth = BranchGraphRowCanvas.graphWidth(model: model, commitOID: tips.last!.oid)
    #expect(firstWidth == 18)
    #expect(abs(lastWidth - firstWidth - 17 * 14) < 0.001)
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
