import Foundation

enum LocalIPAddressProvider {
    static func ipv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfacePointer) == 0, let firstAddress = interfacePointer else {
            return []
        }
        defer {
            freeifaddrs(interfacePointer)
        }

        for sequence in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = sequence.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard name != "lo0" else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                continue
            }

            let address = host.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            addresses.append(address)
        }

        return Array(Set(addresses)).sorted()
    }
}
