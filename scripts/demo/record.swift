import AppKit
import ScreenCaptureKit
import AVFoundation

final class Recording: NSObject, SCRecordingOutputDelegate {
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        print("RECORDING \(Date().timeIntervalSince1970)"); fflush(stdout)
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        fputs("Recording failed: \(error)\n", stderr); exit(1)
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { exit(0) }
}
let delegate = Recording()
Task { @MainActor in
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windows = content.windows.filter { ($0.owningApplication?.bundleIdentifier == "dev.mxcl.portal.film" && $0.windowLayer == 0 && $0.frame.width > 1000 && $0.frame.height > 500) || $0.title == "Portal Film Backdrop" }
        for window in windows { print("WINDOW \(window.windowID) \(window.title ?? "") \(window.frame)") }
        guard windows.count >= 2, let display = content.displays.first else { fatalError("Missing film windows") }
        let filter = SCContentFilter(display: display, including: windows)
        let config = SCStreamConfiguration()
        // shortcut: framing is calibrated for the 1512×982 shoot display. Recalibrate before filming on another display.
        config.width = 3024; config.height = 1700
        config.sourceRect = CGRect(x: 0, y: 66, width: 1512, height: 850)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        rc.outputFileType = .mov
        rc.videoCodecType = .h264
        let recording = SCRecordingOutput(configuration: rc, delegate: delegate)
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(Double(CommandLine.arguments[2])!))
        try await stream.stopCapture()
        try await Task.sleep(for: .seconds(1))
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
