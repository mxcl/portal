//
//  macgit (Commit+) - a macOS Git client built with Swift and SwiftUI.
//  Copyright (C) 2026  Thanh Tran <trantienthanh2412@gmail.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU Affero General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU Affero General Public License for more details.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
import SwiftUI

public struct BranchGraphRowCanvas: View {
    static let rowHeight: CGFloat = 44
    static let laneWidth: CGFloat = 24
    static let dotSize: CGFloat = 8
    static let trailingPadding: CGFloat = 4
    static let verticalBleed: CGFloat = 2

    let model: CommitGraphModel
    let rowIndex: Int
    let commitOID: String
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var graphWidth: CGFloat {
        Self.graphWidth(model: model, commitOID: commitOID)
    }

    public init(model: CommitGraphModel, rowIndex: Int, commitOID: String) {
        self.model = model
        self.rowIndex = rowIndex
        self.commitOID = commitOID
    }

    public static func graphWidth(model: CommitGraphModel, commitOID: String) -> CGFloat {
        CGFloat(model.laneCount(for: commitOID)) * laneWidth + trailingPadding
    }

    public var body: some View {
        Canvas { context, _ in
            context.translateBy(x: 0, y: Self.verticalBleed)
            drawRow(in: &context)
        }
        .frame(width: graphWidth, height: Self.rowHeight + Self.verticalBleed * 2)
        // Draw through List's native vertical insets so paths meet between rows.
        .padding(.vertical, -(4 + Self.verticalBleed))
        .accessibilityHidden(true)
    }

    private func drawRow(in context: inout GraphicsContext) {
        guard model.rowSlices.indices.contains(rowIndex) else { return }
        let row = model.rowSlices[rowIndex]
        let strokeStyle = StrokeStyle(
            lineWidth: 1.2,
            lineCap: .round,
            lineJoin: .round
        )
        let rowOffset = Double(rowIndex)

        for pathIndex in row.pathIndices where model.paths.indices.contains(pathIndex) {
            let graphPath = model.paths[pathIndex]
            var pathStyle = strokeStyle
            pathStyle.dash = graphPath.isDashed ? [4, 4] : []
            context.stroke(
                BranchGraphCanvas.path(
                    for: graphPath,
                    rowHeight: Self.rowHeight,
                    laneWidth: Self.laneWidth,
                    rowOffset: rowOffset
                ),
                with: .color(BranchGraphCanvas.lineColor(
                    colorIndex: graphPath.colorIndex,
                    isHighlighted: graphPath.isHighlighted
                )),
                style: pathStyle
            )
        }

        for linkIndex in row.linkIndices where model.links.indices.contains(linkIndex) {
            let link = model.links[linkIndex]
            context.stroke(
                BranchGraphCanvas.linkPath(
                    for: link,
                    rowHeight: Self.rowHeight,
                    laneWidth: Self.laneWidth,
                    rowOffset: rowOffset
                ),
                with: .color(BranchGraphCanvas.lineColor(
                    colorIndex: link.colorIndex,
                    isHighlighted: link.isHighlighted
                )),
                style: strokeStyle
            )
        }

        for label in model.branchLabels {
            let bounds = label.outline.boundingRect
            guard bounds.maxY >= CGFloat(rowIndex) * Self.rowHeight - Self.verticalBleed,
                  bounds.minY <= CGFloat(rowIndex + 1) * Self.rowHeight + Self.verticalBleed else { continue }
            let outline = label.outline.offsetBy(dx: 0, dy: -CGFloat(rowIndex) * Self.rowHeight)
            context.fill(outline, with: .color(GraphPalette.color(for: label.colorIndex)))
        }

        for dotIndex in row.dotIndices where model.dots.indices.contains(dotIndex) {
            BranchGraphCanvas.drawDot(
                model.dots[dotIndex],
                in: &context,
                rowHeight: Self.rowHeight,
                laneWidth: Self.laneWidth,
                dotSize: Self.dotSize,
                rowOffset: rowOffset,
                background: dotBackground
            )
        }
    }

    private var dotBackground: Color {
        if backgroundProminence == .increased {
            return Color(nsColor: .selectedContentBackgroundColor)
        }

        let rowBackgrounds = NSColor.alternatingContentBackgroundColors
        guard !rowBackgrounds.isEmpty else {
            return Color(nsColor: .controlBackgroundColor)
        }
        return Color(nsColor: rowBackgrounds[rowIndex % rowBackgrounds.count])
    }
}
