import Foundation

/// Pass a configured host identity, never executable shell text, between the two apps.
public enum TerminalLaunchRequest {
    public static let newTabURL = URL(string: "portal-terminal://new-tab")!

    public static func url(hostID: String) -> URL {
        var components = URLComponents()
        components.scheme = "portal-terminal"
        components.host = "new-window"
        components.queryItems = [URLQueryItem(name: "host", value: hostID)]
        return components.url!
    }

    public static func hostID(from url: URL) -> String? {
        guard url.scheme == "portal-terminal", url.host == "new-window",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.queryItems?.first(where: { $0.name == "host" })?.value,
              !host.isEmpty else { return nil }
        return host
    }
}
