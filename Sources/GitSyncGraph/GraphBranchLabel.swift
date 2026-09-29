import AppKit
import CoreText
import GitSyncCore
import SwiftUI

extension RepositorySnapshot {
    public var auxiliaryHistoryLabels: [String: [String]] {
        let paths = (detachedWorktrees ?? [:]).values.flatMap { $0 }
        let counts = Dictionary(grouping: paths, by: { ($0 as NSString).lastPathComponent })
        var labels = (detachedWorktrees ?? [:]).mapValues { paths in
            paths.map { path in
                let name = (path as NSString).lastPathComponent
                return "\(counts[name]?.count == 1 ? name : path) (detached)"
            }
        }
        for ref in references where ref.fullName.hasPrefix("refs/codex/snapshots/") {
            labels[ref.oid, default: []].append(ref.displayName(hosts: []))
        }
        return labels
    }
}

extension RepositoryReference {
    public static func graphNames(_ references: [Self], hosts: [SyncHost], sourceMachine: String? = nil,
                                  allReferences: [Self]? = nil, tags: Bool = false,
                                  localMachine: String? = nil, expanded: Bool = false) -> [String] {
        let candidates = (allReferences ?? references).filter { tags ? $0.isGraphTag : $0.isGraphBranch }
        let groups = Dictionary(grouping: candidates, by: \.graphShortName)
        var seen: [String: Set<String>] = [:]
        return references.filter { tags ? $0.isGraphTag : $0.isGraphBranch }.compactMap { ref in
            let group = groups[ref.graphShortName] ?? []
            let name: String
            let matching = group.filter { $0.oid == ref.oid }
            let matchesLocal = !tags && localMachine.map { machine in
                matching.contains {
                    ($0.fullName.hasPrefix("refs/heads/") && sourceMachine == machine) ||
                        $0.isPeerBranch(from: machine)
                }
            } == true
            if !expanded && matching.count > 1 && (matching.count == group.count || matchesLocal) {
                name = ref.graphShortName
            } else if (ref.fullName.hasPrefix("refs/heads/") || ref.fullName.hasPrefix("refs/tags/")),
                      let sourceMachine {
                name = "\(sourceMachine.lowercased())/\(ref.graphShortName)"
            } else {
                name = ref.displayName(hosts: hosts)
            }
            return seen[ref.oid, default: []].insert(name).inserted ? name : nil
        }
    }

    private var graphShortName: String {
        if fullName.hasPrefix("refs/remotes/") {
            return String(fullName.split(separator: "/", maxSplits: 3).last ?? "")
        }
        if fullName.hasPrefix("refs/sync/") {
            return String(fullName.split(separator: "/", maxSplits: 4).last ?? "")
        }
        return name
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
    let hoverOutline: Path
    let colorIndex: Int

    static func make(names: [String: [String]], hoverNames: [String: [String]] = [:], commits: [RepositoryCommit], model: CommitGraphModel, preferredHost: String? = nil) -> [Self] {
        let anchors = commits.enumerated().compactMap { row, commit -> (dot: GraphDot, names: [String], hoverNames: [String], route: Int)? in
            guard let names = names[commit.oid], !names.isEmpty else { return nil }
            let dot = model.dots[row]
            let route = model.paths.firstIndex { path in
                !path.isDashed && path.colorIndex == dot.colorIndex &&
                    path.points.first!.y <= dot.center.y && path.points.last!.y > dot.center.y
            }
            // Isolated tips get their own label rather than sharing an unrelated lane.
            return (dot, names, hoverNames[commit.oid] ?? names, route ?? model.paths.count + row)
        }
        let groups = Dictionary(grouping: anchors, by: \.route)
        return groups.keys.sorted().flatMap { key in
            let group = groups[key]!
            return group.enumerated().map { index, anchor in
                let dot = anchor.dot
                func text(_ names: [String]) -> String {
                    let names = names.map { $0.uppercased() }
                    let prefix = preferredHost.map { $0.uppercased() + "/" }
                    let ordered = names.filter { prefix.map($0.hasPrefix) ?? false } +
                        names.filter { !(prefix.map($0.hasPrefix) ?? false) }
                    // The last name in an upward-reading line is physically at the top.
                    return ordered.reversed().joined(separator: " · ")
                }
                let name = text(anchor.names)
                let route = model.paths.indices.contains(key) ? model.paths[key] : nil
                var path = route.map {
                    BranchGraphCanvas.path(for: $0, rowHeight: BranchGraphRowCanvas.rowHeight,
                                           laneWidth: BranchGraphRowCanvas.laneWidth)
                } ?? Path()
                let incoming = route.flatMap { route in
                    model.links.first {
                        $0.end == route.points.first && $0.colorIndex == route.colorIndex &&
                            // Incoming curves end half a row before the first commit.
                            dot.center.y <= $0.end.y + 0.5
                    }
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
                let end = group.indices.contains(index + 1)
                    ? fraction(atY: group[index + 1].dot.center.y * BranchGraphRowCanvas.rowHeight - 5) : 1
                let trimmed = path.trimmedPath(from: fraction(atY: start.y + 5), to: end)
                return Self(outline: outline(name, along: trimmed, onLeft: dot.lane == 0, truncate: group.count > 1),
                            hoverOutline: outline(name, along: trimmed, onLeft: dot.lane == 0, truncate: group.count > 1, expanded: true,
                                                  expandedText: text(anchor.hoverNames)),
                            colorIndex: dot.colorIndex)
            }
        }
    }

    static func outline(_ text: String, along path: Path, onLeft: Bool = false, truncate: Bool = false, expanded: Bool = false, expandedText: String? = nil) -> Path {
        // Sample the existing curve once; glyphs use its tangent and distance, including lane bends.
        var start: CGPoint?
        path.forEach { element in
            if case .move(to: let point) = element, start == nil { start = point }
        }
        guard let start else { return Path() }
        // Very short trims can be empty. Keep the actual start rather than skipping
        // to the first sample (which can be several rows down a long history).
        let centerline = [start] + (1...128).compactMap {
            path.trimmedPath(from: 0, to: CGFloat($0) / 128).currentPoint
        }
        guard centerline.count > 1 else { return Path() }
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let offset = onLeft ? -8 : 8 + font.capHeight
        let points = centerline.indices.map { index in
            let before = centerline[max(0, index - 1)]
            let after = centerline[min(centerline.count - 1, index + 1)]
            let dx = after.x - before.x, dy = after.y - before.y
            let length = max(0.0001, hypot(dx, dy))
            return CGPoint(x: centerline[index].x + dy / length * offset,
                           y: centerline[index].y - dx / length * offset)
        }
        var distances: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) {
            distances.append(distances.last! + hypot(b.x - a.x, b.y - a.y))
        }
        let length = distances.last!
        guard length > 8 else { return Path() }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 1.1]
        let fullLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var line = fullLine
        if truncate {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            guard let fitted = CTLineCreateTruncatedLine(line, Double(length - 4), .end, ellipsis) else { return Path() }
            line = fitted
        }
        let textLength = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Leave a little space at the lower tip. Longer names continue along the
        // upper tangent rather than losing their suffix to an ellipsis.
        let textStart = min(textLength, length - 4)
        // Expansion keeps the first glyph anchored and reveals the suffix upward.
        if expanded {
            line = expandedText.map {
                CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
            } ?? fullLine
        }
        var result = Path()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (index, glyph) in glyphs.enumerated() {
                let position = positions[index]
                let halfAdvance = advances[index].width / 2
                guard let shape = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                let distance = textStart - position.x - halfAdvance
                let index = min(points.count - 1, max(1, distances.firstIndex { $0 >= distance } ?? points.count - 1))
                let a = points[index - 1], b = points[index]
                let span = max(0.0001, distances[index] - distances[index - 1])
                let t = (distance - distances[index - 1]) / span
                let angle = atan2(b.y - a.y, b.x - a.x)
                let transform = CGAffineTransform(translationX: a.x + (b.x - a.x) * t,
                                                  y: a.y + (b.y - a.y) * t)
                    .rotated(by: angle - .pi).scaledBy(x: 1, y: -1)
                    .translatedBy(x: -halfAdvance, y: 0)
                result.addPath(Path(shape), transform: transform)
            }
        }
        return result
    }
}
