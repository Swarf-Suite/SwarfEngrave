// swarfengrave-cli: plan a .swarfengrave document and write its G-code, without the app.
//
//   swarfengrave-cli <file.swarfengrave> [--out DIR] [--png preview.png] [--simulate] [--machine ID]
//   swarfengrave-cli --demo out.swarfengrave

import CAMCore
import CoreGraphics
import EngraveCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let usage = """
    usage: swarfengrave-cli <file.swarfengrave> [--out DIR] [--png preview.png] [--simulate] [--machine ID]
           swarfengrave-cli --demo out.swarfengrave
    """

func demoDocument() -> EngraveDocument {
    var sheet = Sheet(name: "Demo", stock: Stock(width: 300, height: 200, thickness: 12, materialID: "plywood", colorHex: "#d8b98a"))
    var frame = DesignObject(name: "Outline", geometry: .rectangle(width: 280, height: 180, cornerRadius: 8),
                             transform: Transform2D(position: V2(150, 100)))
    frame.cut = CutSettings(type: .profile, depth: 12)
    frame.cut.through = true
    frame.cut.profileSide = .outside
    frame.cut.tabs.count = 6
    var pocket = DesignObject(name: "Pocket", geometry: .rectangle(width: 70, height: 50, cornerRadius: 6),
                              transform: Transform2D(position: V2(60, 140)))
    pocket.cut = CutSettings(type: .pocket, depth: 4)
    var line = DesignObject(name: "Line", geometry: .line(length: 100), transform: Transform2D(position: V2(150, 30)))
    line.cut = CutSettings(type: .engrave, depth: 1)
    var star = DesignObject(name: "Star", geometry: .star(points: 5, outerRadius: 35, innerRadius: 15),
                            transform: Transform2D(position: V2(220, 120)))
    star.cut = CutSettings(type: .vcarve, depth: 0)
    var text = DesignObject(name: "Swarf", geometry: .text(TextSpec(string: "Swarf", fontName: "Helvetica-Bold", size: 20)),
                            transform: Transform2D(position: V2(80, 70)))
    text.cut = CutSettings(type: .vcarve, depth: 0)
    sheet.objects = [frame, pocket, line, star, text]
    return EngraveDocument(sheets: [sheet])
}

func writePNG(_ g: Grid2D, thickness T: Double, to url: URL) throws {
    let W = g.width, H = g.height
    var px = [UInt8](repeating: 0, count: W * H)
    for y in 0..<H {
        for x in 0..<W {
            let v = max(0, min(1, Double(g[x, y]) / max(1e-9, T)))
            px[(H - 1 - y) * W + x] = UInt8((v * 255).rounded())  // image rows run top-down; stock Y runs up
        }
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData),
          let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "swarfengrave-cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"]) }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "swarfengrave-cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"]) }
}

func duration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%dh %02dm %02ds", t / 3600, t / 60 % 60, t % 60) : String(format: "%dm %02ds", t / 60, t % 60)
}

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
var input: String?
var outDir: String?
var pngPath: String?
var simulate = false
var machineID: String?
var demoPath: String?
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("\(a) needs a value\n\(usage)") }
        return args.removeFirst()
    }
    switch a {
    case "--out": outDir = value()
    case "--png": pngPath = value()
    case "--simulate": simulate = true
    case "--machine": machineID = value()
    case "--demo": demoPath = value()
    case "-h", "--help": print(usage); exit(0)
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)\n\(usage)") }
        input = a
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

if let demo = demoPath {
    do {
        try encoder.encode(demoDocument()).write(to: URL(fileURLWithPath: demo))
        print("wrote \(demo)")
    } catch { fail("cannot write \(demo): \(error.localizedDescription)") }
    if input == nil { exit(0) }
}

guard let input else { fail(usage) }
let inURL = URL(fileURLWithPath: input)
let doc: EngraveDocument
do { doc = try JSONDecoder().decode(EngraveDocument.self, from: Data(contentsOf: inURL)) } catch {
    fail("cannot read \(input): \(error.localizedDescription)")
}
let machine: MachineProfile = {
    guard let id = machineID else { return doc.machine }
    if let m = (EngraveDocument.machines + MachineProfile.builtIn).first(where: { $0.id == id }) { return m }
    fail("unknown machine \(id); known: \((EngraveDocument.machines + MachineProfile.builtIn).map(\.id).joined(separator: ", "))")
}()
let out = URL(fileURLWithPath: outDir ?? inURL.deletingLastPathComponent().path)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let baseName = inURL.deletingPathExtension().lastPathComponent

print("Machine: \(machine.name)")
var grand = 0.0
for (n, sheet) in doc.sheets.enumerated() {
    let t0 = Date()
    let plan = CutPlanner.plan(sheet: sheet, bits: doc.bits, machine: machine)
    let planMS = Date().timeIntervalSince(t0) * 1000
    print(String(format: "\nSheet %d: %@ (%.0f × %.0f × %.1f mm, %@), planned in %.0f ms", n + 1, sheet.name,
                 sheet.stock.width, sheet.stock.height, sheet.stock.thickness, sheet.stock.materialID, planMS))
    for w in plan.warnings { print("  \(w.severity == .error ? "error" : "warning"): \(w.message)") }
    for (tp, s) in zip(plan.toolpaths, plan.seconds) {
        print("  \(tp.name) — \(tp.tool.name): \(tp.moves.count) moves, \(duration(s))")
    }
    print("  Total time: \(duration(plan.totalSeconds))")
    grand += plan.totalSeconds
    let job = doc.sheets.count > 1 ? "\(baseName)_\(n + 1)" : baseName
    for f in GCodeExport.files(sheet: sheet, plan: plan, machine: machine, bits: doc.bits, jobName: job) {
        let url = out.appendingPathComponent(f.name)
        do { try f.content.write(to: url, atomically: true, encoding: .utf8) } catch { fail("cannot write \(url.path): \(error.localizedDescription)") }
        print("  wrote \(url.path)")
    }
    if let png = pngPath {
        let t1 = Date()
        let surface = simulate ? CarvePreview.simulate(sheet: sheet, toolpaths: plan.toolpaths)
            : CarvePreview.surface(sheet: sheet, bits: doc.bits)
        let ms = Date().timeIntervalSince(t1) * 1000
        var url = URL(fileURLWithPath: png)
        if doc.sheets.count > 1 { url = url.deletingPathExtension().appendingPathExtension("\(n + 1).png") }
        do { try writePNG(surface, thickness: sheet.stock.thickness, to: url) } catch { fail(error.localizedDescription) }
        print(String(format: "  wrote %@ (%@, %d × %d cells, %.0f ms)", url.path, simulate ? "simulated" : "preview", surface.width, surface.height, ms))
    }
}
if doc.sheets.count > 1 { print("\nAll sheets: \(duration(grand))") }
