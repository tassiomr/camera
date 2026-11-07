import Foundation

/// A 3D LUT in the layout CIColorCube expects: RGBA Float32, red varying fastest.
struct CubeLUT: Sendable {
    enum ParseError: LocalizedError, Equatable {
        case missingSize, invalidSize(Int), wrongEntryCount(expected: Int, found: Int), invalidLine(String), only1DSupported
        var errorDescription: String? {
            switch self {
            case .missingSize: "Arquivo .cube sem LUT_3D_SIZE."
            case .invalidSize(let s): "Tamanho de LUT inválido: \(s)."
            case .wrongEntryCount(let e, let f): "Esperava \(e) entradas, encontrei \(f)."
            case .invalidLine(let l): "Linha inválida: \(l)"
            case .only1DSupported: "LUTs 1D não são suportadas; use uma LUT 3D."
            }
        }
    }

    var title: String
    var dimension: Int
    var data: Data

    static func parse(_ text: String, fallbackTitle: String = "LUT") throws -> CubeLUT {
        var size: Int?
        var title = fallbackTitle
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = parts.first else { continue }
            switch keyword {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            case "LUT_3D_SIZE":
                guard parts.count == 2, let s = Int(parts[1]) else { throw ParseError.invalidLine(line) }
                guard (2...256).contains(s) else { throw ParseError.invalidSize(s) }
                size = s
                values.reserveCapacity(s * s * s * 4)
            case "LUT_1D_SIZE":
                throw ParseError.only1DSupported
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap { Float($0) }
            case "LUT_3D_INPUT_RANGE":
                let r = parts.dropFirst().compactMap { Float($0) }
                if r.count == 2 { domainMin = [r[0], r[0], r[0]]; domainMax = [r[1], r[1], r[1]] }
            default:
                let nums = parts.compactMap { Float($0) }
                guard nums.count == 3 else {
                    if keyword.first?.isLetter == true { continue } // unknown keyword
                    throw ParseError.invalidLine(line)
                }
                values.append(contentsOf: nums)
                values.append(1)
            }
        }
        guard let n = size else { throw ParseError.missingSize }
        let expected = n * n * n
        guard values.count / 4 == expected else { throw ParseError.wrongEntryCount(expected: expected, found: values.count / 4) }
        _ = (domainMin, domainMax) // CIColorCube assumes a 0…1 domain; most camera LUTs use it.
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(title: title, dimension: n, data: data)
    }

    /// Builds a LUT from a per-pixel transform on 0…1 RGB.
    static func generate(title: String, dimension: Int, _ transform: (SIMD3<Double>) -> SIMD3<Double>) -> CubeLUT {
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        let scale = Double(dimension - 1)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let out = transform(SIMD3(Double(r) / scale, Double(g) / scale, Double(b) / scale))
                    values.append(Float(min(max(out.x, 0), 1)))
                    values.append(Float(min(max(out.y, 0), 1)))
                    values.append(Float(min(max(out.z, 0), 1)))
                    values.append(1)
                }
            }
        }
        return CubeLUT(title: title, dimension: dimension, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

/// Apple Log math from Apple's "Apple Log Profile" white paper.
enum AppleLogCurve {
    static let r0 = -0.05641088, rt = 0.01, c = 47.28711236, b = 0.00964052, gamma = 0.08550479, beta = 0.69336945
    static var pt: Double { c * (rt - r0) * (rt - r0) }

    static func encode(_ r: Double) -> Double {
        if r < r0 { return 0 }
        if r < rt { return c * (r - r0) * (r - r0) }
        return gamma * log2(r + b) + beta
    }

    static func decode(_ p: Double) -> Double {
        if p < 0 { return r0 }
        if p < pt { return (p / c).squareRoot() + r0 }
        return pow(2, (p - beta) / gamma) - b
    }
}

enum BuiltInLUT: String, CaseIterable, Identifiable {
    case appleLogTo709

    var id: String { "builtin.\(rawValue)" }
    var title: String { "Apple Log → Rec.709 (técnica)" }

    /// Technical display transform: Apple Log decode → BT.2020→BT.709 gamut →
    /// filmic shoulder → BT.709 OETF. An approximation for monitoring; for grading
    /// use Apple's official LUT imported as .cube.
    func make(dimension: Int = 33) -> CubeLUT {
        CubeLUT.generate(title: title, dimension: dimension) { rgb in
            let lin = SIMD3(AppleLogCurve.decode(rgb.x), AppleLogCurve.decode(rgb.y), AppleLogCurve.decode(rgb.z))
            let r = 1.6605 * lin.x - 0.5876 * lin.y - 0.0728 * lin.z
            let g = -0.1246 * lin.x + 1.1329 * lin.y - 0.0083 * lin.z
            let b = -0.0182 * lin.x - 0.1006 * lin.y + 1.1187 * lin.z
            func tone(_ x: Double) -> Double {
                let v = max(x, 0) * 0.8
                return (v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14)
            }
            func oetf(_ l: Double) -> Double { l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099 }
            return SIMD3(oetf(tone(r)), oetf(tone(g)), oetf(tone(b)))
        }
    }
}

/// Imported LUTs live in Application Support/LUTs. Nothing leaves the device.
final class LUTLibrary {
    struct Entry: Identifiable, Hashable { var id: String; var title: String; var url: URL? }

    let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LUTs")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func entries() -> [Entry] {
        let builtIn = BuiltInLUT.allCases.map { Entry(id: $0.id, title: $0.title, url: nil) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let imported = files.filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Entry(id: "file.\($0.lastPathComponent)", title: $0.deletingPathExtension().lastPathComponent, url: $0) }
        return builtIn + imported
    }

    func load(id: String) -> CubeLUT? {
        if let builtIn = BuiltInLUT.allCases.first(where: { $0.id == id }) { return builtIn.make() }
        guard id.hasPrefix("file.") else { return nil }
        let url = directory.appendingPathComponent(String(id.dropFirst(5)))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? CubeLUT.parse(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    /// Validates and copies an external .cube into the library.
    func importLUT(from source: URL) throws -> Entry {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: source, encoding: .utf8)
        _ = try CubeLUT.parse(text)
        let dest = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: source, to: dest)
        return Entry(id: "file.\(dest.lastPathComponent)", title: dest.deletingPathExtension().lastPathComponent, url: dest)
    }
}
