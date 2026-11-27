// PDF reader: walks each page's content stream with CGPDFScanner and collects painted paths (m l c v y h re),
// applying cm matrices, q/Q and form XObjects. One layer per page, in mm (1 pt = 25.4/72 mm), Y up.

import CAMCore
import CoreGraphics
import Foundation

enum PDFImporter {
    static func parse(url: URL) throws -> ImportedArtwork {
        guard let doc = CGPDFDocument(url as CFURL) else { throw ImportError.unreadable("Couldn't open \(url.lastPathComponent) as a PDF.") }
        if doc.isEncrypted && !doc.isUnlocked { throw ImportError.unreadable("The PDF is password protected.") }
        var layers: [(name: String, path: Path2D)] = []
        var warnings: [String] = []
        let pageCount = doc.numberOfPages
        guard pageCount > 0 else { throw ImportError.unreadable("The PDF has no pages.") }
        for n in 1...pageCount {
            guard let page = doc.page(at: n) else { continue }
            let collector = PDFPathCollector()
            let box = page.getBoxRect(.mediaBox)
            let k = 25.4 / 72
            collector.ctm = CGAffineTransform(translationX: -box.origin.x, y: -box.origin.y)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
            collector.scan(CGPDFContentStreamCreateWithPage(page))
            if collector.sawText { warnings.append("Text on page \(n) of the PDF was skipped: convert text to outlines first.") }
            if collector.sawImage { warnings.append("Images on page \(n) of the PDF were skipped.") }
            let p = ImportGeometry.join(collector.out, tolerance: 0.01)
            if !p.isEmpty { layers.append((name: pageCount == 1 ? "Artwork" : "Page \(n)", path: p)) }
        }
        if layers.isEmpty { warnings.append("No vector paths were found in the PDF.") }
        return ImportedArtwork(layers: layers, warnings: warnings)
    }
}

final class PDFPathCollector {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var current = Path2D()
    var cur = CGPoint.zero  // current point, user space
    var subStart = CGPoint.zero
    var out = Path2D()
    var depth = 0
    var sawText = false
    var sawImage = false

    func p(_ x: CGFloat, _ y: CGFloat) -> V2 { ImportGeometry.apply(ctm, V2(Double(x), Double(y))) }

    func scan(_ cs: CGPDFContentStreamRef) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        PDFPathCollector.install(table)
        let scanner = CGPDFScannerCreate(cs, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    func paint(close: Bool) {
        if close { current.close() }
        current.subpaths.removeAll { $0.segments.isEmpty }
        out.append(current)
        current = Path2D()
    }

    static func me(_ info: UnsafeMutableRawPointer?) -> PDFPathCollector {
        Unmanaged<PDFPathCollector>.fromOpaque(info!).takeUnretainedValue()
    }

    static func pop(_ s: CGPDFScannerRef, _ n: Int) -> [CGFloat]? {
        var v = [CGFloat](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(s, &x) else { return nil }
            v[i] = x
        }
        return v
    }

    static func install(_ t: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(t, "q") { _, info in let c = PDFPathCollector.me(info); c.stack.append(c.ctm) }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in let c = PDFPathCollector.me(info); if let m = c.stack.popLast() { c.ctm = m } }
        CGPDFOperatorTableSetCallback(t, "cm") { s, info in
            let c = PDFPathCollector.me(info)
            guard let v = PDFPathCollector.pop(s, 6) else { return }
            c.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(c.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "m") { s, info in
            let c = PDFPathCollector.me(info)
            guard let v = PDFPathCollector.pop(s, 2) else { return }
            c.current.move(to: c.p(v[0], v[1]))
            c.cur = CGPoint(x: v[0], y: v[1]); c.subStart = c.cur
        }
        CGPDFOperatorTableSetCallback(t, "l") { s, info in
            let c = PDFPathCollector.me(info)
            guard let v = PDFPathCollector.pop(s, 2) else { return }
            c.current.line(to: c.p(v[0], v[1]))
            c.cur = CGPoint(x: v[0], y: v[1])
        }
        CGPDFOperatorTableSetCallback(t, "c") { s, info in
            let c = PDFPathCollector.me(info)
            guard let v = PDFPathCollector.pop(s, 6) else { return }
            c.current.cubic(to: c.p(v[4], v[5]), control1: c.p(v[0], v[1]), control2: c.p(v[2], v[3]))
            c.cur = CGPoint(x: v[4], y: v[5])
        }
        CGPDFOperatorTableSetCallback(t, "v") { s, info in
            let c = PDFPathCollector.me(info)
            guard let v = PDFPathCollector.pop(s, 4) else { return }
            c.current.cubic(to: c.p(v[2], v[3]), control1: c.p(c.cur.x, c.cur.y), control2: c.p(v[0], v[1]))
            c.cur = CGPoint(x: v[2], y: v[3])
        }
        CGPDFOperatorTableSetCallback(t, "y") { s, info in
            let c = PDFPathCollector.me(info)
            guard let v = PDFPathCollector.pop(s, 4) else { return }
            c.current.cubic(to: c.p(v[2], v[3]), control1: c.p(v[0], v[1]), control2: c.p(v[2], v[3]))
            c.cur = CGPoint(x: v[2], y: v[3])
        }
        CGPDFOperatorTableSetCallback(t, "h") { _, info in
            let c = PDFPathCollector.me(info)
            c.current.close()
            c.cur = c.subStart
        }
        CGPDFOperatorTableSetCallback(t, "re") { s, info in
            let c = PDFPathCollector.me(info)
            guard let v = PDFPathCollector.pop(s, 4) else { return }
            let (x, y, w, h) = (v[0], v[1], v[2], v[3])
            c.current.move(to: c.p(x, y))
            c.current.line(to: c.p(x + w, y))
            c.current.line(to: c.p(x + w, y + h))
            c.current.line(to: c.p(x, y + h))
            c.current.close()
            c.cur = CGPoint(x: x, y: y); c.subStart = c.cur
        }
        for op in ["S", "f", "F", "f*", "B", "B*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in PDFPathCollector.me(info).paint(close: false) }
        }
        for op in ["s", "b", "b*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in PDFPathCollector.me(info).paint(close: true) }
        }
        CGPDFOperatorTableSetCallback(t, "n") { _, info in PDFPathCollector.me(info).current = Path2D() }
        CGPDFOperatorTableSetCallback(t, "BT") { _, info in PDFPathCollector.me(info).sawText = true }
        CGPDFOperatorTableSetCallback(t, "BI") { _, info in PDFPathCollector.me(info).sawImage = true }
        CGPDFOperatorTableSetCallback(t, "Do") { s, info in
            let c = PDFPathCollector.me(info)
            var namePtr: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(s, &namePtr), let name = namePtr else { return }
            let cs = CGPDFScannerGetContentStream(s)
            guard let obj = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &stream), let st = stream, let dict = CGPDFStreamGetDictionary(st) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let sub = subtype else { return }
            let kind = String(cString: sub)
            if kind == "Image" { c.sawImage = true; return }
            guard kind == "Form", c.depth < 12 else { return }
            var matrix = CGAffineTransform.identity
            var arr: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let a = arr, CGPDFArrayGetCount(a) == 6 {
                var v = [CGFloat](repeating: 0, count: 6)
                for i in 0..<6 { var x: CGPDFReal = 0; _ = CGPDFArrayGetNumber(a, i, &x); v[i] = x }
                matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            }
            var res: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dict, "Resources", &res)
            let saved = c.ctm
            let savedPath = c.current
            c.ctm = matrix.concatenating(c.ctm)
            c.current = Path2D()
            c.depth += 1
            let form = CGPDFContentStreamCreateWithStream(st, res ?? CGPDFStreamGetDictionary(st)!, cs)
            c.scan(form)
            CGPDFContentStreamRelease(form)
            c.depth -= 1
            c.ctm = saved
            c.current = savedPath
        }
    }
}
