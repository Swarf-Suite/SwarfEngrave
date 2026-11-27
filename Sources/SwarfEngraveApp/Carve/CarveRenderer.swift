// Metal renderer for the 3D carve view: the carved surface as a lit height field (a float texture, triangulated in
// the vertex shader), the stock's sides, toolpath lines and a tool marker. Adapted from SwarfPath's viewport renderer.

import CAMCore
import EngraveCore
import MetalKit
import simd

enum CarveMath {
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect, z = far / (near - far)
        return float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    static func orthographic(width: Float, height: Float, near: Float, far: Float) -> float4x4 {
        let z = 1 / (near - far)
        return float4x4(columns: (SIMD4(2 / width, 0, 0, 0), SIMD4(0, 2 / height, 0, 0), SIMD4(0, 0, z, 0), SIMD4(0, 0, z * near, 1)))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    static func rgb(hex: String) -> SIMD3<Float> {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return SIMD3(0.69, 0.48, 0.29) }
        return SIMD3(Float((v >> 16) & 0xff), Float((v >> 8) & 0xff), Float(v & 0xff)) / 255
    }
}

struct CarveCamera {
    var target = SIMD3<Float>(100, 50, 0)
    var yaw: Float = -0.6
    var pitch: Float = 0.6
    var distance: Float = 300
    var ortho = false
    var fovY: Float = 0.6

    var eye: SIMD3<Float> { target + distance * SIMD3(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch)) }

    func view() -> float4x4 {
        let up: SIMD3<Float> = abs(pitch) > 1.5699 ? SIMD3(-sin(yaw), cos(yaw), 0) : SIMD3(0, 0, 1)
        return CarveMath.lookAt(eye: eye, target: target, up: up)
    }

    func projection(aspect: Float) -> float4x4 {
        if ortho {
            let h = 2 * distance * tan(fovY / 2)
            return CarveMath.orthographic(width: h * aspect, height: h, near: -distance * 50, far: distance * 50)
        }
        return CarveMath.perspective(fovY: fovY, aspect: aspect, near: max(0.1, distance * 0.01), far: distance * 50)
    }

    /// Fit a stock of this size in view (keeps the angles).
    mutating func frame(_ size: V3, aspect: Float) {
        target = SIMD3(Float(size.x / 2), Float(size.y / 2), Float(size.z / 2))
        let w = Float(max(10, size.x)), h = Float(max(10, size.y))
        // Fit the larger of the width (scaled by aspect) and the depth, with a margin.
        let r = max(w / max(0.3, aspect), h) * 0.5 * 1.25
        distance = r / tan(fovY / 2)
    }
}

enum CarveViewPreset: String, CaseIterable, Identifiable {
    case top = "Top", front = "Front", iso = "Iso"
    var id: String { rawValue }
}

private struct CarveMeshVertex {
    var pos: SIMD3<Float>
    var nrm: SIMD3<Float>
    var color: SIMD4<Float>
}

private struct CarveLineVertex {
    var pos: SIMD3<Float>
    var color: SIMD4<Float>
}

private struct CarveUniforms {
    var viewProj: float4x4
    var lightDir: SIMD4<Float>
    var eye: SIMD4<Float>
    var grid: SIMD4<Float>  // originX, originY, res, stock top
    var gridSize: SIMD4<UInt32>  // W, H, grain, 0
    var wood: SIMD4<Float>
}

@MainActor
final class CarveRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var camera = CarveCamera()
    var showToolpaths = false

    private var heightPipe: MTLRenderPipelineState!
    private var meshPipe: MTLRenderPipelineState!
    private var linePipe: MTLRenderPipelineState!
    private var bgPipe: MTLRenderPipelineState!
    private var depthOn: MTLDepthStencilState!
    private var depthRead: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!

    private var heightTex: MTLTexture?
    private var grid = SIMD4<Float>(0, 0, 1, 0)
    private var gridSize = SIMD4<UInt32>(0, 0, 0, 0)
    private var wood = SIMD4<Float>(0.69, 0.48, 0.29, 1)
    private var skirtBuf: MTLBuffer?, skirtCount = 0
    private var bedBuf: MTLBuffer?, bedCount = 0
    private var pathBuf: MTLBuffer?, pathCount = 0
    private var markerBuf: MTLBuffer?, markerCount = 0

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        super.init()
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColorMake(0.07, 0.07, 0.07, 1)
        do { try buildPipelines(view) } catch { NSLog("SwarfEngrave: carve pipeline error \(error)"); return nil }
    }

    private func buildPipelines(_ view: MTKView) throws {
        let lib = try device.makeLibrary(source: CarveShaders.source, options: nil)
        func pipe(_ v: String, _ f: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        heightPipe = try pipe("ce_height_vs", "ce_surface_fs", blend: false)
        meshPipe = try pipe("ce_mesh_vs", "ce_surface_fs", blend: false)
        linePipe = try pipe("ce_line_vs", "ce_line_fs", blend: true)
        bgPipe = try pipe("ce_bg_vs", "ce_bg_fs", blend: false)
        func ds(_ write: Bool, _ cmp: MTLCompareFunction) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = write
            d.depthCompareFunction = cmp
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthOn = ds(true, .lessEqual)
        depthRead = ds(false, .lessEqual)
        depthOff = ds(false, .always)
    }

    private func buffer<T>(_ a: [T]) -> MTLBuffer? {
        guard !a.isEmpty else { return nil }
        return a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    // MARK: Scene

    /// Most cells drawn; larger surfaces are reduced by taking the lowest point of each block (so narrow cuts survive).
    static let maxCells = 2_100_000

    static func decimated(_ g: Grid2D) -> Grid2D {
        let n = g.width * g.height
        guard n > 3_000_000 else { return g }
        let k = Int((Double(n) / Double(maxCells)).squareRoot().rounded(.up))
        let W = (g.width + k - 1) / k, H = (g.height + k - 1) / k
        var out = Grid2D(origin: g.origin, res: g.res * Double(k), width: W, height: H, fill: 0)
        g.data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                for by in 0..<H {
                    let y0 = by * k, y1 = min(g.height, y0 + k)
                    for bx in 0..<W {
                        let x0 = bx * k, x1 = min(g.width, x0 + k)
                        var m = Float.greatestFiniteMagnitude
                        for y in y0..<y1 { for x in x0..<x1 { m = min(m, src[y * g.width + x]) } }
                        dst[by * W + bx] = m
                    }
                }
            }
        }
        return out
    }

    func setSurface(_ g0: Grid2D?, stock: Stock) {
        wood = SIMD4(CarveMath.rgb(hex: stock.colorHex), 1)
        let top = Float(stock.thickness)
        guard let g1 = g0, g1.width > 1, g1.height > 1, g1.data.count == g1.width * g1.height else {
            // No surface yet: a flat block.
            var flat = Grid2D(covering: .zero, V2(stock.width, stock.height), res: max(stock.width, stock.height) / 64, fill: top)
            flat.data = flat.data.map { _ in top }
            setGrid(flat, stock: stock)
            return
        }
        setGrid(Self.decimated(g1), stock: stock)
    }

    private func setGrid(_ g: Grid2D, stock: Stock) {
        let W = g.width, H = g.height
        if heightTex == nil || heightTex!.width != W || heightTex!.height != H {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: W, height: H, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            heightTex = device.makeTexture(descriptor: d)
        }
        g.data.withUnsafeBytes { heightTex?.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: W * 4) }
        grid = SIMD4(Float(g.origin.x), Float(g.origin.y), Float(g.res), Float(stock.thickness))
        gridSize = SIMD4(UInt32(W), UInt32(H), stock.showGrain ? 1 : 0, 0)
        buildSkirt(g, stock: stock)
    }

    /// The stock's four sides, following the surface height along each edge (so edge cuts show as notches).
    private func buildSkirt(_ g: Grid2D, stock: Stock) {
        let side = SIMD4<Float>(wood.x * 0.82, wood.y * 0.82, wood.z * 0.82, 1)
        var v: [CarveMeshVertex] = []
        let W = g.width, H = g.height, res = Float(g.res), ox = Float(g.origin.x), oy = Float(g.origin.y)
        func h(_ x: Int, _ y: Int) -> Float { max(0, min(Float(stock.thickness), g.data[y * W + x])) }
        func strip(_ count: Int, _ pt: (Int) -> (SIMD2<Float>, Float), _ n: SIMD3<Float>, flip: Bool) {
            guard count > 1 else { return }
            for i in 0..<(count - 1) {
                let (a, ha) = pt(i), (b, hb) = pt(i + 1)
                let a0 = SIMD3(a.x, a.y, 0), a1 = SIMD3(a.x, a.y, ha), b0 = SIMD3(b.x, b.y, 0), b1 = SIMD3(b.x, b.y, hb)
                let quad = flip ? [a0, b1, b0, a0, a1, b1] : [a0, b0, b1, a0, b1, a1]
                for p in quad { v.append(CarveMeshVertex(pos: p, nrm: n, color: side)) }
            }
        }
        strip(W, { (SIMD2(ox + Float($0) * res, oy), h($0, 0)) }, SIMD3(0, -1, 0), flip: false)
        strip(W, { (SIMD2(ox + Float($0) * res, oy + Float(H - 1) * res), h($0, H - 1)) }, SIMD3(0, 1, 0), flip: true)
        strip(H, { (SIMD2(ox, oy + Float($0) * res), h(0, $0)) }, SIMD3(-1, 0, 0), flip: true)
        strip(H, { (SIMD2(ox + Float(W - 1) * res, oy + Float($0) * res), h(W - 1, $0)) }, SIMD3(1, 0, 0), flip: false)
        skirtBuf = buffer(v); skirtCount = v.count
    }

    func setBed(stock: Stock, workZero: V3) {
        var l: [CarveLineVertex] = []
        let x = Float(stock.width), y = Float(stock.height)
        let gc = SIMD4<Float>(1, 1, 1, 0.05)
        let pad: Float = max(20, min(x, y) * 0.2)
        let step: Float = max(x, y) > 600 ? 50 : 10
        var gx = ((-pad) / step).rounded(.down) * step
        while gx <= x + pad { l.append(CarveLineVertex(pos: SIMD3(gx, -pad, -0.05), color: gc)); l.append(CarveLineVertex(pos: SIMD3(gx, y + pad, -0.05), color: gc)); gx += step }
        var gy = ((-pad) / step).rounded(.down) * step
        while gy <= y + pad { l.append(CarveLineVertex(pos: SIMD3(-pad, gy, -0.05), color: gc)); l.append(CarveLineVertex(pos: SIMD3(x + pad, gy, -0.05), color: gc)); gy += step }
        // Work zero axes
        let p = SIMD3<Float>(Float(workZero.x), Float(workZero.y), Float(workZero.z) + 0.05)
        let L = max(8, min(x, y) * 0.12)
        let axes: [(SIMD3<Float>, SIMD4<Float>)] = [
            (SIMD3(1, 0, 0), SIMD4(0.85, 0.42, 0.42, 1)), (SIMD3(0, 1, 0), SIMD4(0.5, 0.75, 0.42, 1)), (SIMD3(0, 0, 1), SIMD4(0.42, 0.62, 0.85, 1)),
        ]
        for (d, c) in axes { l.append(CarveLineVertex(pos: p, color: c)); l.append(CarveLineVertex(pos: p + d * L, color: c)) }
        bedBuf = buffer(l); bedCount = l.count
    }

    func setToolpaths(_ tps: [Toolpath]) {
        var v: [CarveLineVertex] = []
        let cut = SIMD4<Float>(0.486, 0.769, 0.651, 0.95)
        let rapid = SIMD4<Float>(0.56, 0.56, 0.56, 0.7)
        let dash: Double = 2.5, gap: Double = 2
        for tp in tps {
            let pts = tp.tessellated(maxSegment: 1)
            guard pts.count > 1 else { continue }
            for i in 1..<pts.count {
                let a = pts[i - 1].0, (b, kind) = pts[i]
                if kind == .rapid {
                    let len = simd_distance(a, b)
                    guard len > 1e-6 else { continue }
                    var s = 0.0
                    while s < len {
                        let e = min(len, s + dash)
                        let p = a + (b - a) * (s / len), q = a + (b - a) * (e / len)
                        v.append(CarveLineVertex(pos: SIMD3<Float>(p), color: rapid))
                        v.append(CarveLineVertex(pos: SIMD3<Float>(q), color: rapid))
                        s = e + gap
                    }
                } else {
                    v.append(CarveLineVertex(pos: SIMD3<Float>(a), color: cut))
                    v.append(CarveLineVertex(pos: SIMD3<Float>(b), color: cut))
                }
            }
        }
        pathBuf = buffer(v); pathCount = v.count
    }

    /// A wireframe bit at the tool tip during playback.
    func setToolMarker(_ p: V3?, tool: Tool?) {
        guard let p, let tool else { markerBuf = nil; markerCount = 0; return }
        var l: [CarveLineVertex] = []
        let c = SIMD4<Float>(0.88, 0.88, 0.88, 1)
        let r = Float(max(0.3, tool.radius)), base = SIMD3<Float>(p)
        let h = Float(max(tool.fluteLength, 10))
        let vee = tool.kind == .vBit
        let tipR: Float = vee ? 0 : r
        let coneH: Float = vee ? r / Float(max(0.1, tan(tool.vAngle * .pi / 360))) : 0
        let n = 24
        for i in 0..<n {
            let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
            let rings: [(Float, Float)] = vee ? [(coneH, r), (h, r)] : [(Float(0), tipR), (h, r)]
            for (z, rr) in rings {
                l.append(CarveLineVertex(pos: base + SIMD3(rr * cos(a0), rr * sin(a0), z), color: c))
                l.append(CarveLineVertex(pos: base + SIMD3(rr * cos(a1), rr * sin(a1), z), color: c))
            }
            if i % 6 == 0 {
                l.append(CarveLineVertex(pos: base + SIMD3((vee ? 0 : r) * cos(a0), (vee ? 0 : r) * sin(a0), 0), color: c))
                l.append(CarveLineVertex(pos: base + SIMD3(r * cos(a0), r * sin(a0), vee ? coneH : 0), color: c))
                l.append(CarveLineVertex(pos: base + SIMD3(r * cos(a0), r * sin(a0), vee ? coneH : 0), color: c))
                l.append(CarveLineVertex(pos: base + SIMD3(r * cos(a0), r * sin(a0), h), color: c))
            }
        }
        markerBuf = buffer(l); markerCount = l.count
    }

    // MARK: Draw

    private var drawableSize = CGSize(width: 1, height: 1)
    var aspect: Float { Float(drawableSize.width / max(1, drawableSize.height)) }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { drawableSize = size }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        drawableSize = view.drawableSize
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let eye = camera.eye
        let light = simd_normalize(SIMD3<Float>(-0.35, -0.55, 1) + simd_normalize(eye - camera.target) * 0.35)
        var u = CarveUniforms(viewProj: camera.projection(aspect: aspect) * camera.view(), lightDir: SIMD4(light, 0),
                              eye: SIMD4(eye, 1), grid: grid, gridSize: gridSize, wood: wood)
        enc.setRenderPipelineState(bgPipe)
        enc.setDepthStencilState(depthOff)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setVertexBytes(&u, length: MemoryLayout<CarveUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<CarveUniforms>.stride, index: 1)
        // Bed first (through-holes show it)
        enc.setRenderPipelineState(linePipe)
        enc.setDepthStencilState(depthRead)
        if let b = bedBuf { enc.setVertexBuffer(b, offset: 0, index: 0); enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: bedCount) }

        enc.setDepthStencilState(depthOn)
        if let ht = heightTex, ht.width > 1, ht.height > 1 {
            enc.setRenderPipelineState(heightPipe)
            enc.setVertexTexture(ht, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6 * (ht.width - 1) * (ht.height - 1))
        }
        if let b = skirtBuf {
            enc.setRenderPipelineState(meshPipe)
            enc.setVertexBuffer(b, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: skirtCount)
        }
        enc.setRenderPipelineState(linePipe)
        enc.setDepthStencilState(depthRead)
        if showToolpaths, let b = pathBuf {
            enc.setVertexBuffer(b, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: pathCount)
        }
        if let b = markerBuf {
            enc.setDepthStencilState(depthOff)
            enc.setVertexBuffer(b, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: markerCount)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

private enum CarveShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4x4 viewProj; float4 lightDir; float4 eye; float4 grid; uint4 gridSize; float4 wood; };
    struct MeshV { float3 pos; float3 nrm; float4 color; };
    struct LineV { float3 pos; float4 color; };
    struct VOut { float4 pos [[position]]; float3 nrm; float3 world; float4 color; float kind; };

    vertex VOut ce_mesh_vs(const device MeshV* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]], uint vid [[vertex_id]]) {
        VOut o; MeshV m = v[vid];
        float3 p = float3(m.pos);
        o.pos = u.viewProj * float4(p, 1); o.nrm = float3(m.nrm); o.world = p; o.color = m.color; o.kind = 0; return o;
    }

    float ce_h(texture2d<float> ht, uint x, uint y, float top) {
        float h = ht.read(uint2(x, y)).r;
        return isnan(h) ? top : clamp(h, 0.0, top + 50.0);
    }

    vertex VOut ce_height_vs(texture2d<float> ht [[texture(0)]], constant Uniforms& u [[buffer(1)]], uint vid [[vertex_id]]) {
        uint W = u.gridSize.x, H = u.gridSize.y;
        float top = u.grid.w;
        uint q = vid / 6, c = vid % 6;
        uint qx = q % (W - 1), qy = q / (W - 1);
        float h00 = ce_h(ht, qx, qy, top), h10 = ce_h(ht, qx + 1, qy, top);
        float h01 = ce_h(ht, qx, qy + 1, top), h11 = ce_h(ht, qx + 1, qy + 1, top);
        // Split each cell along the diagonal whose corners are closest in height, so angled walls stay smooth.
        const uint mainDiag[6] = {0, 1, 3, 0, 3, 2};
        const uint otherDiag[6] = {0, 1, 2, 1, 3, 2};
        uint corner = abs(h00 - h11) <= abs(h10 - h01) ? mainDiag[c] : otherDiag[c];
        uint x = qx + (corner & 1), y = qy + (corner >> 1);
        float h = ce_h(ht, x, y, top);
        float hl = ce_h(ht, uint(max(int(x) - 1, 0)), y, top), hr = ce_h(ht, min(x + 1, W - 1), y, top);
        float hd = ce_h(ht, x, uint(max(int(y) - 1, 0)), top), hu = ce_h(ht, x, min(y + 1, H - 1), top);
        float res = u.grid.z;
        float3 n = normalize(float3(hl - hr, hd - hu, 2.0 * res));
        float3 p = float3(u.grid.x + float(x) * res, u.grid.y + float(y) * res, h);
        VOut o; o.pos = u.viewProj * float4(p, 1); o.nrm = n; o.world = p; o.kind = 1;
        // Cut surfaces are darker than the uncut top, and darker still the deeper they are.
        float depth = clamp((top - h) / max(top, 1.0), 0.0, 1.0);
        float cut = smoothstep(0.01, 0.08, top - h);
        float3 base = u.wood.rgb;
        float3 col = mix(base, base * 0.8, cut);
        col = mix(col, base * 0.42, depth * 0.85);
        o.color = float4(col, 1);
        return o;
    }

    fragment float4 ce_surface_fs(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
        if (in.kind > 0.5 && in.world.z < 0.02) discard_fragment();  // cut right through: the bed shows
        float3 n = normalize(in.nrm);
        float3 v = normalize(u.eye.xyz - in.world);
        if (dot(n, v) < 0) n = -n;
        float3 base = in.color.rgb;
        if (u.gridSize.z == 1) {
            // Grain running along X: wavy bands across Y.
            float2 w = in.world.xy;
            float warp = 2.4 * sin(w.x * 0.019 + w.y * 0.061) + 0.9 * sin(w.x * 0.053 - w.y * 0.13) + 0.25 * sin(w.x * 0.31);
            float g = 0.5 + 0.5 * sin((w.y + warp) * 2.3);
            float g2 = 0.5 + 0.5 * sin((w.y + warp * 1.8) * 0.41 + 1.3);
            base *= 1.0 - 0.12 * pow(g, 6.0) - 0.06 * g2;
        }
        // Walls (steep faces of the height field) read a little darker.
        float wall = 1.0 - clamp(abs(n.z), 0.0, 1.0);
        base *= mix(1.0, 0.72, wall * in.kind);
        float3 l = normalize(u.lightDir.xyz);
        float diff = max(dot(n, l), 0.0);
        float hemi = 0.5 + 0.5 * n.z;
        float3 h = normalize(l + v);
        float spec = pow(max(dot(n, h), 0.0), 40.0) * 0.12;
        return float4(base * (0.3 + 0.2 * hemi + 0.62 * diff) + spec, 1);
    }

    vertex VOut ce_line_vs(const device LineV* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]], uint vid [[vertex_id]]) {
        VOut o; LineV m = v[vid];
        float3 p = float3(m.pos);
        o.pos = u.viewProj * float4(p, 1); o.pos.z -= 0.0005 * o.pos.w;
        o.nrm = float3(0, 0, 1); o.world = p; o.color = m.color; o.kind = 0; return o;
    }
    fragment float4 ce_line_fs(VOut in [[stage_in]]) { return in.color; }

    struct BgOut { float4 pos [[position]]; float2 uv; };
    vertex BgOut ce_bg_vs(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        BgOut o; o.pos = float4(p * 2 - 1, 0.9999, 1); o.uv = p; return o;
    }
    fragment float4 ce_bg_fs(BgOut in [[stage_in]]) {
        float t = clamp(in.uv.y, 0.0, 1.0);
        return float4(mix(float3(0.055, 0.055, 0.055), float3(0.11, 0.11, 0.11), t), 1);
    }
    """
}
