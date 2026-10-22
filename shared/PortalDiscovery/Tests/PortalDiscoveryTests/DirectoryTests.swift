import Testing
import Foundation
@testable import PortalDiscovery

@Test func directorySeparatesIdentitiesAndRetainsOfflineHosts() throws {
    var first = DiscoveryHost(); first.name = "First"
    var second = DiscoveryHost(); second.name = "Second"
    let token = Data(repeating: 7, count: 32)
    let records = [HostRegistration(host: first, owner: "a", token: token),
                   HostRegistration(host: second, owner: "b", token: Data(repeating: 8, count: 32))]
    let restored = try HostDirectory.decode(records.map { try JSONEncoder().encode($0) })
    #expect(HostDirectory.select(restored, token: token) == [first])
    #expect(restored == records)
}

@Test func incompatibleAndCorruptRecordsFailVisibly() throws {
    let record = HostRegistration(host: DiscoveryHost(), owner: "a", token: Data(repeating: 0, count: 32))
    let data = try JSONEncoder().encode(record)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["version"] = 999
    let future = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DirectoryError.self) { try HostDirectory.decode([future]) }
    #expect(throws: (any Error).self) { try HostDirectory.decode([Data("broken".utf8)]) }
}

@Test func rootKeyIsNeverSerializedInHostRecord() throws {
    let token = Data(repeating: 42, count: 32)
    let record = HostRegistration(host: DiscoveryHost(), owner: "owner", token: token)
    let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    #expect(!json.contains(token.base64EncodedString()))
    #expect(record.identity == PortalIdentity.fingerprint(token))
}
