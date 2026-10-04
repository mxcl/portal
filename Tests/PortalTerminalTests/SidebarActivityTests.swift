#if os(macOS)
import Foundation
import Testing
@testable import PortalTerminal

@Test("Terminal output pulses are coalesced per project without losing later activity")
@MainActor
func sidebarOutputPulses() {
    let workspace = TerminalWorkspace()
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    workspace.recordProjectOutput("busy", at: start)
    workspace.recordProjectOutput("busy", at: start.addingTimeInterval(0.05))
    #expect(workspace.projectOutputAt["busy"] == start)
    workspace.recordProjectOutput("other", at: start.addingTimeInterval(0.05))
    #expect(workspace.projectOutputAt["other"] == start.addingTimeInterval(0.05))
    workspace.recordProjectOutput("busy", at: start.addingTimeInterval(0.25))
    #expect(workspace.projectOutputAt["busy"] == start.addingTimeInterval(0.25))
    #expect(workspace.projectTerminalStates["busy"] == nil)
}
#endif
