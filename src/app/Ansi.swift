import AppKit
import Foundation
import UniformTypeIdentifiers

enum Ansi {
    final class FileLink: NSObject {
        let url: URL
        let line: Int?
        let isDirectory: Bool
        let isTextFile: Bool

        init(url: URL, line: Int?) {
            self.url = url
            var isDirectory: ObjCBool = false
            self.isDirectory = FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            self.isTextFile = contentType?.conforms(to: .text) == true
            self.line = self.isDirectory ? nil : line
        }
    }

    struct TerminalScreenState {
        let text: String
        let attributedText: NSAttributedString
        let isAlternateScreenActive: Bool
        let isApplicationCursorModeActive: Bool
    }

    struct StyledOutput {
        let plainText: String
        let attributedText: NSAttributedString
    }

    struct AlternateScreenSwitch {
        let range: Range<String.Index>
        let isActive: Bool
    }

    static func emptyAttributedOutput() -> NSAttributedString {
        NSAttributedString(string: " ", attributes: TextStyle().attributes())
    }

    final class StyledTextRenderer {
        private static let maxRenderedLines = 5_000
        private static let maxRenderedCells = 300_000
        private static let maxLineCells = 2_000

        private var pending = ""
        private var style = TextStyle()
        private var lines: [[Cell]] = [[]]
        private var cursorRow = 0
        private var cursorCol = 0
        private var savedCursorRow = 0
        private var savedCursorCol = 0
        private var viewportTop = 0
        private var rows: Int?
        private var scrollTop = 0
        private var scrollBottom = 0
        private var droppedLineCount = 0
        private var visibleCellCount = 0
        private var attributeCache: AttributeCache = [:]
        private var linkBaseDirectory: String?

        init(rows: Int? = nil) {
            self.rows = rows.map { max(1, $0) }
            scrollBottom = self.rows.map { $0 - 1 } ?? 0
        }

        func resize(rows: Int) {
            let rows = max(1, rows)
            let screenRow = cursorRow - viewportTop
            self.rows = rows
            scrollTop = 0
            scrollBottom = rows - 1
            cursorRow = viewportTop + min(max(0, screenRow), rows - 1)
        }

        func reset() {
            pending.removeAll()
            style = TextStyle()
            lines = [[]]
            cursorRow = 0
            cursorCol = 0
            savedCursorRow = 0
            savedCursorCol = 0
            viewportTop = 0
            scrollTop = 0
            scrollBottom = rows.map { $0 - 1 } ?? 0
            droppedLineCount = 0
            visibleCellCount = 0
            attributeCache.removeAll(keepingCapacity: true)
            linkBaseDirectory = nil
        }

        func process(_ text: String, linkBaseDirectory: String? = nil) -> StyledOutput {
            self.linkBaseDirectory = linkBaseDirectory
            let scalars = Array((pending + text).unicodeScalars)
            pending.removeAll()

            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]

                switch scalar.value {
                case 0x1B:
                    guard processEscape(scalars, index: &index) else {
                        pending = String(String.UnicodeScalarView(scalars[index...]))
                        index = scalars.count
                        continue
                    }
                case 0x07:
                    index += 1
                case 0x08:
                    cursorCol = max(0, cursorCol - 1)
                    index += 1
                case 0x09:
                    expandTab()
                    index += 1
                case 0x0A, 0x0B, 0x0C:
                    lineFeed()
                    index += 1
                case 0x0D:
                    cursorCol = 0
                    index += 1
                case 0x00..<0x20, 0x7F:
                    index += 1
                default:
                    put(scalar)
                    index += 1
                }
            }

            return renderedOutput()
        }

        private func processEscape(_ scalars: [Unicode.Scalar], index: inout Int) -> Bool {
            guard index + 1 < scalars.count else { return false }
            let introducer = scalars[index + 1]

            if introducer == "[" {
                var cursor = index + 2
                while cursor < scalars.count {
                    let value = scalars[cursor].value
                    if value >= 0x40 && value <= 0x7E {
                        let body = scalars[(index + 2)..<cursor]
                        handleCSI(body: body, final: scalars[cursor])
                        index = cursor + 1
                        return true
                    }
                    cursor += 1
                }
                return false
            }

            if introducer == "]" {
                var cursor = index + 2
                while cursor < scalars.count {
                    if scalars[cursor].value == 0x07 {
                        index = cursor + 1
                        return true
                    }
                    if scalars[cursor].value == 0x1B {
                        guard cursor + 1 < scalars.count else { return false }
                        if scalars[cursor + 1] == "\\" {
                            index = cursor + 2
                            return true
                        }
                    }
                    cursor += 1
                }
                return false
            }

            if Ansi.isCharacterSetSelectionIntroducer(introducer) {
                guard index + 2 < scalars.count else { return false }
                index += 3
                return true
            }

            switch introducer {
            case "7":
                saveCursor()
            case "8":
                restoreCursor()
            case "D":
                lineFeed()
            case "E":
                cursorCol = 0
                lineFeed()
            case "M":
                reverseIndex()
            case "c":
                reset()
            default:
                break
            }
            index += 2
            return true
        }

        private func handleCSI<C: Collection>(
            body: C,
            final: Unicode.Scalar
        ) where C.Element == Unicode.Scalar {
            let privateMode = body.first == "?"
            guard !privateMode else { return }

            switch final {
            case "A":
                moveCursorRows(-firstParameter(body, defaultValue: 1))
            case "B":
                moveCursorRows(firstParameter(body, defaultValue: 1))
            case "C":
                cursorCol += firstParameter(body, defaultValue: 1)
            case "D":
                cursorCol = max(0, cursorCol - firstParameter(body, defaultValue: 1))
            case "E":
                moveCursorRows(firstParameter(body, defaultValue: 1))
                cursorCol = 0
            case "F":
                moveCursorRows(-firstParameter(body, defaultValue: 1))
                cursorCol = 0
            case "G":
                cursorCol = max(0, firstParameter(body, defaultValue: 1) - 1)
            case "H", "f":
                let parameters = parseParameters(body)
                cursorRow = absoluteRow(parameter(parameters, at: 0, defaultValue: 1) - 1)
                cursorCol = max(0, parameter(parameters, at: 1, defaultValue: 1) - 1)
            case "J":
                eraseDisplay(firstParameter(body, defaultValue: 0))
            case "K":
                eraseLine(firstParameter(body, defaultValue: 0))
            case "X":
                eraseCharacters(firstParameter(body, defaultValue: 1))
            case "S":
                scrollUp(firstParameter(body, defaultValue: 1))
            case "T":
                scrollDown(firstParameter(body, defaultValue: 1))
            case "d":
                cursorRow = absoluteRow(firstParameter(body, defaultValue: 1) - 1)
            case "m":
                let parameters = parseParameters(body)
                style.applySGR(parameters)
            case "s":
                saveCursor()
            case "u":
                restoreCursor()
            case "r":
                setScrollRegion(body)
            default:
                break
            }
        }

        private func put(_ scalar: Unicode.Scalar) {
            if cursorCol >= Self.maxLineCells {
                lineFeed()
            }
            ensureCursorRow()
            cursorCol = min(cursorCol, Self.maxLineCells - 1)
            while lines[cursorRow].count < cursorCol {
                lines[cursorRow].append(Cell(scalar: " ", style: style))
                visibleCellCount += 1
            }
            if cursorCol < lines[cursorRow].count {
                lines[cursorRow][cursorCol] = Cell(scalar: scalar, style: style)
            } else {
                lines[cursorRow].append(Cell(scalar: scalar, style: style))
                visibleCellCount += 1
            }
            cursorCol += 1
        }

        private func expandTab() {
            for _ in 0..<(8 - cursorCol % 8) {
                put(" ")
            }
        }

        private func lineFeed() {
            if rows != nil, cursorRow - viewportTop == scrollBottom {
                scrollUp(1)
            } else {
                moveCursorRows(1)
            }
            cursorCol = 0
            ensureCursorRow()
        }

        private func reverseIndex() {
            if rows != nil, cursorRow - viewportTop == scrollTop {
                scrollDown(1)
            } else {
                moveCursorRows(-1)
            }
        }

        private func moveCursorRows(_ offset: Int) {
            guard let rows else {
                cursorRow = max(0, cursorRow + offset)
                return
            }
            let screenRow = min(max(0, cursorRow - viewportTop + offset), rows - 1)
            cursorRow = viewportTop + screenRow
        }

        private func absoluteRow(_ screenRow: Int) -> Int {
            guard let rows else { return max(0, screenRow) }
            return viewportTop + min(max(0, screenRow), rows - 1)
        }

        private func ensureCursorRow(_ requestedRow: Int? = nil) {
            let row = requestedRow ?? cursorRow
            var didAppendRow = false
            while row >= lines.count {
                lines.append([])
                didAppendRow = true
            }
            if didAppendRow {
                trimScrollbackIfNeeded()
            }
        }

        private func eraseDisplay(_ mode: Int) {
            switch mode {
            case 0:
                eraseLine(0)
                if cursorRow + 1 < lines.count {
                    let range = (cursorRow + 1)..<lines.count
                    visibleCellCount -= lines[range].reduce(0) { $0 + $1.count }
                    lines.removeSubrange(range)
                }
            case 1:
                eraseLine(1)
                if cursorRow > 0, !lines.isEmpty {
                    for row in 0..<min(cursorRow, lines.count) {
                        visibleCellCount -= lines[row].count
                        lines[row] = []
                    }
                }
            case 2, 3:
                lines = [[]]
                cursorRow = 0
                cursorCol = 0
                visibleCellCount = 0
            default:
                break
            }
        }

        private func eraseLine(_ mode: Int) {
            guard cursorRow < lines.count else { return }
            cursorCol = min(cursorCol, Self.maxLineCells - 1)
            switch mode {
            case 0:
                if cursorCol < lines[cursorRow].count {
                    visibleCellCount -= lines[cursorRow].count - cursorCol
                    lines[cursorRow].removeSubrange(cursorCol..<lines[cursorRow].count)
                }
            case 1:
                while lines[cursorRow].count <= cursorCol {
                    lines[cursorRow].append(Cell(scalar: " ", style: style))
                    visibleCellCount += 1
                }
                for col in 0...cursorCol {
                    lines[cursorRow][col] = Cell(scalar: " ", style: style)
                }
            case 2:
                visibleCellCount -= lines[cursorRow].count
                lines[cursorRow] = []
            default:
                break
            }
        }

        private func eraseCharacters(_ count: Int) {
            guard count > 0, cursorRow < lines.count else { return }
            cursorCol = min(cursorCol, Self.maxLineCells - 1)
            let end = min(lines[cursorRow].count, cursorCol + count)
            guard cursorCol < end else { return }
            for col in cursorCol..<end {
                lines[cursorRow][col] = Cell(scalar: " ", style: style)
            }
        }

        private func setScrollRegion<C: Collection>(_ body: C) where C.Element == Unicode.Scalar {
            guard let rows else { return }
            let parameters = parseParameters(body)
            let top = parameter(parameters, at: 0, defaultValue: 1) - 1
            let bottom = parameter(parameters, at: 1, defaultValue: rows) - 1
            if top >= 0, bottom < rows, top < bottom {
                scrollTop = top
                scrollBottom = bottom
            } else {
                scrollTop = 0
                scrollBottom = rows - 1
            }
            cursorRow = viewportTop
            cursorCol = 0
        }

        private func scrollUp(_ requestedCount: Int) {
            guard let rows else { return }
            let count = min(max(0, requestedCount), scrollBottom - scrollTop + 1)
            guard count > 0 else { return }

            if scrollTop == 0, scrollBottom == rows - 1 {
                for _ in 0..<count {
                    viewportTop += 1
                    cursorRow += 1
                    savedCursorRow += 1
                    ensureCursorRow(viewportTop + rows - 1)
                }
                return
            }

            ensureCursorRow(viewportTop + scrollBottom)
            let start = viewportTop + scrollTop
            let end = viewportTop + scrollBottom
            for _ in 0..<count {
                visibleCellCount -= lines[start].count
                lines.remove(at: start)
                lines.insert([], at: end)
            }
        }

        private func scrollDown(_ requestedCount: Int) {
            guard rows != nil else { return }
            let count = min(max(0, requestedCount), scrollBottom - scrollTop + 1)
            guard count > 0 else { return }
            ensureCursorRow(viewportTop + scrollBottom)
            let start = viewportTop + scrollTop
            let end = viewportTop + scrollBottom
            for _ in 0..<count {
                visibleCellCount -= lines[end].count
                lines.remove(at: end)
                lines.insert([], at: start)
            }
        }

        private func saveCursor() {
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol
        }

        private func restoreCursor() {
            cursorRow = max(0, savedCursorRow)
            cursorCol = max(0, savedCursorCol)
        }

        private func renderedOutput() -> StyledOutput {
            let attributed = NSMutableAttributedString()
            var plain = ""
            plain.reserveCapacity(
                visibleCellCount
                    + max(0, lines.count - 1)
                    + (droppedLineCount > 0 ? 48 : 0)
            )

            if droppedLineCount > 0 {
                let notice = "[Trimmed \(droppedLineCount) earlier output lines]\n"
                plain.append(notice)
                Ansi.appendAttributed(
                    notice,
                    style: TextStyle(),
                    to: attributed,
                    cache: &attributeCache
                )
            }

            for (rowIndex, line) in lines.enumerated() {
                Ansi.appendStyledCells(
                    line,
                    to: &plain,
                    attributed: attributed,
                    cache: &attributeCache
                )
                if rowIndex < lines.count - 1 {
                    plain.append("\n")
                    Ansi.appendAttributed(
                        "\n",
                        style: TextStyle(),
                        to: attributed,
                        cache: &attributeCache
                    )
                }
            }

            Ansi.linkifyURLs(in: attributed, baseDirectory: linkBaseDirectory)
            return StyledOutput(plainText: plain, attributedText: attributed)
        }

        private func trimScrollbackIfNeeded() {
            guard lines.count > Self.maxRenderedLines || visibleCellCount > Self.maxRenderedCells else {
                return
            }

            // ponytail: batch trim gives replay headroom; exact-at-cap trimming turns huge logs quadratic.
            let targetLines = Self.maxRenderedLines * 9 / 10
            let targetCells = Self.maxRenderedCells * 9 / 10
            var removeCount = 0
            var removedCells = 0
            while removeCount < lines.count - 1,
                  lines.count - removeCount > targetLines || visibleCellCount - removedCells > targetCells {
                removedCells += lines[removeCount].count
                removeCount += 1
            }
            if removeCount > 0 {
                lines.removeSubrange(0..<removeCount)
                visibleCellCount -= removedCells
                droppedLineCount += removeCount
                cursorRow = max(0, cursorRow - removeCount)
                savedCursorRow = max(0, savedCursorRow - removeCount)
                viewportTop = max(0, viewportTop - removeCount)
            }
        }

        private func parameter(_ parameters: [Int?], at index: Int, defaultValue: Int) -> Int {
            guard parameters.indices.contains(index),
                  let value = parameters[index],
                  value != 0
            else {
                return defaultValue
            }
            return value
        }
    }

    final class TerminalScreen {
        private var rows: Int
        private var cols: Int
        private var cells: [[Cell]]
        private var cursorRow = 0
        private var cursorCol = 0
        private var savedCursorRow = 0
        private var savedCursorCol = 0
        private var pending = ""
        private var isAlternateScreenActive = false
        private var isApplicationCursorModeActive = false
        private var wrapsAtRightMargin = true
        private var style = TextStyle()
        private var attributeCache: AttributeCache = [:]

        init(rows: Int, cols: Int) {
            self.rows = max(1, rows)
            self.cols = max(1, cols)
            self.cells = Array(
                repeating: Array(repeating: Cell(), count: self.cols),
                count: self.rows
            )
        }

        func resize(rows newRows: Int, cols newCols: Int) {
            let clampedRows = max(1, newRows)
            let clampedCols = max(1, newCols)
            guard clampedRows != rows || clampedCols != cols else { return }

            var resized = Array(
                repeating: Array(repeating: Cell(), count: clampedCols),
                count: clampedRows
            )
            for row in 0..<min(rows, clampedRows) {
                for col in 0..<min(cols, clampedCols) {
                    resized[row][col] = cells[row][col]
                }
            }
            rows = clampedRows
            cols = clampedCols
            cells = resized
            cursorRow = min(cursorRow, rows - 1)
            cursorCol = min(cursorCol, cols - 1)
            savedCursorRow = min(savedCursorRow, rows - 1)
            savedCursorCol = min(savedCursorCol, cols - 1)
        }

        func resetForCommand() {
            style = TextStyle()
            clear()
            cursorRow = 0
            cursorCol = 0
            savedCursorRow = 0
            savedCursorCol = 0
            pending.removeAll()
            isAlternateScreenActive = false
            isApplicationCursorModeActive = false
            wrapsAtRightMargin = true
            attributeCache.removeAll(keepingCapacity: true)
        }

        @discardableResult
        func process(_ text: String) -> TerminalScreenState {
            let scalars = Array((pending + text).unicodeScalars)
            pending.removeAll()

            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                switch scalar.value {
                case 0x1B:
                    guard processEscape(scalars, index: &index) else {
                        pending = String(String.UnicodeScalarView(scalars[index...]))
                        index = scalars.count
                        continue
                    }
                case 0x07:
                    index += 1
                case 0x08:
                    cursorCol = max(0, cursorCol - 1)
                    index += 1
                case 0x09:
                    cursorCol = min(cols - 1, cursorCol + (8 - cursorCol % 8))
                    index += 1
                case 0x0A, 0x0B, 0x0C:
                    lineFeed()
                    index += 1
                case 0x0D:
                    cursorCol = 0
                    index += 1
                case 0x00..<0x20, 0x7F:
                    index += 1
                default:
                    put(scalar)
                    index += 1
                }
            }

            return state
        }

        var state: TerminalScreenState {
            renderedState()
        }

        private func processEscape(_ scalars: [Unicode.Scalar], index: inout Int) -> Bool {
            guard index + 1 < scalars.count else { return false }
            let introducer = scalars[index + 1]

            if introducer == "[" {
                var cursor = index + 2
                while cursor < scalars.count {
                    let value = scalars[cursor].value
                    if value >= 0x40 && value <= 0x7E {
                        let body = scalars[(index + 2)..<cursor]
                        handleCSI(body: body, final: scalars[cursor])
                        index = cursor + 1
                        return true
                    }
                    cursor += 1
                }
                return false
            }

            if introducer == "]" {
                var cursor = index + 2
                while cursor < scalars.count {
                    if scalars[cursor].value == 0x07 {
                        index = cursor + 1
                        return true
                    }
                    if scalars[cursor].value == 0x1B {
                        guard cursor + 1 < scalars.count else { return false }
                        if scalars[cursor + 1] == "\\" {
                            index = cursor + 2
                            return true
                        }
                    }
                    cursor += 1
                }
                return false
            }

            if Ansi.isCharacterSetSelectionIntroducer(introducer) {
                guard index + 2 < scalars.count else { return false }
                index += 3
                return true
            }

            switch introducer {
            case "7":
                saveCursor()
            case "8":
                restoreCursor()
            case "D":
                lineFeed()
            case "E":
                cursorCol = 0
                lineFeed()
            case "M":
                reverseIndex()
            case "c":
                resetForCommand()
            default:
                break
            }
            index += 2
            return true
        }

        private func handleCSI<C: Collection>(
            body: C,
            final: Unicode.Scalar
        ) where C.Element == Unicode.Scalar {
            let privateMode = body.first == "?"

            if privateMode {
                let parameters = parseParameters(body.dropFirst())
                handlePrivateMode(parameters: parameters, final: final)
                return
            }

            switch final {
            case "A":
                cursorRow = max(0, cursorRow - firstParameter(body, defaultValue: 1))
            case "B":
                cursorRow = min(rows - 1, cursorRow + firstParameter(body, defaultValue: 1))
            case "C":
                cursorCol = min(cols - 1, cursorCol + firstParameter(body, defaultValue: 1))
            case "D":
                cursorCol = max(0, cursorCol - firstParameter(body, defaultValue: 1))
            case "E":
                cursorRow = min(rows - 1, cursorRow + firstParameter(body, defaultValue: 1))
                cursorCol = 0
            case "F":
                cursorRow = max(0, cursorRow - firstParameter(body, defaultValue: 1))
                cursorCol = 0
            case "G":
                cursorCol = clamp(firstParameter(body, defaultValue: 1) - 1, max: cols - 1)
            case "H", "f":
                let parameters = parseParameters(body)
                cursorRow = clamp(parameter(parameters, at: 0, defaultValue: 1) - 1, max: rows - 1)
                cursorCol = clamp(parameter(parameters, at: 1, defaultValue: 1) - 1, max: cols - 1)
            case "J":
                eraseDisplay(firstParameter(body, defaultValue: 0))
            case "K":
                eraseLine(firstParameter(body, defaultValue: 0))
            case "L":
                insertLines(firstParameter(body, defaultValue: 1))
            case "M":
                deleteLines(firstParameter(body, defaultValue: 1))
            case "P":
                deleteCharacters(firstParameter(body, defaultValue: 1))
            case "S":
                scrollUp(firstParameter(body, defaultValue: 1))
            case "T":
                scrollDown(firstParameter(body, defaultValue: 1))
            case "X":
                eraseCharacters(firstParameter(body, defaultValue: 1))
            case "@":
                insertCharacters(firstParameter(body, defaultValue: 1))
            case "d":
                cursorRow = clamp(firstParameter(body, defaultValue: 1) - 1, max: rows - 1)
            case "m":
                let parameters = parseParameters(body)
                style.applySGR(parameters)
            case "s":
                saveCursor()
            case "u":
                restoreCursor()
            default:
                break
            }
        }

        private func handlePrivateMode(parameters: [Int?], final: Unicode.Scalar) {
            for parameter in parameters {
                guard let parameter else { continue }
                switch parameter {
                case 1:
                    isApplicationCursorModeActive = final == "h"
                case 7:
                    wrapsAtRightMargin = final == "h"
                case 47, 1047, 1049:
                    isAlternateScreenActive = final == "h"
                    if final == "h" {
                        clear()
                        cursorRow = 0
                        cursorCol = 0
                    }
                default:
                    break
                }
            }
        }

        private func put(_ scalar: Unicode.Scalar) {
            cells[cursorRow][cursorCol] = Cell(scalar: scalar, style: style)
                if cursorCol == cols - 1 {
                if wrapsAtRightMargin {
                    cursorCol = 0
                    lineFeed()
                }
            } else {
                cursorCol += 1
            }
        }

        private func lineFeed() {
            if cursorRow == rows - 1 {
                scrollUp(1)
            } else {
                cursorRow += 1
            }
        }

        private func reverseIndex() {
            if cursorRow == 0 {
                scrollDown(1)
            } else {
                cursorRow -= 1
            }
        }

        private func clear() {
            cells = Array(
                repeating: Array(repeating: Cell(), count: cols),
                count: rows
            )
        }

        private func eraseDisplay(_ mode: Int) {
            switch mode {
            case 0:
                eraseLine(0)
                if cursorRow + 1 < rows {
                    for row in (cursorRow + 1)..<rows {
                        cells[row] = blankLine(style: style)
                    }
                }
            case 1:
                eraseLine(1)
                if cursorRow > 0 {
                    for row in 0..<cursorRow {
                        cells[row] = blankLine(style: style)
                    }
                }
            case 2, 3:
                cells = Array(
                    repeating: blankLine(style: style),
                    count: rows
                )
            default:
                break
            }
        }

        private func eraseLine(_ mode: Int) {
            switch mode {
            case 0:
                for col in cursorCol..<cols {
                    cells[cursorRow][col] = Cell(scalar: " ", style: style)
                }
            case 1:
                for col in 0...cursorCol {
                    cells[cursorRow][col] = Cell(scalar: " ", style: style)
                }
            case 2:
                cells[cursorRow] = blankLine(style: style)
            default:
                break
            }
        }

        private func eraseCharacters(_ count: Int) {
            guard count > 0 else { return }
            for col in cursorCol..<min(cols, cursorCol + count) {
                cells[cursorRow][col] = Cell(scalar: " ", style: style)
            }
        }

        private func insertCharacters(_ count: Int) {
            let count = min(max(0, count), cols - cursorCol)
            guard count > 0 else { return }
            var line = cells[cursorRow]
            for _ in 0..<count {
                line.insert(Cell(scalar: " ", style: style), at: cursorCol)
                _ = line.popLast()
            }
            cells[cursorRow] = line
        }

        private func deleteCharacters(_ count: Int) {
            let count = min(max(0, count), cols - cursorCol)
            guard count > 0 else { return }
            var line = cells[cursorRow]
            for _ in 0..<count {
                line.remove(at: cursorCol)
                line.append(Cell(scalar: " ", style: style))
            }
            cells[cursorRow] = line
        }

        private func insertLines(_ count: Int) {
            let count = min(max(0, count), rows - cursorRow)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.insert(blankLine(style: style), at: cursorRow)
                _ = cells.popLast()
            }
        }

        private func deleteLines(_ count: Int) {
            let count = min(max(0, count), rows - cursorRow)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.remove(at: cursorRow)
                cells.append(blankLine(style: style))
            }
        }

        private func scrollUp(_ count: Int) {
            let count = min(max(0, count), rows)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.removeFirst()
                cells.append(blankLine(style: style))
            }
        }

        private func scrollDown(_ count: Int) {
            let count = min(max(0, count), rows)
            guard count > 0 else { return }
            for _ in 0..<count {
                cells.removeLast()
                cells.insert(blankLine(style: style), at: 0)
            }
        }

        private func saveCursor() {
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol
        }

        private func restoreCursor() {
            cursorRow = min(savedCursorRow, rows - 1)
            cursorCol = min(savedCursorCol, cols - 1)
        }

        private func renderedState() -> TerminalScreenState {
            let rows = renderedRows()
            guard !rows.isEmpty else {
                return TerminalScreenState(
                    text: " ",
                    attributedText: Ansi.emptyAttributedOutput(),
                    isAlternateScreenActive: isAlternateScreenActive,
                    isApplicationCursorModeActive: isApplicationCursorModeActive
                )
            }

            let output = NSMutableAttributedString()
            var plain = ""
            let cellCount = rows.reduce(0) { $0 + $1.columnCount }
            plain.reserveCapacity(cellCount + max(0, rows.count - 1))

            for (index, row) in rows.enumerated() {
                if row.row == cursorRow {
                    var renderedCells = Array(cells[row.row][0..<row.columnCount])
                    renderedCells[cursorCol].style.isInverse.toggle()
                    Ansi.appendStyledCells(
                        renderedCells,
                        to: &plain,
                        attributed: output,
                        cache: &attributeCache
                    )
                } else {
                    Ansi.appendStyledCells(
                        cells[row.row][0..<row.columnCount],
                        to: &plain,
                        attributed: output,
                        cache: &attributeCache
                    )
                }
                if index < rows.count - 1 {
                    plain.append("\n")
                    Ansi.appendAttributed(
                        "\n",
                        style: TextStyle(),
                        to: output,
                        cache: &attributeCache
                    )
                }
            }

            Ansi.linkifyURLs(in: output)
            return TerminalScreenState(
                text: plain,
                attributedText: output,
                isAlternateScreenActive: isAlternateScreenActive,
                isApplicationCursorModeActive: isApplicationCursorModeActive
            )
        }

        private func renderedRows() -> [RenderedRow] {
            var rows = [RenderedRow]()
            rows.reserveCapacity(self.rows)

            for row in 0..<self.rows {
                rows.append(RenderedRow(row: row, columnCount: renderedColumnCount(in: cells[row], row: row)))
            }

            while rows.first?.columnCount == 0 {
                rows.removeFirst()
            }
            while rows.last?.columnCount == 0 {
                rows.removeLast()
            }
            return rows
        }

        private func renderedColumnCount(in row: [Cell], row rowIndex: Int) -> Int {
            var count = row.count
            while count > 0, row[count - 1].scalar == " " {
                count -= 1
            }
            return rowIndex == cursorRow ? max(count, cursorCol + 1) : count
        }

        private func blankLine(style: TextStyle = TextStyle()) -> [Cell] {
            Array(repeating: Cell(scalar: " ", style: style), count: cols)
        }

        private func parameter(_ parameters: [Int?], at index: Int, defaultValue: Int) -> Int {
            guard parameters.indices.contains(index),
                  let value = parameters[index],
                  value != 0
            else {
                return defaultValue
            }
            return value
        }

        private func clamp(_ value: Int, max maxValue: Int) -> Int {
            min(max(0, value), maxValue)
        }
    }

    static func alternateScreenSwitches(in text: String) -> [Bool] {
        var switches: [Bool] = []
        scanAlternateScreenSwitches(in: text) { _, isActive in
            switches.append(isActive)
            return true
        }
        return switches
    }

    static func alternateScreenSwitchRanges(in text: String) -> [AlternateScreenSwitch] {
        var switches: [AlternateScreenSwitch] = []
        scanAlternateScreenSwitches(in: text) { range, isActive in
            switches.append(AlternateScreenSwitch(range: range, isActive: isActive))
            return true
        }
        return switches
    }

    static func containsAlternateScreenSwitch(in text: String) -> Bool {
        var didFindSwitch = false
        scanAlternateScreenSwitches(in: text) { _, _ in
            didFindSwitch = true
            return false
        }
        return didFindSwitch
    }

    private static func scanAlternateScreenSwitches(
        in text: String,
        onSwitch: (Range<String.Index>, Bool) -> Bool
    ) {
        let bytes = text.utf8
        var index = bytes.startIndex

        while index < bytes.endIndex {
            guard bytes[index] == 0x1B,
                  let bracketIndex = bytes.index(index, offsetBy: 1, limitedBy: bytes.endIndex),
                  bracketIndex < bytes.endIndex,
                  bytes[bracketIndex] == 0x5B,
                  let bodyStart = bytes.index(index, offsetBy: 2, limitedBy: bytes.endIndex)
            else {
                bytes.formIndex(after: &index)
                continue
            }

            var cursor = bodyStart
            var parameters: [UInt8] = []
            var didFindFinal = false
            while cursor < bytes.endIndex {
                let byte = bytes[cursor]
                if byte >= 0x40 && byte <= 0x7E {
                    if byte == 0x68 || byte == 0x6C,
                       isAlternateScreenMode(parameters),
                       let start = String.Index(index, within: text) {
                        bytes.formIndex(after: &cursor)
                        if let end = String.Index(cursor, within: text),
                           !onSwitch(start..<end, byte == 0x68) {
                            return
                        }
                        index = cursor
                        didFindFinal = true
                        break
                    }
                    bytes.formIndex(after: &cursor)
                    index = cursor
                    didFindFinal = true
                    break
                }
                parameters.append(byte)
                bytes.formIndex(after: &cursor)
            }

            if !didFindFinal {
                break
            }
        }
    }

    static func visibleText(from text: String) -> String {
        StyledTextRenderer().process(text).plainText
    }

    static func runSelfTests() {
        assert(visibleText(from: "a\tb") == "a       b")

        let text = "http://one.test https://two.test/a. file:///tmp/x ftp://nope"
        let output = StyledTextRenderer().process(text).attributedText
        assert(linkScheme(in: output, text: text, needle: "http://one.test") == "http")
        assert(linkScheme(in: output, text: text, needle: "https://two.test/a") == "https")
        assert(linkScheme(in: output, text: text, needle: "file:///tmp/x") == "file")
        assert(linkScheme(in: output, text: text, needle: "ftp://nope") == nil)
        let punctuation = String(repeating: ".", count: 40) + "!"
        assert(StyledTextRenderer().process(punctuation).plainText == punctuation)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultty-ansi-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let file = tempDirectory.appendingPathComponent("Example.swift")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let image = tempDirectory.appendingPathComponent("Example.png")
        FileManager.default.createFile(atPath: image.path, contents: Data())
        let directory = tempDirectory.appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let pathText = "\(file.path):42 ./Example.swift:7 ./Sources/ Missing.swift:1"
        let pathOutput = StyledTextRenderer()
            .process(pathText, linkBaseDirectory: tempDirectory.path)
            .attributedText
        assert(fileLinkLine(in: pathOutput, text: pathText, needle: file.path) == 42)
        assert(fileLinkLine(in: pathOutput, text: pathText, needle: "./Example.swift") == 7)
        assert(fileLinkIsDirectory(in: pathOutput, text: pathText, needle: "./Sources/"))
        assert(fileLinkLine(in: pathOutput, text: pathText, needle: "Missing.swift") == nil)
        assert(FileLink(url: file, line: nil).isTextFile)
        assert(!FileLink(url: image, line: nil).isTextFile)

        let screen = TerminalScreen(rows: 2, cols: 4)
        let cursorOutput = screen.process("\u{1B}[?1049habc\u{1B}[D")
        assert(cursorOutput.text == "abc")
        assert(cursorOutput.attributedText.attribute(.backgroundColor, at: 2, effectiveRange: nil) != nil)

        let blankCursorOutput = TerminalScreen(rows: 2, cols: 4).process("\u{1B}[?1049h")
        assert(blankCursorOutput.text == " ")
        assert(blankCursorOutput.attributedText.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)

        let prompt = StyledTextRenderer()
        _ = prompt.process("\u{1B}7\u{1B}[?25l\u{1B}8\u{1B}[0G\u{1B}[2KQuestion?\r\n> One\r\n  Two\r\n\u{1B}7\u{1B}[1A\u{1B}[0G\u{1B}[1A\u{1B}[0G")
        let redrawnPrompt = prompt.process("\u{1B}8\u{1B}[0G\u{1B}[2K\u{1B}[1A\u{1B}[0G\u{1B}[2K\u{1B}[1A\u{1B}[0G\u{1B}[2K\u{1B}[1A\u{1B}[0G\u{1B}[2KQuestion?\r\n  One\r\n> Two\r\n\u{1B}7\u{1B}[1A\u{1B}[0G")
        assert(redrawnPrompt.plainText == "Question?\n  One\n> Two\n")

        let sizeProbe = StyledTextRenderer().process("output\u{1B}7\u{1B}[999;999f\u{1B}[6n")
        assert(sizeProbe.plainText == "output")
    }

    private static let linkDetector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static let clickableURLSchemes: Set<String> = ["file", "http", "https"]

    private static let pathDetector = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_./~-])((?:~|/|\./|\.\./)?(?:(?:[A-Za-z0-9_.$+@%-]+/)+[A-Za-z0-9_.$+@%-]+|(?:[A-Za-z0-9_$+@%-]+\.)+[A-Za-z][A-Za-z0-9_+-]{0,11})/?)(?::([0-9]+))?(?::[0-9]+)?"#
    )

    private static func linkifyURLs(
        in output: NSMutableAttributedString,
        baseDirectory: String? = nil
    ) {
        let range = NSRange(location: 0, length: output.length)
        linkDetector.enumerateMatches(in: output.string, range: range) { match, _, _ in
            guard let match,
                  let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  clickableURLSchemes.contains(scheme)
            else {
                return
            }
            output.addAttribute(.link, value: url, range: match.range)
        }
        linkifyFilePaths(in: output, baseDirectory: baseDirectory, range: range)
    }

    private static func linkifyFilePaths(
        in output: NSMutableAttributedString,
        baseDirectory: String?,
        range: NSRange
    ) {
        let text = output.string as NSString
        var links: [(range: NSRange, link: FileLink)] = []
        pathDetector.enumerateMatches(in: output.string, range: range) { match, _, _ in
            guard let match,
                  output.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                  let pathRange = Range(match.range(at: 1), in: output.string)
            else {
                return
            }

            let rawPath = trimmingTrailingPathPunctuation(String(output.string[pathRange]))
            guard let url = fileURL(for: rawPath, baseDirectory: baseDirectory) else { return }
            let line = lineNumber(in: text, from: match)
            let linkLength = rawPath.utf16.count
                + (line.map { String($0).utf16.count + 1 } ?? 0)
            links.append((
                range: NSRange(location: match.range.location, length: linkLength),
                link: FileLink(url: url, line: line)
            ))
        }
        for link in links {
            output.addAttribute(.link, value: link.link, range: link.range)
        }
    }

    private static let pathTrimCharacters = CharacterSet(charactersIn: ".,);]")

    private static func trimmingTrailingPathPunctuation(_ path: String) -> String {
        var path = path
        while let scalar = path.unicodeScalars.last,
              pathTrimCharacters.contains(scalar) {
            path.removeLast()
        }
        return path
    }

    private static func fileURL(for rawPath: String, baseDirectory: String?) -> URL? {
        guard !rawPath.isEmpty else { return nil }
        let expandedPath: String
        if rawPath == "~" || rawPath.hasPrefix("~/") {
            expandedPath = FileManager.default.homeDirectoryForCurrentUser.path
                + String(rawPath.dropFirst())
        } else if rawPath.hasPrefix("/") {
            expandedPath = rawPath
        } else if let baseDirectory {
            expandedPath = (baseDirectory as NSString).appendingPathComponent(rawPath)
        } else {
            expandedPath = rawPath
        }

        let path = (expandedPath as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
    }

    private static func lineNumber(in text: NSString, from match: NSTextCheckingResult) -> Int? {
        let range = match.range(at: 2)
        guard range.location != NSNotFound,
              let line = Int(text.substring(with: range)),
              line > 0
        else {
            return nil
        }
        return line
    }

    private static func linkScheme(
        in output: NSAttributedString,
        text: String,
        needle: String
    ) -> String? {
        let range = (text as NSString).range(of: needle)
        guard range.location != NSNotFound,
              let url = output.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        else {
            return nil
        }
        return url.scheme
    }

    private static func fileLinkLine(
        in output: NSAttributedString,
        text: String,
        needle: String
    ) -> Int? {
        let range = (text as NSString).range(of: needle)
        guard range.location != NSNotFound,
              let link = output.attribute(.link, at: range.location, effectiveRange: nil) as? FileLink
        else {
            return nil
        }
        return link.line
    }

    private static func fileLinkIsDirectory(
        in output: NSAttributedString,
        text: String,
        needle: String
    ) -> Bool {
        let range = (text as NSString).range(of: needle)
        guard range.location != NSNotFound,
              let link = output.attribute(.link, at: range.location, effectiveRange: nil) as? FileLink
        else {
            return false
        }
        return link.isDirectory
    }

    private static func isAlternateScreenMode(_ parameters: [UInt8]) -> Bool {
        guard parameters.first == 0x3F,
              let body = String(bytes: parameters.dropFirst(), encoding: .ascii)
        else {
            return false
        }
        return body.split(separator: ";").contains { mode in
            mode == "47" || mode == "1047" || mode == "1049"
        }
    }

    private static func isCharacterSetSelectionIntroducer(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x28...0x2F:
            return true
        default:
            return false
        }
    }

    private struct RenderedRow {
        let row: Int
        let columnCount: Int
    }

    private typealias AttributeCache = [TextStyle: [NSAttributedString.Key: Any]]

    private static func appendStyledCells<C: Collection>(
        _ cells: C,
        to plain: inout String,
        attributed: NSMutableAttributedString,
        cache: inout AttributeCache
    ) where C.Element == Cell {
        var currentStyle: TextStyle?
        var run = ""
        run.reserveCapacity(cells.underestimatedCount)

        for cell in cells {
            plain.unicodeScalars.append(cell.scalar)
            if currentStyle == nil {
                currentStyle = cell.style
            } else if currentStyle != cell.style {
                appendAttributed(
                    run,
                    style: currentStyle ?? TextStyle(),
                    to: attributed,
                    cache: &cache
                )
                run.removeAll(keepingCapacity: true)
                currentStyle = cell.style
            }
            run.unicodeScalars.append(cell.scalar)
        }

        if let currentStyle, !run.isEmpty {
            appendAttributed(
                run,
                style: currentStyle,
                to: attributed,
                cache: &cache
            )
        }
    }

    private static func appendAttributed(
        _ text: String,
        style: TextStyle,
        to output: NSMutableAttributedString,
        cache: inout AttributeCache
    ) {
        guard !text.isEmpty else { return }
        output.append(NSAttributedString(
            string: text,
            attributes: attributes(for: style, cache: &cache)
        ))
    }

    private static func attributes(
        for style: TextStyle,
        cache: inout AttributeCache
    ) -> [NSAttributedString.Key: Any] {
        if let attributes = cache[style] {
            return attributes
        }
        if cache.count > 512 {
            cache.removeAll(keepingCapacity: true)
        }
        let attributes = style.attributes()
        cache[style] = attributes
        return attributes
    }

    private struct Cell: Hashable {
        var scalar: Unicode.Scalar = " "
        var style = TextStyle()
    }

    private struct TextStyle: Hashable {
        var foreground: TerminalColor?
        var background: TerminalColor?
        var isBold = false
        var isDim = false
        var isItalic = false
        var isUnderlined = false
        var isStruckThrough = false
        var isInverse = false

        mutating func applySGR(_ parameters: [Int?]) {
            let parameters = parameters.isEmpty ? [0] : parameters
            var index = 0

            while index < parameters.count {
                let parameter = parameters[index] ?? 0
                switch parameter {
                case 0:
                    self = TextStyle()
                    index += 1
                case 1:
                    isBold = true
                    index += 1
                case 2:
                    isDim = true
                    index += 1
                case 3:
                    isItalic = true
                    index += 1
                case 4:
                    isUnderlined = true
                    index += 1
                case 7:
                    isInverse = true
                    index += 1
                case 9:
                    isStruckThrough = true
                    index += 1
                case 21, 22:
                    isBold = false
                    isDim = false
                    index += 1
                case 23:
                    isItalic = false
                    index += 1
                case 24:
                    isUnderlined = false
                    index += 1
                case 27:
                    isInverse = false
                    index += 1
                case 29:
                    isStruckThrough = false
                    index += 1
                case 30...37:
                    foreground = .palette(parameter - 30)
                    index += 1
                case 39:
                    foreground = nil
                    index += 1
                case 40...47:
                    background = .palette(parameter - 40)
                    index += 1
                case 49:
                    background = nil
                    index += 1
                case 90...97:
                    foreground = .palette(parameter - 90 + 8)
                    index += 1
                case 100...107:
                    background = .palette(parameter - 100 + 8)
                    index += 1
                case 38, 48:
                    index = applyExtendedColor(parameters, at: index)
                default:
                    index += 1
                }
            }
        }

        func attributes() -> [NSAttributedString.Key: Any] {
            var font = NSFont.monospacedSystemFont(ofSize: 12, weight: isBold ? .semibold : .regular)
            if isItalic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }

            var foregroundColor = foreground?.nsColor ?? .labelColor
            var backgroundColor = background?.nsColor

            if isDim {
                foregroundColor = foregroundColor.withAlphaComponent(0.62)
            }

            if isInverse {
                let originalForeground = foregroundColor
                foregroundColor = backgroundColor ?? .black
                backgroundColor = originalForeground
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foregroundColor
            ]
            if let backgroundColor {
                attributes[.backgroundColor] = backgroundColor
            }
            if isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if isStruckThrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return attributes
        }

        private mutating func applyExtendedColor(_ parameters: [Int?], at index: Int) -> Int {
            guard parameters.indices.contains(index + 1),
                  let mode = parameters[index + 1]
            else {
                return index + 1
            }

            let appliesToForeground = parameters[index] == 38
            switch mode {
            case 5:
                var cursor = index + 2
                while parameters.indices.contains(cursor) {
                    if let colorIndex = parameters[cursor] {
                        setColor(.palette(colorIndex), foreground: appliesToForeground)
                        return cursor + 1
                    }
                    cursor += 1
                }
                return index + 2
            case 2:
                var cursor = index + 2
                var components: [Int] = []
                while parameters.indices.contains(cursor), components.count < 3 {
                    if let component = parameters[cursor] {
                        components.append(min(max(0, component), 255))
                    }
                    cursor += 1
                }
                if components.count == 3 {
                    setColor(
                        .rgb(components[0], components[1], components[2]),
                        foreground: appliesToForeground
                    )
                    return cursor
                }
                return index + 2
            default:
                return index + 2
            }
        }

        private mutating func setColor(_ color: TerminalColor, foreground: Bool) {
            if foreground {
                self.foreground = color
            } else {
                self.background = color
            }
        }
    }

    private enum TerminalColor: Hashable {
        case palette(Int)
        case rgb(Int, Int, Int)

        var nsColor: NSColor {
            switch self {
            case .palette(let index):
                return Self.paletteColor(index)
            case .rgb(let red, let green, let blue):
                return Self.rgb(red, green, blue)
            }
        }

        private static func paletteColor(_ index: Int) -> NSColor {
            let clamped = min(max(0, index), 255)
            let base: [NSColor] = [
                rgb(0, 0, 0),
                rgb(205, 49, 49),
                rgb(13, 188, 121),
                rgb(229, 229, 16),
                rgb(36, 114, 200),
                rgb(188, 63, 188),
                rgb(17, 168, 205),
                rgb(229, 229, 229),
                rgb(102, 102, 102),
                rgb(241, 76, 76),
                rgb(35, 209, 139),
                rgb(245, 245, 67),
                rgb(59, 142, 234),
                rgb(214, 112, 214),
                rgb(41, 184, 219),
                rgb(255, 255, 255)
            ]

            if clamped < base.count {
                return base[clamped]
            }

            if clamped < 232 {
                let color = clamped - 16
                let levels = [0, 95, 135, 175, 215, 255]
                let red = levels[color / 36]
                let green = levels[(color / 6) % 6]
                let blue = levels[color % 6]
                return rgb(red, green, blue)
            }

            let level = 8 + (clamped - 232) * 10
            return rgb(level, level, level)
        }

        private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
            NSColor(
                calibratedRed: CGFloat(min(max(0, red), 255)) / 255,
                green: CGFloat(min(max(0, green), 255)) / 255,
                blue: CGFloat(min(max(0, blue), 255)) / 255,
                alpha: 1
            )
        }
    }

    private static func parseParameters<C: Collection>(_ body: C) -> [Int?] where C.Element == Unicode.Scalar {
        guard !body.isEmpty else { return [] }

        var parameters: [Int?] = []
        var value = 0
        var hasDigits = false
        var isValid = true

        func appendParameter() {
            parameters.append(hasDigits && isValid ? value : nil)
            value = 0
            hasDigits = false
            isValid = true
        }

        for scalar in body {
            switch scalar.value {
            case 0x30...0x39:
                value = value * 10 + Int(scalar.value - 0x30)
                hasDigits = true
            case 0x3A, 0x3B:
                appendParameter()
            default:
                isValid = false
            }
        }

        appendParameter()
        return parameters
    }

    private static func firstParameter<C: Collection>(
        _ body: C,
        defaultValue: Int
    ) -> Int where C.Element == Unicode.Scalar {
        var iterator = body.makeIterator()
        guard var scalar = iterator.next() else { return defaultValue }

        var value = 0
        var hasDigits = false

        while true {
            switch scalar.value {
            case 0x30...0x39:
                value = value * 10 + Int(scalar.value - 0x30)
                hasDigits = true
            case 0x3A, 0x3B:
                return hasDigits && value != 0 ? value : defaultValue
            default:
                return defaultValue
            }

            guard let next = iterator.next() else {
                break
            }
            scalar = next
        }

        return hasDigits && value != 0 ? value : defaultValue
    }
}
