#if os(macOS)
import Foundation
import Testing
@testable import GitSyncEngine

@Test("GitHub refresh remains idle without a trigger and coalesces bursts with bounded retries")
func githubRefreshScheduling() {
    var schedule = GitHubRefreshSchedule()
    #expect(schedule.take() == nil)
    schedule.request(catchUp: true)
    schedule.request(catchUp: false)
    #expect(schedule.take() == true)
    #expect(schedule.take() == nil)
    for _ in 0..<3 {
        #expect(schedule.retry() == true)
        #expect(schedule.take() == false)
    }
    #expect(schedule.retry() == false)
    #expect(schedule.take() == nil)
    schedule.request(catchUp: false)
    #expect(schedule.take() == false)
    schedule.preserveCatchUp()
    #expect(schedule.retry() == true)
    #expect(schedule.take() == true)
}

@Test("GitHub responses preserve independent counts and restrict notification navigation")
func githubResponseDecoding() throws {
    let data = Data(#"{"counts":{"owner/repo":{"stars":12,"issues":3,"pullRequests":7}},"notifications":[{"id":"1:now","repository":"owner/repo","title":"Review","body":"body","url":"https://github.com/owner/repo/pull/1","alert":true},{"id":"bad","repository":"owner/repo","title":"Bad","body":"body","url":"file:///tmp/private","alert":true}],"authorizedRepositories":["owner/repo"],"fetches":[],"retryAfter":60,"errors":[],"installationURL":"https://github.com/apps/gitinuum/installations/new"}"#.utf8)
    let response = try JSONDecoder().decode(GitHubResponse.self, from: data)
    #expect(response.counts["owner/repo"]?.summary == "12 stars, 7 open pull requests, 3 open issues")
    #expect(response.notifications[0].safeURL != nil)
    #expect(response.notifications[1].safeURL == nil)
    #expect(response.retryAfter == 60)
    #expect(response.hasUnreadNotifications == nil) // Older relays do not report unread state.
    var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for unread in [true, false] {
        payload["hasUnreadNotifications"] = unread
        let updated = try JSONDecoder().decode(GitHubResponse.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(updated.hasUnreadNotifications == unread)
        var state = GitHubState()
        state.hasUnreadNotifications = updated.hasUnreadNotifications
        let restored = try JSONDecoder().decode(GitHubState.self, from: JSONEncoder().encode(state))
        #expect(restored.hasUnreadNotifications == unread)
    }
    #expect(try JSONDecoder().decode(GitHubState.self, from: JSONEncoder().encode(GitHubState())).hasUnreadNotifications == nil)
    #expect(EngineControlProtocol.version == 4)
}
@Test("GitHub sign-in control requests require no relay configuration")
func githubConnectAction() throws {
    let data = try JSONEncoder().encode(GitHubAction.connect)
    let decoded = try JSONDecoder().decode(GitHubAction.self, from: data)
    guard case .connect = decoded else {
        Issue.record("Expected a GitHub connect action")
        return
    }
    #expect(String(decoding: data, as: UTF8.self) == #"{"connect":{}}"#)
}
#endif
