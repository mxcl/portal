import AppKit
import CoreText
import GitSyncCore
import SwiftUI

extension RepositoryReference {
    public static func graphNames(_ references: [Self], hosts: [SyncHost], sourceMachine: String? = nil) -> [String] {
        var seen: [String: Set<String>] = [:]
        return references.filter(\.isGraphBranch).compactMap { branch in
            let name: String
            if branch.fullName.hasPrefix("refs/heads/"), let sourceMachine {
                name = "\(sourceMachine.lowercased())/\(branch.name)"
            } else {
                name = branch.displayName(hosts: hosts)
            }
            return seen[branch.oid, default: []].insert(name).inserted ? name : nil
        }
    }

    public var isGraphTag: Bool {
        if fullName.hasPrefix("refs/tags/") { return true }
        let parts = fullName.split(separator: "/", maxSplits: 4)
        return parts.count == 5 && parts[0] == "refs" && parts[1] == "sync" && parts[3] == "tags"
    }

    public var isGraphBranch: Bool {
        fullName.hasPrefix("refs/heads/") ||
            (fullName.hasPrefix("refs/remotes/") && !fullName.hasSuffix("/HEAD"))
    }
}

struct GraphBranchLabel: Sendable {
    let outline: Path
    let colorIndex: Int

    static func make(names: [String: [String]], commits: [RepositoryCommit], model: CommitGraphModel, preferredHost: String? = nil) -> [Self] {
        let anchors = commits.enumerated().compactMap { row, commit -> (dot: GraphDot, name: String, route: Int)? in
            guard let names = names[commit.oid], !names.isEmpty else { return nil }
            let dot = model.dots[row]
            let route = model.paths.firstIndex { path in
                !path.isDashed && path.colorIndex == dot.colorIndex &&
                    path.points.first!.y <= dot.center.y && path.points.last!.y > dot.center.y
            }
            // Isolated tips get their own label rather than sharing an unrelated lane.
            return (dot, names.joined(separator: " · ").uppercased(), route ?? model.paths.count + row)
        }
        let groups = Dictionary(grouping: anchors, by: \.route)
        return groups.keys.sorted().map { key in
            let group = groups[key]!
            let dot = group[0].dot
            let names = group.flatMap { $0.name.components(separatedBy: " · ") }
            let prefix = preferredHost.map { $0.uppercased() + "/" }
            let ordered = names.filter { prefix.map($0.hasPrefix) ?? false } +
                names.filter { !(prefix.map($0.hasPrefix) ?? false) }
            // The last name in an upward-reading line is physically at the top.
            let name = ordered.reversed().joined(separator: " · ")
            let route = model.paths.indices.contains(key) ? model.paths[key] : nil
            var path = route.map {
                BranchGraphCanvas.path(for: $0, rowHeight: BranchGraphRowCanvas.rowHeight,
                                       laneWidth: BranchGraphRowCanvas.laneWidth)
            } ?? Path()
            let incoming = route.flatMap { route in
                model.links.first { $0.end == route.points.first && $0.colorIndex == route.colorIndex }
            }
            if let incoming {
                var complete = BranchGraphCanvas.linkPath(for: incoming,
                    rowHeight: BranchGraphRowCanvas.rowHeight, laneWidth: BranchGraphRowCanvas.laneWidth)
                complete.addPath(path)
                path = complete
            }
            let start = BranchGraphCanvas.position(for: incoming?.start ?? dot.center, rowHeight: BranchGraphRowCanvas.rowHeight,
                                                    laneWidth: BranchGraphRowCanvas.laneWidth)
            if path.isEmpty {
                path.move(to: start)
                path.addLine(to: CGPoint(x: start.x, y: start.y + BranchGraphRowCanvas.rowHeight / 2 - 2))
            }
            func fraction(atY y: CGFloat) -> CGFloat {
                var low: CGFloat = 0
                var high: CGFloat = 1
                for _ in 0..<18 {
                    let middle = (low + high) / 2
                    if (path.trimmedPath(from: 0, to: middle).currentPoint?.y ?? 0) < y {
                        low = middle
                    } else {
                        high = middle
                    }
                }
                return (low + high) / 2
            }
            let trimmed = path.trimmedPath(from: fraction(atY: start.y + 5), to: 1)
            return Self(outline: outline(name, along: trimmed), colorIndex: dot.colorIndex)
        }
    }

    private static func outline(_ text: String, along path: Path) -> Path {
        // Sample the existing curve once; glyphs use its tangent and distance, including lane bends.
        var start: CGPoint?
        path.forEach { element in
            if case .move(to: let point) = element, start == nil { start = point }
        }
        guard let start else { return Path() }
        // Very short trims can be empty. Keep the actual start rather than skipping
        // to the first sample (which can be several rows down a long history).
        let points = [start] + (1...128).compactMap {
            path.trimmedPath(from: 0, to: CGFloat($0) / 128).currentPoint
        }
        guard points.count > 1 else { return Path() }
        var distances: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) {
            distances.append(distances.last! + hypot(b.x - a.x, b.y - a.y))
        }
        let length = distances.last!
        guard length > 8 else { return Path() }
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 1.1]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let fitted = CTLineCreateTruncatedLine(line, Double(length), .end, ellipsis) ?? ellipsis
        let textLength = CGFloat(CTLineGetTypographicBounds(fitted, nil, nil, nil))
        var result = Path()
        for run in CTLineGetGlyphRuns(fitted) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (glyph, position) in zip(glyphs, positions) {
                guard let shape = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                let distance = textLength - position.x
                let index = min(points.count - 1, max(1, distances.firstIndex { $0 >= distance } ?? points.count - 1))
                let a = points[index - 1], b = points[index]
                let span = max(0.0001, distances[index] - distances[index - 1])
                let t = (distance - distances[index - 1]) / span
                let angle = atan2(b.y - a.y, b.x - a.x)
                let transform = CGAffineTransform(translationX: a.x + (b.x - a.x) * t + 8 + font.capHeight,
                                                  y: a.y + (b.y - a.y) * t)
                    .rotated(by: angle - .pi).scaledBy(x: 1, y: -1)
                result.addPath(Path(shape), transform: transform)
            }
        }
        return result
    }
}
