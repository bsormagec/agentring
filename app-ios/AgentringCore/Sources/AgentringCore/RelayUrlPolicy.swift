import Foundation

/// TLS is mandatory, except for plain-HTTP relays on a private network or localhost
/// (self-hosting on a LAN, local development, CI). Same rules as the Android app.
public enum RelayUrlPolicy {
    public static func check(_ url: String) throws {
        guard let (scheme, host) = schemeAndHost(url) else { throw CoreError("Invalid relay URL") }
        switch scheme {
        case "https":
            return
        case "http":
            guard isPrivateHost(host) else {
                throw CoreError("The relay must use https:// (http is only allowed on a local network)")
            }
        default:
            throw CoreError("The relay URL must start with https://")
        }
    }

    /// Same rule for the LiveKit URL the relay hands out on accept: it carries the
    /// call's join token, so it must be wss:// unless the server is on a private network.
    public static func checkLiveKit(_ url: String) throws {
        guard let (scheme, host) = schemeAndHost(url) else { throw CoreError("Invalid LiveKit URL") }
        switch scheme {
        case "wss", "https":
            return
        case "ws", "http":
            guard isPrivateHost(host) else {
                throw CoreError("LiveKit must use wss:// (ws is only allowed on a local network)")
            }
        default:
            throw CoreError("Invalid LiveKit URL scheme")
        }
    }

    /// localhost, `*.local`, `::1`, and the IPv4 ranges 10/8, 127/8, 192.168/16,
    /// 172.16/12 and 100.64/10 (CGNAT, e.g. Tailscale). Other IPv6 hosts are not private.
    public static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for p in parts {
            // Like Kotlin's toIntOrNull: optional sign, ASCII digits only.
            guard let n = Int(p), (0...255).contains(n) else { return false }
            octets.append(n)
        }
        let a = octets[0], b = octets[1]
        return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b))
            || (a == 100 && (64...127).contains(b))
    }

    /// Scheme and host of an absolute URL; nil when it has no host.
    static func schemeAndHost(_ url: String) -> (String, String)? {
        guard let c = URLComponents(string: url), let scheme = c.scheme, let host = c.host, !host.isEmpty else {
            return nil
        }
        return (scheme, host)
    }
}
