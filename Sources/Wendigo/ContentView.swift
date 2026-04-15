import SwiftUI

let kBuildVersion = 3

struct ContentView: View {
    @ObservedObject var sourceManager: SourceManager
    @State private var showTestConfig = false
    @State private var testLabel = "test"
    @State private var testPresetIndex = 1  // default 1080p
    @State private var testCustomW = "1920"
    @State private var testCustomH = "1080"
    @State private var testUseCustom = false

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

                    Section("Test Pattern") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("ID:")
                                    .frame(width: 30, alignment: .leading)
                                TextField("stream-id", text: $testLabel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 140)
                            }

                            if !testUseCustom {
                                Picker("Resolution", selection: $testPresetIndex) {
                                    ForEach(0..<TestSourceConfig.presets.count, id: \.self) { i in
                                        let p = TestSourceConfig.presets[i]
                                        Text("\(p.name) (\(p.width)x\(p.height))").tag(i)
                                    }
                                }
                                .pickerStyle(.menu)
                            } else {
                                HStack {
                                    TextField("W", text: $testCustomW)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                    Text("x")
                                    TextField("H", text: $testCustomH)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                }
                            }

                            HStack {
                                Toggle("Custom", isOn: $testUseCustom)
                                    .toggleStyle(.checkbox)
                                Spacer()
                                Button("Add") {
                                    let config: TestSourceConfig
                                    if testUseCustom {
                                        let w = Int(testCustomW) ?? 1920
                                        let h = Int(testCustomH) ?? 1080
                                        config = TestSourceConfig(width: max(64, w), height: max(64, h), label: testLabel)
                                    } else {
                                        let p = TestSourceConfig.presets[testPresetIndex]
                                        config = TestSourceConfig(width: p.width, height: p.height, label: testLabel)
                                    }
                                    sourceManager.addMapping(source: .test(config))
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if sourceManager.ndiSources.isEmpty && sourceManager.syphonSources.isEmpty {
                        Text("Searching for sources...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 280)

            // Streams + Preview panel
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Streams")
                        .font(.headline)
                    Spacer()
                    Text("ws://\(getLocalIP()):9000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bitrate")
                            .font(.caption)
                            .frame(width: 55, alignment: .leading)
                        Picker("", selection: $sourceManager.bitrateMbps) {
                            Text("5").tag(5)
                            Text("10").tag(10)
                            Text("20").tag(20)
                            Text("30").tag(30)
                            Text("50").tag(50)
                        }
                        .pickerStyle(.segmented)
                        Text("Mbps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Keyframe")
                            .font(.caption)
                            .frame(width: 55, alignment: .leading)
                        Picker("", selection: $sourceManager.keyframeInterval) {
                            Text("All").tag(1)
                            Text("1s").tag(60)
                            Text("2s").tag(120)
                            Text("5s").tag(300)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                List {
                    ForEach(sourceManager.mappings) { mapping in
                        let isPreview = sourceManager.previewMappingId == mapping.id
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle()
                                    .fill(mapping.isActive ? .green : .gray)
                                    .frame(width: 8, height: 8)
                                Text(mapping.source.name)
                                    .fontWeight(.medium)
                                Spacer()
                                Button(isPreview ? "Hide Preview" : "Preview") {
                                    if isPreview {
                                        sourceManager.previewMappingId = nil
                                        sourceManager.previewImage = nil
                                        sourceManager.previewResolution = ""
                                    } else {
                                        sourceManager.previewMappingId = mapping.id
                                    }
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(isPreview ? .orange : .accentColor)
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
                                Text("ID:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                StreamIdField(mapping: mapping, sourceManager: sourceManager)
                            }

                            HStack {
                                if !mapping.resolution.isEmpty {
                                    Text(mapping.resolution)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
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

                // Preview pane
                if sourceManager.previewMappingId != nil {
                    Divider()
                    VStack(spacing: 4) {
                        if let image = sourceManager.previewImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 300)
                                .background(Color.black)
                        } else {
                            Rectangle()
                                .fill(Color.black)
                                .frame(height: 200)
                                .overlay(
                                    Text("Waiting for frames...")
                                        .foregroundStyle(.secondary)
                                )
                        }
                        if !sourceManager.previewResolution.isEmpty {
                            Text(sourceManager.previewResolution)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 300)
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle("Wendigo (build \(kBuildVersion))")
        .onAppear {
            sourceManager.startDiscovery()
            try? sourceManager.server.start()
        }
    }
}

/// Editable stream ID that only commits on Enter or focus loss
private struct StreamIdField: View {
    let mapping: StreamMapping
    @ObservedObject var sourceManager: SourceManager
    @State private var draft: String = ""

    var body: some View {
        TextField("stream-id", text: $draft, onCommit: {
            sourceManager.updateStreamId(for: mapping, newId: draft)
        })
        .textFieldStyle(.roundedBorder)
        .font(.caption)
        .frame(maxWidth: 150)
        .onAppear { draft = mapping.streamId }
        .onChange(of: mapping.streamId) { _, newVal in draft = newVal }
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
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "localhost" }
    defer { freeifaddrs(ifaddr) }

    // Prefer common interfaces in order; pick the first IPv4 match
    let preferred = ["en0", "en1", "en2", "en3", "en4", "bridge0"]
    var candidates: [String: String] = [:]  // interface name -> IP

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: interface.ifa_name)
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                   &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
        let ip = String(cString: hostname)
        // Skip loopback
        if ip.hasPrefix("127.") { continue }
        candidates[name] = ip
    }

    for name in preferred {
        if let ip = candidates[name] { return ip }
    }
    // Fall back to any non-loopback IPv4 address
    return candidates.values.first ?? "localhost"
}
