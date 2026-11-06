import Foundation

/// Binds measured code to the app that release preflight inspects. Mach-O UUIDs
/// survive signing; test bundles and signatures are not part of the shipped code.
nonisolated struct BenchmarkArtifactIdentity: Encodable, Sendable {
    struct Image: Encodable, Sendable {
        let architecture: String
        let uuid: String
    }

    let schemaVersion = 1
    let bundleIdentifier: String
    let marketingVersion: String
    let buildNumber: String
    let mainExecutable: String
    let machoUUIDs: [String: [Image]]

    static func capture(bundle: Bundle = .main) throws -> Self {
        let root = bundle.bundleURL.resolvingSymlinksInPath()
        guard let bundleIdentifier = bundle.bundleIdentifier,
              let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let executable = bundle.executableURL?.resolvingSymlinksInPath(),
              executable.path.hasPrefix(root.path + "/") else {
            throw Failure.invalidBundle
        }
        guard let entries = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw Failure.invalidBundle
        }
        let signatures: [[UInt8]] = [
            [0xfe, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf],
            [0xce, 0xfa, 0xed, 0xfe], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]
        ]
        let magic = Set(signatures.map { Data($0) })
        var images: [String: [Image]] = [:]
        for case let url as URL in entries {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if relative.split(separator: "/").contains(where: {
                $0.hasSuffix(".xctest") || $0.hasSuffix(".dSYM") || $0 == "_CodeSignature" || $0 == ".git"
            }) {
                entries.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let file = try FileHandle(forReadingFrom: url)
            let header: Data
            do {
                header = try file.read(upToCount: 4) ?? Data()
                try file.close()
            } catch {
                try? file.close()
                throw error
            }
            guard magic.contains(header) else { continue }
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["dwarfdump", "--uuid", url.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else {
                throw Failure.missingUUID(relative)
            }
            let records = text.split(separator: "\n").compactMap { line -> Image? in
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 3, fields[0] == "UUID:",
                      let uuid = UUID(uuidString: String(fields[1])),
                      fields[2].first == "(", fields[2].last == ")" else { return nil }
                return Image(architecture: String(fields[2].dropFirst().dropLast()), uuid: uuid.uuidString)
            }.sorted { ($0.architecture, $0.uuid) < ($1.architecture, $1.uuid) }
            // UUID output alone can omit a fat slice without LC_UUID.
            let architecturePipe = Pipe()
            let architectureProcess = Process()
            architectureProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            architectureProcess.arguments = ["lipo", "-archs", url.path]
            architectureProcess.standardOutput = architecturePipe
            architectureProcess.standardError = FileHandle.nullDevice
            try architectureProcess.run()
            let architectureData = architecturePipe.fileHandleForReading.readDataToEndOfFile()
            architectureProcess.waitUntilExit()
            guard architectureProcess.terminationStatus == 0,
                  let architectureText = String(data: architectureData, encoding: .utf8) else {
                throw Failure.missingUUID(relative)
            }
            let architectures = architectureText.split(whereSeparator: \.isWhitespace).map(String.init)
            let uuidArchitectures = records.map(\.architecture)
            guard !records.isEmpty, !architectures.isEmpty,
                  Set(architectures).count == architectures.count,
                  Set(uuidArchitectures).count == uuidArchitectures.count,
                  Set(architectures) == Set(uuidArchitectures) else { throw Failure.missingUUID(relative) }
            images[relative] = records
        }
        let mainExecutable = String(executable.path.dropFirst(root.path.count + 1))
        guard images[mainExecutable] != nil else { throw Failure.missingUUID(mainExecutable) }
        return Self(bundleIdentifier: bundleIdentifier, marketingVersion: marketingVersion,
            buildNumber: buildNumber, mainExecutable: mainExecutable, machoUUIDs: images)
    }

    private enum Failure: Error {
        case invalidBundle
        case missingUUID(String)
    }
}

/// Evidence from the shipped Mach-O slices, independent of scheme/environment claims.
/// Captured outside every latency interval. Unknown or incomplete inspection throws.
nonisolated struct BenchmarkBuildInstrumentation: Encodable, Sendable {
    struct Binary: Encodable, Sendable {
        let path: String
        let architecture: String
        let llvmProfileSections: [String]
    }

    let schemaVersion = 1
    let method = "mach-o-llvm-profile-sections-v1"
    let binaries: [Binary]
    let llvmProfileInstrumented: Bool

    static func capture(identity: BenchmarkArtifactIdentity, bundle: Bundle = .main) throws -> Self {
        let root = bundle.bundleURL.resolvingSymlinksInPath()
        var binaries: [Binary] = []
        for path in identity.machoUUIDs.keys.sorted() {
            for slice in identity.machoUUIDs[path, default: []] {
                let pipe = Pipe()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["otool", "-arch", slice.architecture, "-h", "-l",
                    root.appendingPathComponent(path).path]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else {
                    throw Failure.incompleteInspection(path, slice.architecture)
                }
                let sections = try profileSections(text, architecture: slice.architecture, uuid: slice.uuid)
                binaries.append(Binary(path: path, architecture: slice.architecture, llvmProfileSections: sections))
            }
        }
        guard !binaries.isEmpty else { throw Failure.incompleteInspection("app", "all") }
        return Self(binaries: binaries, llvmProfileInstrumented: binaries.contains { !$0.llvmProfileSections.isEmpty })
    }

    private static func profileSections(_ output: String, architecture: String, uuid: String) throws -> [String] {
        // otool -arch can produce successful but empty output for an absent slice.
        // Check the numeric Mach header, UUID, command count and section count.
        let lines = output.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let headers = lines.indices.filter { lines[$0] == ["magic", "cputype", "cpusubtype", "caps", "filetype", "ncmds", "sizeofcmds", "flags"] }
        let cpu: [String: (Int, Int)] = [
            "arm64": (16777228, 0), "arm64e": (16777228, 2),
            "x86_64": (16777223, 3), "x86_64h": (16777223, 8),
            "i386": (7, 3), "armv7": (12, 9), "armv7s": (12, 11), "arm64_32": (33554444, 1)
        ]
        guard headers.count == 1, let headerIndex = headers.first, headerIndex + 1 < lines.count,
              let expectedCPU = cpu[architecture] else { throw Failure.incompleteInspection("header", architecture) }
        let header = lines[headerIndex + 1]
        guard header.count == 8, ["0xfeedface", "0xfeedfacf"].contains(header[0]),
              Int(header[1]) == expectedCPU.0, let subtype = Int(header[2]),
              subtype & 0x00ffffff == expectedCPU.1,
              let commandCount = Int(header[5]), commandCount > 0, commandCount <= lines.count else {
            throw Failure.incompleteInspection("architecture", architecture)
        }
        let commands = lines.filter { $0.first == "Load" && $0.count == 3 && $0[1] == "command" }
        let commandNumbers = commands.compactMap { Int($0[2]) }
        let commandKinds = lines.filter { $0.first == "cmd" && $0.count == 2 }
        let commandSizes = lines.filter { $0.first == "cmdsize" && $0.count == 2 }.compactMap { Int($0[1]) }
        let uuidLines = lines.filter { $0.first == "uuid" }
        let counts = lines.filter { $0.first == "nsects" }
        let sectionCounts = counts.compactMap { $0.count == 2 ? Int($0[1]) : nil }
        let sections = lines.filter { $0.first == "sectname" }
        guard commandNumbers == Array(0..<commandCount), commandKinds.count == commandCount,
              commandSizes.count == commandCount, commandSizes.allSatisfy({ $0 > 0 }),
              commandSizes.reduce(0, +) == Int(header[6]),
              uuidLines == [["uuid", uuid.uppercased()]],
              !counts.isEmpty, sectionCounts.count == counts.count, sectionCounts.allSatisfy({ $0 >= 0 }),
              sections.count == sectionCounts.reduce(0, +), !sections.isEmpty,
              sections.allSatisfy({ $0.count == 2 }),
              lines.filter({ $0 == ["Section"] }).count == sections.count else {
            throw Failure.incompleteInspection("load commands", architecture)
        }
        return Set(sections.map { $0[1] }.filter {
            $0.hasPrefix("__llvm_prf_") || $0.hasPrefix("__llvm_cov")
        }).sorted()
    }

    private enum Failure: Error {
        case incompleteInspection(String, String)
    }
}
