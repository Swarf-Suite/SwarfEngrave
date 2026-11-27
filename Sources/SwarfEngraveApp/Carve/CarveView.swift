// The 3D carve view: the preview surface (or the simulated stock during playback) with orbit / pan / zoom, view
// presets, toolpath lines and a playback scrubber.

import AppKit
import CAMCore
import Combine
import EngraveCore
import MetalKit
import SwiftUI

struct CarveView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var playback = CarvePlayback()
    @StateObject private var control = CarveControl()

    var body: some View {
        ZStack {
            Color.obsidian
            CarveRepresentable(model: model, playback: playback, control: control)
            VStack {
                HStack(spacing: 8) {
                    Spacer()
                    viewButtons
                    if !model.toolpaths.isEmpty {
                        Button { model.showToolpaths.toggle() } label: {
                            Label("Toolpaths", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .swarfButton(model.showToolpaths ? .outlineAccent : .normal, .small, active: model.showToolpaths)
                        .help("Show the toolpaths over the carving")
                    }
                }
                Spacer()
                if !model.toolpaths.isEmpty { playbackBar }
            }
            .padding(10)
            if control.metalUnavailable {
                Text("The 3D view needs Metal graphics, which this Mac doesn't offer.")
                    .font(.system(size: 12)).foregroundStyle(Color.steel)
            }
        }
        .onChange(of: toolpathKey) { _, _ in playback.stop() }
        .onDisappear { playback.stop() }
    }

    private var toolpathKey: String { CarvePlayback.key(model.toolpaths) }

    private var viewButtons: some View {
        HStack(spacing: 0) {
            ForEach(CarveViewPreset.allCases) { p in
                Button { control.view?.apply(p) } label: {
                    Text(p.rawValue).font(.system(size: 11, weight: .medium)).frame(minWidth: 40, minHeight: 22)
                        .foregroundStyle(control.preset == p ? Color.obsidian : Color.offwhite)
                        .background(control.preset == p ? Color.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.slate, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.line))
    }

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Button {
                if playback.state == .playing { playback.pause() } else { playback.play(model: model) }
            } label: {
                Image(systemName: playback.state == .playing ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .swarfButton(.primary, .small)
            .help(playback.state == .playing ? "Pause" : "Play the carving")
            Button { playback.stop() } label: { Image(systemName: "stop.fill").frame(width: 16) }
                .swarfButton(.normal, .small)
                .disabled(playback.state == .idle)
                .help("Stop and show the preview")
            Slider(value: Binding(get: { playback.progress }, set: { playback.scrub(to: $0, model: model) }), in: 0...1)
                .tint(Color.accent)
                .frame(minWidth: 160)
            Text(playback.state == .idle ? "Preview" : "\(Int((playback.progress * 100).rounded()))%")
                .font(.mono).foregroundStyle(Color.steel).frame(width: 64, alignment: .trailing)
            if playback.state != .idle, !playback.currentName.isEmpty {
                Text(playback.currentName).font(.system(size: 11)).foregroundStyle(Color.steel).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.slate.opacity(0.96), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.line))
        .frame(maxWidth: 640)
    }
}

/// Commands from the SwiftUI controls to the Metal view.
@MainActor
final class CarveControl: ObservableObject {
    weak var view: CarveMTKView?
    @Published var preset: CarveViewPreset? = .iso
    @Published var metalUnavailable = false
}

// MARK: Playback

/// Plays the toolpaths back by cutting a StockSimulator off the main thread and showing snapshots of it.
@MainActor
final class CarvePlayback: ObservableObject {
    enum State { case idle, playing, paused }
    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var surface: Grid2D?
    @Published private(set) var toolPosition: V3?
    @Published private(set) var tool: Tool?
    @Published private(set) var currentName = ""

    /// Seconds for the whole job at normal speed.
    var duration: Double = 30

    private var key = ""
    private var segments: [SimSegment] = []
    private var cumulative: [Double] = []  // weighted length at the end of each segment
    private var names: [String] = []
    private var tools: [Tool] = []
    private var timer: Timer?
    private var lastTick = Date()
    private let worker = SimWorker()

    static func key(_ tps: [Toolpath]) -> String { tps.map { "\($0.id):\($0.moves.count):\($0.tool.id)" }.joined(separator: ",") }

    private func prepare(_ model: EditorModel) {
        let k = Self.key(model.toolpaths) + "|\(model.sheet.stock.size)"
        guard k != key else { return }
        key = k
        segments = []
        cumulative = []
        names = model.toolpaths.map(\.name)
        tools = model.toolpaths.map(\.tool)
        var run = 0.0
        for (ti, tp) in model.toolpaths.enumerated() {
            let pts = tp.tessellated(maxSegment: 1)
            guard pts.count > 1 else { continue }
            for i in 1..<pts.count {
                let a = pts[i - 1].0, (b, kind) = pts[i]
                let len = simd_distance(a, b)
                // Rapids take a fraction of the time of cutting moves.
                run += kind == .rapid ? len * 0.15 : len
                segments.append(SimSegment(a: a, b: b, tool: ti))
                cumulative.append(run)
            }
        }
        let stock = model.sheet.stock.size
        let res = max(StockSimulator.defaultResolution(for: stock), (stock.x * stock.y / 2_000_000).squareRoot())
        worker.configure(segments: segments, tools: tools, stockSize: stock, resolution: res) { [weak self] grid, done in
            guard let self, self.state != .idle else { return }
            self.surface = grid
            self.updateTool(done)
        }
    }

    private func updateTool(_ done: Int) {
        guard !segments.isEmpty else { toolPosition = nil; return }
        let i = max(0, min(segments.count - 1, done - 1))
        toolPosition = progress >= 1 ? nil : segments[i].b
        tool = tools[segments[i].tool]
        currentName = names[segments[i].tool]
    }

    private func segmentIndex(_ p: Double) -> Int {
        guard let total = cumulative.last, total > 0 else { return segments.count }
        let target = p * total
        var lo = 0, hi = cumulative.count
        while lo < hi { let m = (lo + hi) / 2; if cumulative[m] < target { lo = m + 1 } else { hi = m } }
        return min(segments.count, lo + (p >= 1 ? 1 : 0))
    }

    func play(model: EditorModel) {
        prepare(model)
        guard !segments.isEmpty else { return }
        if progress >= 1 || state == .idle { progress = 0 }
        state = .playing
        lastTick = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        worker.request(segmentIndex(progress))
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        progress = min(1, progress + dt / max(1, duration))
        worker.request(segmentIndex(progress))
        if progress >= 1 { pause() }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        if state == .playing { state = .paused }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        state = .idle
        progress = 0
        surface = nil
        toolPosition = nil
        currentName = ""
        worker.request(0)
    }

    func scrub(to p: Double, model: EditorModel) {
        prepare(model)
        guard !segments.isEmpty else { return }
        progress = max(0, min(1, p))
        if state == .idle { state = .paused }
        worker.request(segmentIndex(progress))
    }
}

struct SimSegment: Sendable {
    var a: V3
    var b: V3
    var tool: Int
}

/// Owns the simulator; all cutting happens on its serial queue. The main thread only sets the target.
final class SimWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "swarfengrave.carve.sim", qos: .userInitiated)
    private var segments: [SimSegment] = []
    private var tools: [Tool] = []
    private var stockSize = V3(1, 1, 1)
    private var resolution = 0.5
    private var sim: StockSimulator?
    private var done = 0
    private var target = 0
    private var running = false
    private var generation = 0
    private var onSnapshot: (@MainActor (Grid2D, Int) -> Void)?

    func configure(segments: [SimSegment], tools: [Tool], stockSize: V3, resolution: Double, onSnapshot: @escaping @MainActor (Grid2D, Int) -> Void) {
        lock.lock()
        self.segments = segments
        self.tools = tools
        self.stockSize = stockSize
        self.resolution = resolution
        self.onSnapshot = onSnapshot
        generation += 1
        target = 0
        lock.unlock()
    }

    private var simGeneration = -1

    /// Queue only.
    private func resetSim(_ g: Int) {
        lock.lock(); let size = stockSize, res = resolution; lock.unlock()
        sim = StockSimulator(stockSize: size, resolution: res)
        simGeneration = g
        done = 0
    }

    func request(_ t: Int) {
        lock.lock()
        target = t
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { [self] in loop() } }
    }

    private func loop() {
        var lastPublish = Date.distantPast
        var dirty = false
        while true {
            lock.lock()
            let t = target, segs = segments, tl = tools, g = generation, publish = onSnapshot
            if sim == nil || t < done || simGeneration != g {
                lock.unlock()
                resetSim(g)
                lock.lock()
            }
            if done >= t {
                running = false
                lock.unlock()
                if dirty, let s = sim?.stock, let publish { let d = done; DispatchQueue.main.async { MainActor.assumeIsolated { publish(s, d) } } }
                return
            }
            lock.unlock()
            // Cut a chunk, then look again at the target (it moves while playing).
            let end = min(t, done + 400, segs.count)
            if done < end {
                for i in done..<end {
                    let s = segs[i]
                    sim?.cut(from: s.a, to: s.b, tool: tl[s.tool])
                }
                done = end
                dirty = true
            } else {
                done = t  // target beyond the segment list
            }
            if Date().timeIntervalSince(lastPublish) > 1.0 / 15, let s = sim?.stock, let publish {
                lastPublish = Date()
                dirty = false
                let d = done
                DispatchQueue.main.async { MainActor.assumeIsolated { publish(s, d) } }
            }
        }
    }
}

// MARK: Metal view and input

final class CarveMTKView: MTKView {
    var renderer: CarveRenderer?
    weak var control: CarveControl?
    var stockSize = V3(200, 100, 12)
    /// Keep the stock framed as the view resizes until the user moves the camera.
    var autoFrame = true

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if autoFrame, let renderer, newSize.width > 10, newSize.height > 10 {
            renderer.camera.frame(stockSize, aspect: Float(newSize.width / newSize.height))
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self) }

    override func mouseDragged(with e: NSEvent) {
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.shift) { pan(dx: e.deltaX, dy: e.deltaY) } else { orbit(dx: e.deltaX, dy: e.deltaY) }
    }

    override func rightMouseDragged(with e: NSEvent) { pan(dx: e.deltaX, dy: e.deltaY) }
    override func otherMouseDragged(with e: NSEvent) { pan(dx: e.deltaX, dy: e.deltaY) }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            // Trackpad: two-finger drag pans.
            pan(dx: e.scrollingDeltaX, dy: -e.scrollingDeltaY)
        } else {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 0.01 : 0.08
            zoom(Float(1 - e.scrollingDeltaY * k))
        }
    }

    override func magnify(with e: NSEvent) { zoom(Float(1 - e.magnification)) }

    override func rotate(with e: NSEvent) {
        renderer?.camera.yaw -= e.rotation * .pi / 180
        control?.preset = nil
        needsDisplay = true
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        guard let renderer else { return }
        autoFrame = false
        renderer.camera.yaw -= Float(dx) * 0.008
        renderer.camera.pitch = max(0, min(1.5707, renderer.camera.pitch + Float(dy) * 0.008))
        if renderer.camera.ortho && renderer.camera.pitch < 1.5 && renderer.camera.pitch > 0.05 { renderer.camera.ortho = false }
        control?.preset = nil
        needsDisplay = true
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        guard let renderer else { return }
        autoFrame = false
        let c = renderer.camera
        let v = c.view()
        let right = SIMD3<Float>(v[0][0], v[1][0], v[2][0])
        let up = SIMD3<Float>(v[0][1], v[1][1], v[2][1])
        let scale = c.distance * 2 * tan(c.fovY / 2) / Float(max(1, bounds.height))
        renderer.camera.target += (-right * Float(dx) + up * Float(dy)) * scale
        needsDisplay = true
    }

    func zoom(_ f: Float) {
        guard let renderer, f.isFinite else { return }
        autoFrame = false
        renderer.camera.distance = max(5, min(20000, renderer.camera.distance * max(0.5, min(1.5, f))))
        needsDisplay = true
    }

    func apply(_ p: CarveViewPreset) {
        guard let renderer else { return }
        switch p {
        case .iso: renderer.camera.yaw = -0.6; renderer.camera.pitch = 0.6; renderer.camera.ortho = false
        case .top: renderer.camera.yaw = 0; renderer.camera.pitch = 1.5707; renderer.camera.ortho = true
        case .front: renderer.camera.yaw = 0; renderer.camera.pitch = 0; renderer.camera.ortho = true
        }
        renderer.camera.frame(stockSize, aspect: Float(bounds.width / max(1, bounds.height)))
        autoFrame = true
        control?.preset = p
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        switch e.charactersIgnoringModifiers {
        case "1": apply(.top)
        case "2": apply(.front)
        case "3", "0": apply(.iso)
        default: super.keyDown(with: e)
        }
    }
}

private struct CarveRepresentable: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: CarvePlayback
    let control: CarveControl

    @MainActor
    final class Coordinator {
        var renderer: CarveRenderer?
        weak var view: CarveMTKView?
        var bag: Set<AnyCancellable> = []
        var stockKey = ""
        var pathKey = ""
        var framed = false
        var lastSurfaceToken: Int = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CarveMTKView {
        let v = CarveMTKView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), device: MTLCreateSystemDefaultDevice())
        v.control = control
        control.view = v
        guard let r = CarveRenderer(view: v) else {
            DispatchQueue.main.async { control.metalUnavailable = true }
            return v
        }
        v.renderer = r
        v.delegate = r
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.allowedTouchTypes = [.indirect]
        let c = context.coordinator
        c.renderer = r
        c.view = v
        // Surfaces are large; push them to the GPU only when they actually change (not on every model change).
        let m = model, pb = playback
        m.$previewSurface.receive(on: DispatchQueue.main).sink { [weak c] g in
            MainActor.assumeIsolated {
                guard let c, pb.state == .idle else { return }
                c.renderer?.setSurface(g, stock: m.sheet.stock)
                c.view?.needsDisplay = true
            }
        }.store(in: &c.bag)
        pb.$surface.receive(on: DispatchQueue.main).sink { [weak c] g in
            MainActor.assumeIsolated {
                guard let c else { return }
                c.renderer?.setSurface(pb.state == .idle ? m.previewSurface : (g ?? m.previewSurface), stock: m.sheet.stock)
                c.view?.needsDisplay = true
            }
        }.store(in: &c.bag)
        r.setSurface(model.previewSurface, stock: model.sheet.stock)
        return v
    }

    func updateNSView(_ v: CarveMTKView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        let c = context.coordinator
        control.view = v
        let sheet = model.sheet
        let st = sheet.stock
        v.stockSize = st.size
        let sk = "\(sheet.id)|\(st.width)|\(st.height)|\(st.thickness)|\(st.colorHex)|\(st.showGrain)|\(sheet.workZero.corner)|\(sheet.workZero.zOnTop)"
        if sk != c.stockKey {
            let resized = !c.stockKey.hasPrefix("\(sheet.id)|\(st.width)|\(st.height)|")
            c.stockKey = sk
            r.setBed(stock: st, workZero: sheet.workZero.origin(for: st))
            r.setSurface(playback.state == .idle ? model.previewSurface : (playback.surface ?? model.previewSurface), stock: st)
            if resized || !c.framed {
                v.autoFrame = true
                r.camera.frame(st.size, aspect: Float(max(1, v.bounds.width) / max(1, v.bounds.height)))
                c.framed = true
            }
        }
        let pk = CarvePlayback.key(model.toolpaths)
        if pk != c.pathKey {
            c.pathKey = pk
            r.setToolpaths(model.toolpaths)
        }
        r.showToolpaths = model.showToolpaths
        r.setToolMarker(playback.state == .idle ? nil : playback.toolPosition, tool: playback.tool)
        v.needsDisplay = true
    }
}
