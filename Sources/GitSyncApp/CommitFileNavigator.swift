#if os(macOS)
import SwiftUI
import gitdiff

struct CommitFileNavigator: View {
    let files: [DiffFile]
    let visibleFiles: Set<UUID>
    let select: (UUID) -> Void

    private var currentFile: DiffFile? { files.first { visibleFiles.contains($0.id) } }

    var body: some View {
        Menu {
            ForEach(files) { file in
                Button { select(file.id) } label: {
                    if file.id == currentFile?.id {
                        Label(file.displayName, systemImage: "checkmark")
                    } else {
                        Text(file.displayName)
                    }
                }
            }
        } label: {
            // Keep the header compact even for commits touching hundreds of files.
            let marks = min(files.count, 5)
            let current = files.firstIndex { $0.id == currentFile?.id } ?? 0
            let selectedMark = current * marks / max(files.count, 1)
            Image(size: CGSize(width: 24, height: 24)) { context in
                for index in 0..<marks {
                    let selected = index == selectedMark
                    let width: CGFloat = selected ? 20 : 12
                    let rect = CGRect(x: 22 - width, y: CGFloat(index * 5) + CGFloat(26 - marks * 5) / 2,
                                      width: width, height: 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(selected ? .primary : .secondary))
                }
            }
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Jump to file")
        .accessibilityValue(currentFile?.displayName ?? "")
        .help(currentFile.map { "Jump to file — \($0.displayName)" } ?? "Jump to file")
    }

    static func isVisible(_ frame: CGRect, viewportHeight: CGFloat) -> Bool {
        viewportHeight > 0 && frame.maxY > 0 && frame.minY < viewportHeight
    }
}
#endif
