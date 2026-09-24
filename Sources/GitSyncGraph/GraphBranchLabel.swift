import AppKit
import CoreText
import GitSyncCore
import SwiftUI

extension RepositoryReference {
    public var isGraphBranch: Bool {
        fullName.hasPrefix("refs/heads/") ||
            (fullName.hasPrefix("refs/remotes/") && !fullName.hasSuffix("/HEAD"))
    }
}

struct GraphBranchLabel: Sendable {
    let outline: Path
    let colorIndex: Int

    static func make(names: [String: [String]], commits: [RepositoryCommit], model: CommitGraphModel) -> [Self] {
        let anchors = commits.enumerated().compactMap { row, commit -> (GraphDot, String)? in
            guard let names = names[commit.oid], !names.isEmpty else { return nil }
            return (model.dots[row], names.joined(separator: " · ").uppercased())
        }
        return anchors.map { dot, name in
            let route = model.paths.first { path in
                !path.isDashed && path.colorIndex == dot.colorIndex &&
                    path.points.first!.y <= dot.center.y && path.points.last!.y > dot.center.y
            }
            var path = route.map {
                BranchGraphCanvas.path(for: $0, rowHeight: BranchGraphRowCanvas.rowHeight,
                                       laneWidth: BranchGraphRowCanvas.laneWidth)
            } ?? Path()
            let start = BranchGraphCanvas.position(for: dot.center, rowHeight: BranchGraphRowCanvas.rowHeight,
                                                    laneWidth: BranchGraphRowCanvas.laneWidth)
            if path.isEmpty {
                path.move(to: start)
                path.addLine(to: CGPoint(x: start.x, y: start.y + BranchGraphRowCanvas.rowHeight / 2 - 2))
            }
            // Trim at the next named tip on this route so labels never overwrite one another.
            let endY = anchors.map(\.0).filter {
                $0.center.y > dot.center.y && $0.colorIndex == dot.colorIndex
            }.map { $0.center.y * BranchGraphRowCanvas.rowHeight - 8 }.min() ?? .greatestFiniteMagnitude
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
            let trimmed = path.trimmedPath(from: fraction(atY: start.y + 7), to: fraction(atY: endY))
            return Self(outline: outline(name, along: trimmed), colorIndex: dot.colorIndex)
        }
    }

    private static func outline(_ text: String, along path: Path) -> Path {
        // Sample the existing curve once; glyphs use its tangent and distance, including lane bends.
        let points = (0...128).compactMap {
            path.trimmedPath(from: 0, to: max(0.000001, CGFloat($0) / 128)).currentPoint
        }
        guard points.count > 1 else { return Path() }
        var distances: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) {
            distances.append(distances.last! + hypot(b.x - a.x, b.y - a.y))
        }
        let length = distances.last!
        guard length > 8 else { return Path() }
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 1.4]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let fitted = CTLineCreateTruncatedLine(line, Double(length), .end, ellipsis) ?? ellipsis
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
                let index = min(points.count - 1, max(1, distances.firstIndex { $0 >= position.x } ?? points.count - 1))
                let a = points[index - 1], b = points[index]
                let span = max(0.0001, distances[index] - distances[index - 1])
                let t = (position.x - distances[index - 1]) / span
                let angle = atan2(b.y - a.y, b.x - a.x)
                let transform = CGAffineTransform(translationX: a.x + (b.x - a.x) * t + 6,
                                                  y: a.y + (b.y - a.y) * t)
                    .rotated(by: angle).scaledBy(x: 1, y: -1)
                result.addPath(Path(shape), transform: transform)
            }
        }
        return result
    }
}
