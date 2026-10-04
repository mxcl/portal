#if os(macOS)
import SwiftUI

struct ProjectCommands: Commands {
    @FocusedValue(\.paletteModel) private var model

    var body: some Commands {
        CommandMenu("Project") {
            Button("Archive…") { model?.archiveSelectedProject() }
                .disabled(model?.canArchiveSelectedProject != true)
        }
    }
}
#endif
