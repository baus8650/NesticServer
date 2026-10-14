import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// DB-IP Lite country data is bundled at build time. Visitor addresses never
/// leave this server and are not retained by the analytics database.
struct OfflineCountryLookup: Sendable {
    static let shared = OfflineCountryLookup()
    private let ipv4: Data?
    private let ipv6: Data?
    init(directory: String = "Resources") {
        ipv4 = try? Data(contentsOf: URL(fileURLWithPath: directory + "/geoip-country-v4.bin"), options: .mappedIfSafe)
        ipv6 = try? Data(contentsOf: URL(fileURLWithPath: directory + "/geoip-country-v6.bin"), options: .mappedIfSafe)
    }
    func country(for ip: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let is4 = bytes.withUnsafeMutableBytes { inet_pton(AF_INET, ip, $0.baseAddress) } == 1
        if !is4 && bytes.withUnsafeMutableBytes({ inet_pton(AF_INET6, ip, $0.baseAddress) }) != 1 { return nil }
        let mapped = !is4 && bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
        let width = is4 || mapped ? 4 : 16
        let address = is4 ? Array(bytes.prefix(4)) : mapped ? Array(bytes.suffix(4)) : bytes
        guard let data = width == 4 ? ipv4 : ipv6 else { return nil }
        let stride = width + 2
        guard data.count % stride == 0 else { return nil }
        var low = 0, high = data.count / stride
        while low < high {
            let mid = (low + high) / 2
            let end = data[(mid*stride)..<(mid*stride+width)]
            if end.lexicographicallyPrecedes(address) { low = mid + 1 } else { high = mid }
        }
        guard low < data.count / stride, let code = String(data: data[(low*stride+width)..<(low*stride+stride)], encoding:.ascii), code != "ZZ" else { return nil }
        return code
    }
}
