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

@Test("wide histories leave room for commit text")
func wideHistoryRowWidth() {
    let contentColumnWidth: CGFloat = 344
    let root = RepositoryCommit(oid: "root", parents: [], author: "", date: .distantPast, message: "root")
    let tips = (0..<18).map {
        RepositoryCommit(oid: "tip-\($0)", parents: [root.oid], author: "", date: .distantPast, message: "tip")
    }
    let model = CommitGraphGenerator.generate(commits: tips + [root], headOID: nil)
    let maximumWidth = BranchGraphRowCanvas.widthLimit(for: contentColumnWidth)

    #expect(model.laneCount * 14 + 4 > 240)
    #expect(maximumWidth <= contentColumnWidth * 0.35)
    #expect(BranchGraphRowCanvas.graphWidth(model: model, maximumWidth: maximumWidth) == maximumWidth)
}
