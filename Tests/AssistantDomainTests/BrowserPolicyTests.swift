import AssistantBrowser
import Foundation
import XCTest

final class BrowserPolicyTests: XCTestCase {
    func testAllowsPublicNamesAndAddresses() throws {
        try assertAllowed([
            "https://example.com/article", "http://example.com", "HTTPS://EXAMPLE.COM/",
            "https://example.com./", "https://xn--bcher-kva.de/", "https://3com.com/",
            "https://172.2.example.com/", "https://10.example.com/", "https://127.example.com/",
            "https://192.168.example.com/", "https://localhost.example.com/",
            "https://notlocalhost.com/", "https://example.local.com/", "https://local.example/",
            "https://home.arpa.example/", "https://0xface.example/", "https://example.0xg/",
            "https://example.com:1/", "https://example.com:443/", "https://example.com:65535/",
            "https://example.com:00080/", "https://example.com/@user:pass?next=http://127.0.0.1#@host",
            "https://example.com/%2f%5c%00?q=%31%32%37.0.0.1",
            "http://1.1.1.1/", "https://8.8.8.8/", "https://8.8.8.8./",
            "http://9.255.255.255/", "http://11.0.0.0/", "http://126.255.255.255/", "http://128.0.0.0/",
            "http://172.15.255.255/", "http://172.32.0.0/", "http://172.2.1.1/",
            "http://172.200.1.1/", "http://172.255.255.255/",
            "http://192.167.255.255/", "http://192.169.0.0/",
            "http://169.253.255.255/", "http://169.255.0.0/",
            "http://100.63.255.255/", "http://100.128.0.0/", "http://223.255.255.255/",
            "https://[2606:4700:4700::1111]/", "http://[2001:4860:4860::8888]:8080/",
            "https://[2606:4700:4700:0000:0000:0000:0000:1111]/",
            "https://[::ffff:8.8.8.8]/", "https://[::FFFF:808:808]/",
            "https://[0:0:0:0:0:ffff:172.200.1.1]/"
        ])
    }

    func testIPv4AndMappedIPv6RangesHaveAccurateReasons() throws {
        let groups: [(String, [String])] = [
            ("Private-network addresses are disabled in the first release.", [
                "10.0.0.0", "10.255.255.255", "172.16.0.0", "172.31.255.255",
                "192.168.0.0", "192.168.255.255"
            ]),
            ("Loopback addresses are disabled in the first release.", ["127.0.0.0", "127.0.0.1", "127.255.255.255"]),
            ("Link-local addresses are disabled in the first release.", ["169.254.0.0", "169.254.169.254", "169.254.255.255"]),
            ("Unspecified addresses are not browsing destinations.", ["0.0.0.0"]),
            ("Shared-address-space destinations are disabled in the first release.", ["100.64.0.0", "100.127.255.255"]),
            ("Multicast addresses are not browsing destinations.", ["224.0.0.0", "239.255.255.255"]),
            ("Reserved IPv4 addresses are not browsing destinations.", ["0.0.0.1", "0.255.255.255", "240.0.0.0", "255.255.255.255"])
        ]
        for (reason, hosts) in groups {
            for host in hosts {
                // Exercise each IPv4 rule directly, with a root dot, and with
                // both dotted and hexadecimal IPv4-mapped IPv6 representations.
                let octets = host.split(separator: ".").map { UInt16($0)! }
                let high = String(octets[0] * 256 + octets[1], radix: 16)
                let low = String(octets[2] * 256 + octets[3], radix: 16)
                try assertBlocked([
                    "http://\(host)/", "https://\(host)./", "https://[::ffff:\(host)]/",
                    "https://[0:0:0:0:0:FFFF:\(high):\(low)]/"
                ], reason: reason)
            }
        }
    }

    func testEvery172SecondOctetUsesOnlyThePrivateCIDR() throws {
        for second in 0...255 {
            for address in ["https://172.\(second).1.1/", "https://[::ffff:172.\(second).1.1]/"] {
                if (16...31).contains(second) {
                    try assertBlocked([address], reason: "Private-network addresses are disabled in the first release.")
                } else {
                    try assertAllowed([address])
                }
            }
        }
    }

    func testIPv6RangesAndBoundaries() throws {
        let groups: [(String, [String])] = [
            ("Loopback addresses are disabled in the first release.", ["::1", "0:0:0:0:0:0:0:1", "0000::0001"]),
            ("Unspecified addresses are not browsing destinations.", ["::", "0:0:0:0:0:0:0:0"]),
            ("Private-network addresses are disabled in the first release.", [
                "fc00::", "FC00::1", "fd00::1", "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
                "fec0::", "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
            ]),
            ("Link-local addresses are disabled in the first release.", ["fe80::", "FE80::1", "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff"]),
            ("Multicast addresses are not browsing destinations.", ["ff00::", "ff02::1", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"]),
            ("Deprecated IPv4-compatible IPv6 addresses are not supported.", ["::127.0.0.1", "::7f00:1", "::8.8.8.8"])
        ]
        for (reason, hosts) in groups {
            try assertBlocked(hosts.map { "https://[\($0)]/" }, reason: reason)
        }
        // These neighbors are outside the denied prefixes. This is a URL-only
        // range test, not a claim that these addresses are globally routable.
        try assertAllowed([
            "https://[fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]/", "https://[fe00::1]/",
            "https://[fe7f:ffff:ffff:ffff:ffff:ffff:ffff:ffff]/"
        ])
    }

    func testLocalNamesAreCaseInsensitiveAndLabelBounded() throws {
        try assertBlocked([
            "http://localhost/", "http://LOCALHOST./", "http://sub.localhost/", "http://a.b.localhost./",
            "http://local/", "http://printer.local/", "http://PRINTER.LOCAL./",
            "http://home.arpa/", "http://router.home.arpa./"
        ], reason: "Local-only host names are disabled in the first release.")
    }

    func testRejectsCredentialsIncludingEmptyAndEncodedUserInfo() throws {
        try assertBlocked([
            "https://user@example.com/", "https://user:secret@example.com/", "https://@example.com/",
            "https://:secret@example.com/", "https://user:@example.com/", "https://:@example.com/",
            "https://user%40name:secret@example.com/", "https://user:secret@127.0.0.1/",
            "https://example.com@evil.example/"
        ], reason: "Web addresses containing user information or credentials are not allowed.")
    }

    func testRejectsNoncanonicalNumericHostsInsteadOfCallingThemPrivate() throws {
        try assertBlocked([
            "http://127.1/", "http://127.0.1/", "http://127/", "http://2130706433/",
            "http://4294967295/", "http://4294967296/", "http://999999999999999999999999/",
            "http://0177.0.0.1/", "http://0300.0250.0.1/", "http://001.002.003.004/",
            "http://0x7f000001/", "http://0X7F.0.0.1/", "http://0x7f.0x0.0x0.0x1/",
            "http://8.8.8/", "http://134744072/", "http://0x08080808/", "http://008.8.8.8/",
            "http://256.0.0.1/", "http://1.2.3.256/", "http://1.2.3.4.5/",
            "http://127.1./", "http://example.123/", "http://example.0xface/", "http://0x/"
        ], reason: "IPv4 addresses must use four decimal octets without leading zeros; other numeric host forms are not supported.")
    }

    func testRejectsEscapedHostsAndScopedIPv6() throws {
        try assertBlocked([
            "http://%31%32%37.0.0.1/", "http://%6cocalhost/", "http://example%2ecom/",
            "http://example.com%2f.evil/", "http://example.com%40evil/", "http://example.com%00/"
        ], reason: "Percent-encoded host names are not supported; use a plain host name or IDNA ASCII name.")
        try assertBlocked([
            "http://[fe80::1%25en0]/", "http://[fe80::1%251]/", "http://[2606:4700::1%25en0]/"
        ], reason: "IPv6 zone identifiers are not supported.")
    }

    func testRejectsUnsupportedSchemesAndMissingHosts() throws {
        try assertBlocked([
            "javascript:alert(1)", "data:text/plain,hello", "file:///etc/hosts", "ftp://example.com/file",
            "about:blank", "blob:https://example.com/id", "ws://example.com/", "//example.com/", "/relative"
        ], reason: "Only HTTP and HTTPS pages can open in the assistant browser.")
        try assertBlocked([
            "http://", "https:///example.com", "https:example.com", "https:/example.com"
        ], reason: "A web address needs a host name.")
    }

    func testDNSLabelLengthLimits() throws {
        let label = String(repeating: "a", count: 63)
        let longest = [label, label, label, String(repeating: "b", count: 61)].joined(separator: ".")
        try assertAllowed(["https://\(label).com/", "https://\(longest)/", "https://\(longest)./"])
        try assertBlocked([
            "https://\(label)a.com/", "https://\(longest)b/"
        ], reason: "The web address has an invalid host name.")
    }

    func testMalformedRawInputsAreRejectedBeforeLossyFoundationParsing() {
        // iOS 17 Foundation can erase invalid ports. The text-entry boundary
        // must reject the original input even when the parsed URL looks valid.
        let groups: [(String, [String])] = [
            ("The web address has an invalid host name.", [
                "https://example..com/", "https://.example.com/", "https://example.com../",
                "https://-example.com/", "https://example-.com/", "https://exam_ple.com/",
                "https://./", "https://1.2.3.-1/", "https://+2130706433/"
            ]),
            ("The web address has a malformed authority.", ["https://2001:4860::8888/", "https://example.com:80:90/"]),
            ("A web address port must be a decimal number between 1 and 65535.", [
                "https://example.com:/", "https://example.com:0/", "https://example.com:65536/",
                "https://example.com:-1/", "https://example.com:+80/", "https://example.com:abc/",
                "https://example.com:999999999999999999999999/", "https://[2606:4700::1111]:65536/"
            ]),
            ("The host must be a valid IPv6 address enclosed in brackets.", [
                "https://[::gg]/", "https://[1:2:3]/", "https://[1::2::3]/",
                "https://[1:2:3:4:5:6:7:8:9]/", "https://[12345::1]/", "https://[127.0.0.1]/",
                "https://[::ffff:127.1]/", "https://[::ffff:0177.0.0.1]/", "https://[v1.example]/"
            ])
        ]
        for (reason, addresses) in groups {
            for address in addresses {
                if let url = URL(string: address) {
                    XCTAssertEqual(BrowserPolicy.evaluate(address: address), .block(reason: reason), address)
                    if url.absoluteString == address {
                        XCTAssertEqual(BrowserPolicy.evaluate(url), .block(reason: reason), address)
                    }
                } else {
                    guard case .block = BrowserPolicy.evaluate(address: address) else {
                        XCTFail("Invalid raw address was accepted: \(address)"); continue
                    }
                }
            }
        }
    }

    func testRelativeURLsValidateTheResolvedDestination() throws {
        let publicBase = try XCTUnwrap(URL(string: "https://example.com/base/"))
        let allowed = try XCTUnwrap(URL(string: "../article", relativeTo: publicBase))
        XCTAssertEqual(BrowserPolicy.evaluate(allowed), .allow(allowed))
        for address in ["//127.0.0.1/path", "//[::1]/path"] {
            let url = try XCTUnwrap(URL(string: address, relativeTo: publicBase))
            XCTAssertEqual(BrowserPolicy.evaluate(url), .block(reason: "Loopback addresses are disabled in the first release."))
        }
        let privateBase = try XCTUnwrap(URL(string: "http://192.168.1.1/"))
        let privateRelative = try XCTUnwrap(URL(string: "page", relativeTo: privateBase))
        XCTAssertEqual(BrowserPolicy.evaluate(privateRelative), .block(reason: "Private-network addresses are disabled in the first release."))
    }

    private func assertAllowed(_ addresses: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        for address in addresses {
            let url = try XCTUnwrap(URL(string: address), address, file: file, line: line)
            XCTAssertEqual(BrowserPolicy.evaluate(url), .allow(url), address, file: file, line: line)
            XCTAssertEqual(BrowserPolicy.evaluate(address: address), .allow(url), address, file: file, line: line)
        }
    }

    private func assertBlocked(_ addresses: [String], reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for address in addresses {
            let url = try XCTUnwrap(URL(string: address), address, file: file, line: line)
            XCTAssertEqual(BrowserPolicy.evaluate(url), .block(reason: reason), address, file: file, line: line)
            XCTAssertEqual(BrowserPolicy.evaluate(address: address), .block(reason: reason), address, file: file, line: line)
        }
    }
}
