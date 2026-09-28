import Foundation
#if os(macOS)
import Darwin
#endif

/// Optional inventory metadata; older peers keep their generic computer icon.
public struct HostHardware: Codable, Equatable, Sendable {
    public let operatingSystem: String
    public let model: String?

    public init(operatingSystem: String, model: String? = nil) {
        self.operatingSystem = operatingSystem
        self.model = model
    }

    public static let current: HostHardware = {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return HostHardware(operatingSystem: "macOS")
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return HostHardware(operatingSystem: "macOS")
        }
        return HostHardware(operatingSystem: "macOS", model: String(cString: buffer))
        #else
        return HostHardware(operatingSystem: "Linux")
        #endif
    }()
}
