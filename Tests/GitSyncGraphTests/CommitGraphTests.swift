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
