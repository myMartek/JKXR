// The performance panel in the headset: how the game is running, as the numbers of the last second and the graphs of the last minute,
// fixed to the head just above the middle of the view. Create and Options (the two menu buttons of the Sense controllers) held together
// for a second show it and hide it, as in every game AVP Play builds, and the game must not open its menu for that. In Settings it can
// be shown from the start.
//
// Adapted from the Skyrim VR build for the Vision Pro (VXRuntime/xros/app/Sources/VXStatsPanel.swift and VXOverlay.swift), which has
// it from Klepton (MIT, Copyright (c) 2026 Max Thomas and contributors; fork https://github.com/myMartek/Klepton, tag toolchain-890;
// license text third_party/klepton/LICENSE): the button logic is runtime/diag/kl_metrics.c kl_metrics_chord, the idea and the
// placement visionos/Sources/KleptonCompositor.swift (the metrics panel, KL_STATS_CARD), the drawing KleptonMetrics.swift (beside
// this file).
//
// Different here: the engine calls in (the functions at the end, named JKXR_Leistung_*). The panel is a pass of its own over each
// eye's finished picture, on the app's command buffer, after ANGLE has finished that eye (TBXR_finishEyeBuffer, angle::Finish), and
// through the eye's rate map, because the drawable is foveated. The buttons are read where the engine's OpenXR layer syncs its
// actions (OpenXrActions.mm, xrSyncActions), and what the game is told of them comes from here.
//
// A meter must not be what it measures: until the panel is first shown nothing of it exists; the picture is drawn once a second on a
// queue of its own into the texture no frame is reading, and a frame only draws one quad with it.
import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore
import simd

// The two buttons' logic, apart from the drawing. Each button is in one of five states. A press waits (pending) before it is passed
// on (passing), because whether it is the first half of "both together" is only known a moment later, and a game that has been told
// "menu" has already opened it. A press that ends while it waits was a tap and is played afterwards (tap). Both down is chord for
// both, and stays that until both are up: letting one go must not turn the other into a press of its own.
struct MenuChord {
    static let wait = 0.25      // how long a press waits for the other button
    static let tap = 0.10       // how long a tap is played once it is known to be one
    static let hold = 1.0       // how long both are held to switch the panel
    private enum Phase { case idle, pending, passing, tap, chord }
    private var phase: [Phase] = [.idle, .idle]
    private var since: [Double] = [0, 0]
    private var chordSince = 0.0
    private var chordSpent = false          // switched already, or one of the two was let go

    /// One poll: which of the two buttons is down now. Returns whether each is passed on to the game, and whether this poll switched
    /// the panel (both held for `hold` without a gap).
    mutating func poll(left: Bool, right: Bool, now: Double) -> (passLeft: Bool, passRight: Bool, switched: Bool) {
        let down = [left, right]
        var switched = false
        if left && right {
            if phase[0] != .chord {
                phase = [.chord, .chord]
                chordSince = now; chordSpent = false
            } else if !chordSpent && now - chordSince >= Self.hold {
                chordSpent = true
                switched = true
            }
        } else if phase[0] == .chord {
            chordSpent = true                 // held together means without a gap
            if !left && !right { phase = [.idle, .idle] }
        }
        for h in 0..<2 {
            switch phase[h] {
            case .idle: if down[h] { phase[h] = .pending; since[h] = now }
            case .pending:
                if !down[h] { phase[h] = .tap; since[h] = now } else if now - since[h] >= Self.wait { phase[h] = .passing }
            case .passing: if !down[h] { phase[h] = .idle }
            case .tap: if now - since[h] >= Self.tap { phase[h] = .idle }
            case .chord: break
            }
        }
        func pass(_ h: Int) -> Bool { phase[h] == .passing || phase[h] == .tap }
        return (pass(0), pass(1), switched)
    }
}

final class Leistungsanzeige {
    static let shared = Leistungsanzeige()
    /// The setting "show from the start" (Settings, ContentView).
    static let schluessel = "jkxr.leistungsanzeige"
    /// JKXR_STATS_CARD_BUTTONS=0 hands the two buttons to the game untouched.
    static let tastenAn = ProcessInfo.processInfo.environment["JKXR_STATS_CARD_BUTTONS"] != "0"
    /// The panel's size and place in the view, exactly Klepton's (KLMetricsPanel.panelSize and the pose in KleptonCompositor.swift):
    /// 0.338 m wide at 1.2 m, just left of the middle, its lower edge a little above it.
    static let widthMeters: Float = KLMetricsPanel.panelSize.x, distanceMeters: Float = 1.2
    static let offsetMeters = SIMD2<Float>(-0.05, 0.101)

    private let lock = NSLock()
    private var chord = MenuChord()
    private var shown = false
    private var samples: [KLMetricsSample] = []
    private var front: MTLTexture?, back: MTLTexture?   // two, swapped when the new picture is complete: a frame never samples the one being written
    private var size = (w: 0, h: 0)                 // of front and back
    private var wanted = (w: 0, h: 0)
    private var device: MTLDevice?
    private var drawing = false
    private let queue = DispatchQueue(label: "jkxr.leistung", qos: .utility)
    private let quad = OverlayQuad()

    // counted on the frame thread
    private var frames = 0
    private var lastSample = CACurrentMediaTime()
    private var eye = (w: 0, h: 0)
    private var foveated = false

    var visible: Bool { lock.lock(); defer { lock.unlock() }; return shown }

    /// Shows or hides the panel (the setting, at the start of a run, and the chord). Shown anew, it starts measuring from there.
    func setVisible(_ on: Bool, why: String) {
        lock.lock()
        let changed = shown != on
        shown = on
        if changed && on { samples.removeAll() }
        lock.unlock()
        guard changed else { return }
        // Until the panel is first shown nothing of it exists: no count of the GPU's command buffers either.
        var counting = false
        if on {
            counting = jkxr_gpu_busy_install() != 0
            _ = jkxr_gpu_busy_take(nil); jkxr_gpu_compiles_take(nil, nil)
            frames = 0; lastSample = CACurrentMediaTime()
        }
        print("[Leistung] shown \(on), why \(why), gpu counted \(counting)")
        if on { redraw() }
    }

    /// The two menu buttons as read this poll; returns what the game is told of each.
    func buttons(left: Bool, right: Bool, now: Double) -> (left: Bool, right: Bool) {
        guard Self.tastenAn else { return (left, right) }
        lock.lock()
        let r = chord.poll(left: left, right: right, now: now)
        let next = r.switched ? !shown : shown
        lock.unlock()
        if r.switched { setVisible(next, why: "create+options") }
        return (r.passLeft, r.passRight)
    }

    private func note(_ sample: KLMetricsSample) {
        lock.lock()
        guard shown else { lock.unlock(); return }
        samples.append(sample)
        if samples.count > KLMetricsPanel.history { samples.removeFirst(samples.count - KLMetricsPanel.history) }
        lock.unlock()
        redraw()
    }

    private func redraw() {
        lock.lock()
        guard !drawing, wanted.w > 0, let device = device else { lock.unlock(); return }
        drawing = true
        let want = wanted, list = samples
        var target = size.w == want.w && size.h == want.h ? back : nil
        lock.unlock()
        queue.async { [self] in
            if target == nil { target = OverlayQuad.makeTexture(device, width: want.w, height: want.h) }
            if let tex = target { Self.render(list, into: tex, width: want.w, height: want.h) }
            lock.lock()
            if let tex = target {
                if size.w != want.w || size.h != want.h { front = tex; back = nil; size = want }   // a new size: the other one follows on the next turn
                else { back = front; front = tex }
            }
            drawing = false
            lock.unlock()
        }
    }

    private static func render(_ samples: [KLMetricsSample], into tex: MTLTexture, width w: Int, height h: Int) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
              let data = ctx.data else { return }
        // KLMetricsPanel draws top-down on its layout units.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        let unit = CGFloat(w) / CGFloat(KLMetricsPanel.panelLayout.w)
        ctx.scaleBy(x: unit, y: unit)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        KLMetricsPanel.drawPanel(ctx, samples: samples)
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
    }

    /// Draws the panel over `color` where a point above straight ahead falls in this eye. `view` is the drawable's eye transform
    /// (device from eye), `projection` its projection (right-up-back), `map` and `viewport` the eye's. Nothing happens while the panel
    /// is hidden or not drawn yet.
    func encode(cb: MTLCommandBuffer, color: MTLTexture, view: simd_float4x4, projection: simd_float4x4,
                map: MTLRasterizationRateMap?, viewport: MTLViewport) {
        eye = (color.width, color.height)
        foveated = map != nil
        let shape = SIMD2<Float>(Self.widthMeters, Self.widthMeters * Float(KLMetricsPanel.panelLayout.h) / Float(KLMetricsPanel.panelLayout.w))
        let displayWidth = map != nil && viewport.width > 0 ? viewport.width : Double(color.width)
        guard let at = OverlayQuad.place(size: shape, distance: Self.distanceMeters, offset: Self.offsetMeters, view: view,
                                         projection: projection, displayWidth: displayWidth) else { return }
        // as many pixels as the panel gets on the display, up to the size it is laid out on
        let w = min(max(at.pixels & ~1, 240), KLMetricsPanel.panelPixels.w)
        let h = w * KLMetricsPanel.panelLayout.h / KLMetricsPanel.panelLayout.w
        lock.lock()
        guard shown else { lock.unlock(); return }
        let fresh = wanted.w != w || wanted.h != h || device == nil
        if fresh { wanted = (w, h); device = cb.device }
        let tex = front
        lock.unlock()
        if fresh || tex == nil { redraw() }
        guard let tex = tex else { return }
        quad.draw(cb: cb, color: color, texture: tex, centre: at.centre, half: at.half, map: map, viewport: viewport)
    }

    // ---- the sample ------------------------------------------------------------------------------------------------------------

    /// One presented frame (TBXR_finishEyeBuffer, after the second eye). Once a second, while the panel is shown, the second's sample.
    func frame() {
        guard visible else { return }
        frames += 1
        let now = CACurrentMediaTime(), dt = now - lastSample
        guard dt >= 1.0 else { return }
        lastSample = now
        var s = KLMetricsSample()
        // The engine draws every picture it presents: the game's rate and the display's are the same here.
        s.fps = Float(Double(frames) / dt)
        s.displayHz = s.fps
        frames = 0
        // Shaders and pipeline states asked of Metal this second (GpuLast.m), compiled or only fetched: ANGLE's too.
        var compiled: UInt = 0, cached: UInt = 0
        jkxr_gpu_compiles_take(&compiled, &cached)
        s.compiles = Float(Double(compiled) / dt); s.compilesCached = Float(Double(cached) / dt)
        // The GPU's working time for the app, as Klepton's panel has it: against the wall clock a utilization; over the frames, the
        // GPU time of one (both eyes, and the panel itself).
        let busy = jkxr_gpu_busy_take(nil)
        if busy >= 0 {
            s.gpuBusy = Float(min(busy / dt, 1))
            if s.fps >= 1, busy > 0 { s.gpuGameMs = Float(busy / Double(s.fps) * 1000) }
        }
        let c = cpu()
        s.cpuCores = c.cores; s.cpuTop = c.top; s.cpuTopName = c.name
        let m = memory()
        s.memUsedMB = m.used; s.memLeftMB = m.left
        s.thermal = ProcessInfo.processInfo.thermalState.rawValue
        s.eyeW = eye.w; s.eyeH = eye.h
        s.outW = eye.w; s.outH = eye.h
        s.upscale = -1
        s.path = "OpenGL ES on ANGLE · per eye" + (foveated ? " · foveated" : "")
        note(s)
    }

    /// CPU the process used since the last call, in cores, and the busiest thread's share of one core with its name.
    private func cpu() -> (cores: Float, top: Float, name: String) {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let list = threads else { return (-1, -1, "") }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)) }
        var total = 0.0, top = 0.0, name = ""
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var n = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &n) } }
            if kr == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                let share = Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
                total += share
                if share > top {
                    top = share
                    var buf = [CChar](repeating: 0, count: 64)
                    if let pt = pthread_from_mach_thread_np(list[i]), pthread_getname_np(pt, &buf, buf.count) == 0 { name = String(cString: buf) } else { name = "" }
                }
            }
            mach_port_deallocate(mach_task_self_, list[i])
        }
        return (Float(total), Float(min(top, 1)), name)
    }

    private func memory() -> (used: Int, left: Int) {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        let used = kr == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
        return (used, Int(os_proc_available_memory() >> 20))
    }
}

/// A picture drawn over an eye's drawable as a quad fixed to the head.
///
/// A quad, not a copy of pixels: a foveated drawable's texture is not a plain picture. It is rasterized through a rate map (dense
/// where the eye looks, sparse at the edge) and the system unwarps it on the way to the display, so pixels copied into it land warped
/// and move with the gaze. A pass that sets the map draws in the display's own coordinates.
final class OverlayQuad {
    private var pipeline: MTLRenderPipelineState?
    private var format: MTLPixelFormat = .invalid
    private var sampler: MTLSamplerState?
    private var failed = false

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct P { float4 rect; };
    struct V { float4 position [[position]]; float2 uv; };
    vertex V ov(uint i [[vertex_id]], constant P &p [[buffer(0)]]) {
        float2 c = float2((i & 1) ? 1.0 : -1.0, (i & 2) ? 1.0 : -1.0);
        V v;
        v.position = float4(p.rect.xy + c * p.rect.zw, 0.05, 1.0);
        v.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5);
        return v;
    }
    fragment float4 of(V v [[stage_in]], texture2d<float> img [[texture(0)]], sampler smp [[sampler(0)]]) {
        return img.sample(smp, v.uv);
    }
    """

    private func prepare(_ device: MTLDevice, _ color: MTLPixelFormat) -> Bool {
        if pipeline != nil && format == color { return true }
        if failed { return false }
        do {
            let lib = try device.makeLibrary(source: Self.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "ov"); d.fragmentFunction = lib.makeFunction(name: "of")
            d.colorAttachments[0].pixelFormat = color
            // the picture's alpha is premultiplied (CoreGraphics): a translucent panel with round corners over the game
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one; d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one; d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
            let s = MTLSamplerDescriptor()
            s.minFilter = .linear; s.magFilter = .linear; s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: s)
            format = color
        } catch {
            failed = true
            print("[Leistung] overlay error: \(error)")
        }
        return pipeline != nil && sampler != nil
    }

    /// Draws `texture` over `color` as a quad with its middle at `centre` and half extents `half`, both in normalized device
    /// coordinates of the eye.
    @discardableResult
    func draw(cb: MTLCommandBuffer, color: MTLTexture, texture: MTLTexture, centre: SIMD2<Float>, half: SIMD2<Float>,
              map: MTLRasterizationRateMap?, viewport: MTLViewport) -> Bool {
        guard prepare(cb.device, color.pixelFormat), let pipeline, let sampler else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        if let map { pass.rasterizationRateMap = map }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if viewport.width > 0, viewport.height > 0 { enc.setViewport(viewport) }
        var rect = SIMD4<Float>(centre.x, centre.y, half.x, half.y)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return true
    }

    /// Where a card `size` metres wide and high lies in this eye, `distance` metres ahead of the head with its middle `offset` metres
    /// to the right of and above straight ahead: its middle and half extents in normalized device coordinates, and how many pixels
    /// wide it is on the display.
    static func place(size: SIMD2<Float>, distance: Float, offset: SIMD2<Float>, view: simd_float4x4, projection: simd_float4x4,
                      displayWidth: Double) -> (centre: SIMD2<Float>, half: SIMD2<Float>, pixels: Int)? {
        let p = projection * (view.inverse * SIMD4<Float>(offset.x, offset.y, -distance, 1))
        guard p.w > 0, distance > 0 else { return nil }
        let half = SIMD2<Float>(size.x * 0.5 * projection.columns.0.x / distance, size.y * 0.5 * projection.columns.1.y / distance)
        return (SIMD2<Float>(p.x / p.w, p.y / p.w), half, Int(Double(half.x) * displayWidth))
    }

    /// A texture for a CoreGraphics bitmap (BGRA, premultiplied alpha, sRGB bytes).
    static func makeTexture(_ device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        return device.makeTexture(descriptor: d)
    }
}

// ---- what the engine calls (Projects/Android/jni/OpenJK/JKXR/visionos: TBXR_Common.mm, OpenXrActions.mm) -------------------------
//
// Plain C names, resolved when the app is linked: the engine's two sets (Outcast and Academy, link-visionos.sh) only refer to them.

/// Whether the panel is shown: the engine then passes each eye.
@_cdecl("JKXR_Leistung_Sichtbar")
func jkxrLeistungSichtbar() -> Bool { Leistungsanzeige.shared.visible }

/// The two menu buttons, raw (left: Create, right: Options). Returns what the game is told of them: bit 0 left, bit 1 right.
@_cdecl("JKXR_Leistung_Tasten")
func jkxrLeistungTasten(_ links: Bool, _ rechts: Bool, _ jetzt: Double) -> Int32 {
    let r = Leistungsanzeige.shared.buttons(left: links, right: rechts, now: jetzt)
    return (r.left ? 1 : 0) | (r.right ? 2 : 0)
}

/// One presented frame.
@_cdecl("JKXR_Leistung_Bild")
func jkxrLeistungBild() { Leistungsanzeige.shared.frame() }

/// One eye: the command buffer that presents it, its colour texture, its view (device from eye) and projection as 16 floats each,
/// column by column, its rate map or nothing, and its viewport.
@_cdecl("JKXR_Leistung_Auge")
func jkxrLeistungAuge(_ cb: UnsafeMutableRawPointer, _ color: UnsafeMutableRawPointer,
                      _ view: UnsafePointer<Float>, _ projection: UnsafePointer<Float>, _ map: UnsafeMutableRawPointer?,
                      _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
    guard let buffer = Unmanaged<AnyObject>.fromOpaque(cb).takeUnretainedValue() as? MTLCommandBuffer,
          let texture = Unmanaged<AnyObject>.fromOpaque(color).takeUnretainedValue() as? MTLTexture else { return }
    let rate = map.flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? MTLRasterizationRateMap }
    func matrix(_ p: UnsafePointer<Float>) -> simd_float4x4 {
        func column(_ i: Int) -> SIMD4<Float> { SIMD4(p[4 * i], p[4 * i + 1], p[4 * i + 2], p[4 * i + 3]) }
        return simd_float4x4(columns: (column(0), column(1), column(2), column(3)))
    }
    Leistungsanzeige.shared.encode(cb: buffer, color: texture, view: matrix(view), projection: matrix(projection), map: rate,
                                   viewport: MTLViewport(originX: x, originY: y, width: w, height: h, znear: 0, zfar: 1))
}
