import SwiftUI

struct ContentView: View {
    @ObservedObject var sourceManager: SourceManager

    var body: some View {
        HSplitView {
            // Sources panel
            VStack(alignment: .leading) {
                Text("Sources")
                    .font(.headline)
                    .padding(.horizontal)

                List {
                    if !sourceManager.ndiSources.isEmpty {
                        Section("NDI") {
                            ForEach(sourceManager.ndiSources) { source in
                                HStack {
                                    Text(cleanNDIName(source.name))
                                    Spacer()
                                    Button("+") {
                                        sourceManager.addMapping(source: .ndi(source))
                                    }
                                }
                            }
                        }
                    }

                    if !sourceManager.syphonSources.isEmpty {
                        Section("Syphon") {
                            ForEach(sourceManager.syphonSources) { source in
                                HStack {
                                    Text("\(source.appName) - \(source.name)")
                                    Spacer()
                                    Button("+") {
                                        sourceManager.addMapping(source: .syphon(source))
                                    }
                                }
                            }
                        }
                    }

                    if sourceManager.ndiSources.isEmpty && sourceManager.syphonSources.isEmpty {
                        Text("Searching for sources...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 250)

            // Streams panel
            VStack(alignment: .leading) {
                HStack {
                    Text("Streams")
                        .font(.headline)
                    Spacer()
                    Text("ws://\(getLocalIP()):9000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                List {
                    ForEach(sourceManager.mappings) { mapping in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle()
                                    .fill(mapping.isActive ? .green : .gray)
                                    .frame(width: 8, height: 8)
                                Text(mapping.source.name)
                                    .fontWeight(.medium)
                                Spacer()
                                Button("Remove") {
                                    sourceManager.removeMapping(mapping)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }

                            HStack {
                                Text("ws://\(getLocalIP()):9000")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("ID: \(mapping.streamId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("\(Int(mapping.fps)) fps")
                                    .font(.caption)
                                let clients = sourceManager.server.clientCounts[mapping.streamId] ?? 0
                                Text("\(clients) client\(clients == 1 ? "" : "s")")
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if sourceManager.mappings.isEmpty {
                        Text("Add a source to start streaming")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 300)
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            sourceManager.startDiscovery()
            try? sourceManager.server.start()
        }
    }
}

private func cleanNDIName(_ name: String) -> String {
    // NDI names are "MACHINE (Source)" — extract just the source part
    if let range = name.range(of: "(") {
        let inside = name[range.upperBound...]
        if let end = inside.range(of: ")") {
            return String(inside[..<end.lowerBound])
        }
    }
    return name
}

func getLocalIP() -> String {
    var address = "localhost"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let addrFamily = interface.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name == "en0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
                break
            }
        }
    }
    return address
}
