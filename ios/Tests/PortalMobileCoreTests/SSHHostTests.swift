import Testing
import Foundation
@testable import PortalMobileCore

@Test func privateVPNAddresses() {
    for address in ["100.64.0.1", "100.127.255.254", "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1", "fd7a:115c:a1e0::1"] {
        #expect(SSHHost.isPrivateAddress(address))
    }
    for address in ["100.63.255.255", "100.128.0.1", "172.15.0.1", "172.32.0.1", "8.8.8.8", "127.0.0.1", "169.254.1.1", "::1", "::ffff:8.8.8.8", "2001:4860:4860::8888", "example.com", "10.0.0.1;id", ""] {
        #expect(!SSHHost.isPrivateAddress(address))
    }
}

@Test func tokenIdentityIsStableAndDistinct() throws {
    let token = Data(repeating: 7, count: 32)
    #expect(try SSHIdentity.publicKey(token: token) == SSHIdentity.publicKey(token: token))
    #expect(try SSHIdentity.publicKey(token: token) != SSHIdentity.publicKey(token: Data(repeating: 8, count: 32)))
    var host = SSHHost()
    host.name = "Mac"; host.address = "100.64.0.1"; host.username = "max"; host.homeDirectory = "/Users/max"
    host.hostPublicKey = try SSHIdentity.publicKey(token: token)
    try host.validate()
    host.hostPublicKey = "invalid"
    #expect(throws: (any Error).self) { try host.validate() }
}

@Test func helperCommandQuotesShellMetacharacters() {
    #expect(SSHHost.quote("/a'b/$(id)") == "'/a'\\''b/$(id)'")
}
