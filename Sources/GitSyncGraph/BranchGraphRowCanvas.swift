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
    static let preferredLaneWidth: CGFloat = 14
    static let maximumWidth: CGFloat = 180
    static let trailingPadding: CGFloat = 4

    let model: CommitGraphModel
    let rowIndex: Int
    let commitOID: String
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var graphWidth: CGFloat {
        Self.graphWidth(model: model, commitOID: commitOID)
    }

    private var laneWidth: CGFloat {
        Self.laneWidth(model: model)
    }

    public init(model: CommitGraphModel, rowIndex: Int, commitOID: String) {
        self.model = model
        self.rowIndex = rowIndex
        self.commitOID = commitOID
    }

    static func graphWidth(model: CommitGraphModel, commitOID: String) -> CGFloat {
        CGFloat(model.laneCount(for: commitOID)) * laneWidth(model: model) + trailingPadding
    }

    private static func laneWidth(model: CommitGraphModel) -> CGFloat {
        min(preferredLaneWidth, (maximumWidth - trailingPadding) / CGFloat(model.laneCount))
    }

    public var body: some View {
        Canvas { context, _ in
            drawRow(in: &context)
        }
        .frame(width: graphWidth, height: Self.rowHeight)
        // Draw through List's native vertical insets so paths meet between rows.
        .padding(.vertical, -4)
        .accessibilityHidden(true)
    }

    private func drawRow(in context: inout GraphicsContext) {
        guard model.rowSlices.indices.contains(rowIndex) else { return }
        let row = model.rowSlices[rowIndex]
        let strokeStyle = StrokeStyle(
            lineWidth: min(2.2, laneWidth * 0.45),
            lineCap: .round,
            lineJoin: .round
        )
        let rowOffset = Double(rowIndex)

        for pathIndex in row.pathIndices where model.paths.indices.contains(pathIndex) {
            let graphPath = model.paths[pathIndex]
            context.stroke(
                BranchGraphCanvas.path(
                    for: graphPath,
                    rowHeight: Self.rowHeight,
                    laneWidth: laneWidth,
                    rowOffset: rowOffset
                ),
                with: .color(BranchGraphCanvas.lineColor(
                    colorIndex: graphPath.colorIndex,
                    isHighlighted: graphPath.isHighlighted
                )),
                style: strokeStyle
            )
        }

        for linkIndex in row.linkIndices where model.links.indices.contains(linkIndex) {
            let link = model.links[linkIndex]
            context.stroke(
                BranchGraphCanvas.linkPath(
                    for: link,
                    rowHeight: Self.rowHeight,
                    laneWidth: laneWidth,
                    rowOffset: rowOffset
                ),
                with: .color(BranchGraphCanvas.lineColor(
                    colorIndex: link.colorIndex,
                    isHighlighted: link.isHighlighted
                )),
                style: strokeStyle
            )
        }

        for dotIndex in row.dotIndices where model.dots.indices.contains(dotIndex) {
            BranchGraphCanvas.drawDot(
                model.dots[dotIndex],
                in: &context,
                rowHeight: Self.rowHeight,
                laneWidth: laneWidth,
                dotSize: min(8, max(3, laneWidth * 0.7)),
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
