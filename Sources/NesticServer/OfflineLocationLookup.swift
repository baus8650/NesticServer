import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ApproximateUsageLocation: Decodable, Sendable {
    let country: String?
    let region: String?
    let city: String?
}
/// A name-only, offline index. No visitor address is retained or exported.
struct OfflineLocationLookup: Sendable {
    static let shared = OfflineLocationLookup()
    private let ipv4: Data?
    private let ipv6: Data?
    private let locations: [ApproximateUsageLocation]
    init(directory: String = "Resources") {
        ipv4 = try? Data(contentsOf:URL(fileURLWithPath:directory+"/geoip-city-v4.bin"),options:.mappedIfSafe)
        ipv6 = try? Data(contentsOf:URL(fileURLWithPath:directory+"/geoip-city-v6.bin"),options:.mappedIfSafe)
        locations = (try? JSONDecoder().decode([ApproximateUsageLocation].self,from:Data(contentsOf:URL(fileURLWithPath:directory+"/geoip-locations.json")))) ?? []
    }
    func location(for ip: String) -> ApproximateUsageLocation? {
        var bytes = [UInt8](repeating:0,count:16)
        let is4 = bytes.withUnsafeMutableBytes { inet_pton(AF_INET,ip,$0.baseAddress) } == 1
        if !is4 && bytes.withUnsafeMutableBytes({ inet_pton(AF_INET6,ip,$0.baseAddress) }) != 1 { return nil }
        let mapped = !is4 && bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
        let width = is4 || mapped ? 4 : 16
        let address = is4 ? Array(bytes.prefix(4)) : mapped ? Array(bytes.suffix(4)) : bytes
        guard let data = width == 4 ? ipv4 : ipv6 else { return nil }
        let stride = width + 4
        guard data.count % stride == 0 else { return nil }
        var low = 0, high = data.count / stride
        while low < high { let mid = (low+high)/2; if data[(mid*stride)..<(mid*stride+width)].lexicographicallyPrecedes(address) { low = mid+1 } else { high = mid } }
        guard low < data.count / stride else { return nil }
        let id = data[(low*stride+width)..<(low*stride+stride)].reduce(0) { ($0 << 8) | Int($1) }
        guard locations.indices.contains(id), locations[id].country != nil else { return nil }
        return locations[id]
    }
}
