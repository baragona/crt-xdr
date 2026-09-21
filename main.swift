// CRT·XDR — a CRT simulation for Retina HDR displays.
// Native macOS: Metal + EDR (extended dynamic range) + 120Hz ProMotion.
//
// Build:  swiftc -O main.swift -o crt-xdr
// Run:    ./crt-xdr
//
// The trick: the drawable is rgba16Float in *extended linear sRGB*, with
// wantsExtendedDynamicRangeContent on. Shader output is linear light where
// 1.0 = SDR white; scanline beam peaks and mask compensation ride above 1.0
// into the panel's EDR headroom, so the mask/scanlines don't darken the image
// the way every SDR CRT filter must.

import Cocoa
import Metal
import MetalKit
import CoreText

// MARK: - Shaders

let MSL = """
#include <metal_stdlib>
using namespace metal;

struct U {
    float4 sizes;   // out.xy, src.zw
    float4 timing;  // time, dt, rolling, unused
    float4 beam;    // sigmaMin, sigmaMax, hSharp, tau
    float4 maskp;   // type, strength, comp, unused
    float4 geo;     // curvature, cornerR, vignette, margin
    float4 light;   // peak, brightness, halation, unused
    float4 cm0;     // phosphor chromaticity matrix, column 0
    float4 cm1;     // column 1
    float4 cm2;     // column 2
    float4 phys;    // convergence px, gamma ratio, cylindrical factor, interlace
    float4 taus;    // per-phosphor decay time constants (s), w unused
};

vertex float4 vs(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    return float4(p[vid], 0.0, 1.0);
}

// ---- phosphor persistence + rolling 60Hz beam, at source resolution --------
fragment float4 fsPersist(float4 fc [[position]],
                          constant U &u [[buffer(0)]],
                          texture2d<float> src  [[texture(0)]],
                          texture2d<float> prev [[texture(1)]],
                          sampler smp [[sampler(0)]]) {
    float2 suv = fc.xy / u.sizes.zw;
    float3 s = src.sample(smp, suv, level(0)).rgb;
    // gun nonlinearity: signal mastered for ~2.2, tube EOTF ~2.4 (Poynton)
    s = pow(max(s, 0.0), float3(u.phys.y));
    // render through real phosphor chromaticities (SMPTE-C etc., CPU-built)
    s = float3x3(u.cm0.xyz, u.cm1.xyz, u.cm2.xyz) * s;
    float3 pr = prev.sample(smp, suv, level(0)).rgb;
    // per-phosphor decay: red Y2O2S:Eu lags the green/blue sulfides
    float3 decay = exp(-u.timing.y / max(u.taus.xyz, float3(2e-5)));
    float3 fresh = s;
    if (u.timing.z > 0.5) {
        float phase  = fract(u.timing.x * 60.0);          // beam y, 0..1
        float sweep  = clamp(u.timing.y * 60.0, 0.0, 1.0); // swept this frame
        float behind = fract(phase - suv.y);
        float lit = behind < sweep ? 1.0 : 0.0;
        float boost = clamp(1.0 / (60.0 * max(u.taus.y, 2e-5)), 1.0, 4.0);
        fresh = s * lit * boost;
    }
    return float4(max(fresh, pr * decay), 1.0);
}

// ---- halation blur, separable, at source resolution -------------------------
static float3 blur9(float2 dir, float2 fc, constant U &u,
                    texture2d<float> t, sampler smp) {
    float2 px = dir / u.sizes.zw;
    float2 suv = fc / u.sizes.zw;
    float w[4] = { 0.2419, 0.1990, 0.1108, 0.0417 };
    float3 acc = 0.0; float tot = 0.0;
    for (int i = -3; i <= 3; i++) {
        float wi = w[abs(i)];
        acc += t.sample(smp, suv + px * float(i) * 2.6, level(0)).rgb * wi;
        tot += wi;
    }
    return acc / tot;
}
fragment float4 fsBlurH(float4 fc [[position]], constant U &u [[buffer(0)]],
                        texture2d<float> t [[texture(0)]], sampler smp [[sampler(0)]]) {
    return float4(blur9(float2(1.0, 0.0), fc.xy, u, t, smp), 1.0);
}
fragment float4 fsBlurV(float4 fc [[position]], constant U &u [[buffer(0)]],
                        texture2d<float> t [[texture(0)]], sampler smp [[sampler(0)]]) {
    return float4(blur9(float2(0.0, 1.0), fc.xy, u, t, smp), 1.0);
}

// ---- final composite at full Retina resolution -------------------------------
static float hash13(uint3 v) {
    uint n = v.x * 1597334673u ^ v.y * 3812015801u ^ v.z * 2798796415u;
    n = (n ^ (n >> 16)) * 2246822519u;
    n = n ^ (n >> 13);
    return float(n & 0xFFFFFFu) / 16777215.0;
}

struct MaskS { float3 w; float cellDy; };

// Phosphor structure modeled on macro photography of real tubes: soft-edged
// deposition (not hard rectangles), powder grain per cell, and for slot masks
// discrete rounded pills in a staggered brick layout.
static MaskS maskEval(float2 fcxy, int t, float grain) {
    MaskS o; o.w = float3(1.0); o.cellDy = 0.0;
    if (t == 0) { return o; }
    int scale = (t == 2 || t == 4) ? 2 : 1;
    float fs = float(scale);
    int xi = int(fcxy.x);
    int p = (xi / scale) % 3;
    float3 sel = float3(p == 0 ? 1.0 : 0.0, p == 1 ? 1.0 : 0.0, p == 2 ? 1.0 : 0.0);
    // lateral deposition profile: gaussian-soft stripe edges
    float cx = (floor(fcxy.x / fs) + 0.5) * fs;
    float dx = fcxy.x - cx;
    float sig = 0.42 * fs;
    float lat = exp(-dx * dx / (2.0 * sig * sig));
    if (t <= 2) {                       // aperture grille: continuous stripes
        float g = 1.0 + grain * (hash13(uint3(uint(xi / scale),
                                              uint(int(fcxy.y) / (4 * scale)), uint(p))) - 0.5);
        o.w = sel * lat * g;
        return o;
    }
    // slot mask: rounded phosphor pills, alternate columns offset half a period
    float P = 4.0 * fs;
    int triad = xi / (3 * scale);
    float yoff = float(triad % 2) * (P * 0.5);
    float ypos = fcxy.y + yoff;
    float cellRow = floor(ypos / P);
    float dyC = ypos - (cellRow + 0.5) * P;
    float hh = 0.5 * (P - fs);          // pill half-height; webbing one stripe wide
    float vert = 1.0 - smoothstep(hh - 0.5, hh + 0.5, fabs(dyC));
    float g = 1.0 + grain * (hash13(uint3(uint(triad),
                                          uint(int(cellRow) & 0x7fffffff), uint(p))) - 0.5);
    o.w = sel * lat * vert * g;
    o.cellDy = -dyC;                    // pills glow as units: beam sampled at cell center
    return o;
}

fragment float4 fsComposite(float4 fc [[position]],
                            constant U &u [[buffer(0)]],
                            texture2d<float> persistT [[texture(0)]],
                            texture2d<float> blurT    [[texture(1)]],
                            sampler smp [[sampler(0)]]) {
    float2 outSize = u.sizes.xy;
    float2 p = fc.xy / outSize * 2.0 - 1.0;

    // fit a 4:3 tube in the window
    float A = outSize.x / outSize.y;
    float T = 4.0 / 3.0;
    float2 c = p;
    if (A > T) { c.x = p.x * A / T; } else { c.y = p.y * T / A; }
    c /= u.geo.w;

    // barrel curvature. Trinitron (grille) tubes are cylindrical — curved
    // horizontally, flat vertically — so phys.z suppresses the vertical bow.
    float k = u.geo.x;
    float2 q = float2(c.x * (1.0 + k * c.y * c.y),
                      c.y * (1.0 + k * 1.3 * c.x * c.x * u.phys.z));

    // rounded-rect tube edge (SDF, antialiased) — derivatives before branching
    float r = u.geo.y;
    float2 dv = fabs(q) - float2(1.0 - r);
    float d = length(max(dv, float2(0.0))) + min(max(dv.x, dv.y), 0.0) - r;
    float fw = fwidth(d) + 1e-5;
    float screenA = 1.0 - smoothstep(-fw, fw, d);

    float2 suv = q * 0.5 + 0.5;
    float2 srcSize = u.sizes.zw;

    // horizontal: sharpened bilinear (video bandwidth)
    float sx = suv.x * srcSize.x - 0.5;
    float x0 = floor(sx);
    float f  = clamp((sx - x0 - 0.5) * u.beam.z + 0.5, 0.0, 1.0);
    float ux = (x0 + 0.5 + f) / srcSize.x;

    // interlace (480i): odd/even fields sit half a source line apart at 60Hz
    float off = 0.0;
    if (u.phys.w > 0.5) {
        float par = fmod(floor(u.timing.x * 60.0), 2.0);
        off = par * 0.5 - 0.25;
    }

    // misconvergence: R and B rasters splay horizontally, zero at center,
    // growing linearly toward the edges (pincushion-model radial error)
    float convU = u.phys.x * q.x / srcSize.x;

    // phosphor mask; slot-mask pills integrate the beam, so the scanline
    // field is evaluated at the pill center rather than per fragment
    int mt = int(u.maskp.x);
    MaskS mk = maskEval(fc.xy, mt, u.maskp.w);
    float suvY = suv.y + dfdy(suv.y) * mk.cellDy;

    // vertical: gaussian electron beam over the two nearest scanlines.
    // brighter -> wider; energy-normalized so a narrow beam peaks >1.0 (EDR)
    float H = srcSize.y;
    float fy = suvY * H - 0.5 - off;
    float l0 = floor(fy);
    float3 col = 0.0;
    for (int i = 0; i < 2; i++) {
        float l = l0 + float(i);
        float inR = (l >= -0.5 && l <= H - 0.5) ? 1.0 : 0.0;
        float vv = (l + 0.5 + off) / H;
        float3 s = float3(persistT.sample(smp, float2(ux + convU, vv), level(0)).r,
                          persistT.sample(smp, float2(ux, vv), level(0)).g,
                          persistT.sample(smp, float2(ux - convU, vv), level(0)).b);
        float lum = clamp(dot(s, float3(0.299, 0.587, 0.114)), 0.0, 1.0);
        float sigma = mix(u.beam.x, u.beam.y, lum);
        float dd = fy - l;
        float w = exp(-dd * dd / (2.0 * sigma * sigma)) * (0.4 / sigma) * inR;
        col += s * w;
    }

    // apply mask + energy compensation into EDR headroom
    col *= mix(float3(1.0), mk.w, u.maskp.y) * u.maskp.z;

    // Trinitron damper wires: fine horizontal shadow wires at 1/3 and 2/3
    if (mt == 1 || mt == 2) {
        float fq = max(fwidth(q.y), 1e-6);
        for (int wi = 0; wi < 2; wi++) {
            float yw = wi == 0 ? -0.3333 : 0.3333;
            float dpx = (q.y - yw) / fq;
            col *= 1.0 - 0.35 * u.maskp.y * exp(-dpx * dpx / 3.0);
        }
    }

    // halation
    col += blurT.sample(smp, suv, level(0)).rgb * u.light.z;

    // vignette
    col *= clamp(1.0 - u.geo.z * 0.5 * dot(c * 0.85, c * 0.85), 0.0, 1.0);

    // Normalize so a flat white area *averages* to SDR white (1.0): the beam
    // profile and mask compensation are already energy-preserving, so only the
    // halation term raises the average.
    col /= 1.0 + u.light.z;
    col *= u.light.y;                    // brightness: 1.0 = macOS SDR white

    // EDR is used only by the structure peaks (beam crests, lit phosphor
    // stripes). Soft-clip them into the available headroom (u.light.x).
    float L = max(u.light.x, 1.0);
    float knee = 0.6 * L;
    float mx = max(col.r, max(col.g, col.b));
    if (mx > knee) {
        float compressed = knee + (L - knee) * (1.0 - exp(-(mx - knee) / max(L - knee, 1e-4)));
        col *= compressed / mx;
    }

    col *= screenA;

    // EDR verification strip (toggle: T): patches at exactly 1x / 2x / 4x /
    // headroom-limit SDR white, in linear light. If HDR is engaged they step
    // up in brightness; if the pipeline were SDR they'd all look identical.
    if (u.timing.w > 0.5 && fc.y > outSize.y - 48.0) {
        int i = int(fc.x / 72.0);
        float rem = fc.x / 72.0 - float(i);
        if (i < 4 && rem < 0.9) {
            float levels[4] = { 1.0, 2.0, 4.0, max(u.light.x, 1.0) };
            col = float3(levels[i]);
        }
    }
    return float4(col, 1.0);
}
"""

// MARK: - Parameters

final class Params {
    var peak: Float = 8.0        // × SDR white
    var bright: Float = 0.9
    var maskType: Int = 2        // grille 0.6mm
    var maskStrength: Float = 1.0
    var grain: Float = 0.10      // phosphor powder grain, per-cell variation
    var sigMin: Float = 0.30
    var sigMax: Float = 0.55
    var sharp: Float = 2.5
    var halation: Float = 0.05
    var decayScale: Float = 1.0  // × real P22 time constants
    var conv: Float = 0.35       // R/B misconvergence at screen edge, source px
    var gammaC: Float = 2.4      // tube EOTF exponent (signal assumed 2.2)
    var phosphor: Int = 1        // 0 sRGB, 1 SMPTE-C D65, 2 SMPTE-C 9300K
    var interlace: Bool = false
    var curv: Float = 0.03
    var testStrip: Bool = false
    var corner: Float = 0.06
    var vig: Float = 0.25
    var rolling: Bool = false
    var scene: Int = 1           // 0 terminal, 1 bars, 2 plasma, 3 image
}
let params = Params()

// MARK: - Source signal painter (320x240, CoreGraphics, bottom-left coords)

let SW = 320, SH = 240

final class SourcePainter {
    let ctx: CGContext
    var dropped: CGImage?
    private var termLine = 0, termChars = 0
    private var termT0 = 0.0
    private let font = CTFontCreateWithName("Menlo" as CFString, 9, nil)

    private let boot = [
        "CRT-XDR MONITOR BIOS v1.2",
        "MEMORY TEST: 524288 BYTES OK",
        "",
        "PHOSPHOR ..... P22 TRIAD, 0.30MM PITCH",
        "DEFLECTION ... 15.734 KHZ / 60.00 HZ",
        "EDR HEADROOM . ######## UNLOCKED",
        "PANEL ........ 254 PPI @ 120 HZ",
        "",
        "ALL SYSTEMS NOMINAL.",
        "",
        "READY.",
        "> RUN DEMO",
    ]

    init() {
        ctx = CGContext(data: nil, width: SW, height: SH, bitsPerComponent: 8,
                        bytesPerRow: SW * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .none
    }

    private func fill(_ r: CGRect, _ red: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        ctx.setFillColor(CGColor(srgbRed: red, green: g, blue: b, alpha: 1))
        ctx.fill(r)
    }

    private func text(_ s: String, x: CGFloat, y: CGFloat,
                      _ red: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        ctx.setFillColor(CGColor(srgbRed: red, green: g, blue: b, alpha: 1))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func draw(_ t: Double) {
        switch params.scene {
        case 0: terminal(t)
        case 2: plasma(t)
        case 3: image()
        default: bars(t)
        }
    }

    private func bars(_ t: Double) {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
            (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)]
        let colors2: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 0.75), (0.07, 0.07, 0.07), (0.75, 0, 0.75), (0.07, 0.07, 0.07),
            (0, 0.75, 0.75), (0.07, 0.07, 0.07), (0.75, 0.75, 0.75)]
        let w7 = CGFloat(SW) / 7
        for i in 0..<7 {
            let (r, g, b) = colors[i]
            fill(CGRect(x: w7 * CGFloat(i), y: 80, width: w7 + 1, height: 160), r, g, b)
            let (r2, g2, b2) = colors2[i]
            fill(CGRect(x: w7 * CGFloat(i), y: 60, width: w7 + 1, height: 20), r2, g2, b2)
        }
        fill(CGRect(x: 0, y: 0, width: SW, height: 60), 0.05, 0.05, 0.05)
        // PLUGE + white reference
        fill(CGRect(x: 10, y: 15, width: 30, height: 30), 0, 0, 0)
        fill(CGRect(x: 45, y: 15, width: 30, height: 30), 0.04, 0.04, 0.04)
        fill(CGRect(x: 80, y: 15, width: 30, height: 30), 0.09, 0.09, 0.09)
        fill(CGRect(x: 120, y: 15, width: 40, height: 30), 1, 1, 1)
        // gray ramp
        for i in 0..<128 {
            let v = CGFloat(i) / 127
            fill(CGRect(x: 170 + CGFloat(i), y: 15, width: 1, height: 30), v, v, v)
        }
        // bouncing white square — shows persistence + rolling scan
        let bx = 20 + abs((t * 90).truncatingRemainder(dividingBy: Double(2 * (SW - 52))) - Double(SW - 52))
        let by = 20 + abs((t * 61).truncatingRemainder(dividingBy: 220.0) - 110.0)
        fill(CGRect(x: bx, y: Double(SH) - by - 12, width: 12, height: 12), 1, 1, 1)
        _ = text("CRT-XDR 320x240 60HZ", x: 216, y: 5, 1, 1, 1)
    }

    private func terminal(_ t: Double) {
        fill(CGRect(x: 0, y: 0, width: SW, height: SH), 0, 0, 0)
        let green: (CGFloat, CGFloat, CGFloat) = (0.22, 1.0, 0.43)
        if termT0 == 0 { termT0 = t }
        var budget = Int((t - termT0) * 40)
        var lastBaseline: CGFloat = 0
        var lastText = ""
        for i in 0...min(termLine, boot.count - 1) {
            let full = boot[i]
            var s = full
            if i == termLine {
                termChars = min(full.count, max(budget, 0))
                s = String(full.prefix(termChars))
                if termChars >= full.count { termLine += 1; termT0 = t + 0.25 }
            } else {
                budget -= full.count
            }
            let baseline = CGFloat(SH) - (16 + CGFloat(i) * 12)
            let w = text(s, x: 10, y: baseline, green.0, green.1, green.2)
            lastBaseline = baseline
            lastText = s
            _ = lastText
            if i == min(termLine, boot.count - 1) {
                // blinking block cursor
                if Int(t * 2.5) % 2 == 0 {
                    fill(CGRect(x: 10 + w + 1, y: baseline - 1, width: 6, height: 9),
                         green.0, green.1, green.2)
                }
            }
            _ = lastBaseline
        }
        if termLine >= boot.count && (t - termT0) > 6 { termLine = 0; termChars = 0; termT0 = t }
    }

    private func plasma(_ t: Double) {
        guard let data = ctx.data else { return }
        let buf = data.assumingMemoryBound(to: UInt8.self)
        let hw = SW / 2, hh = SH / 2
        for py in 0..<hh {
            for px in 0..<hw {
                let x = Double(px), y = Double(py)
                let v = sin(x * 0.11 + t * 1.9)
                      + sin((x + y) * 0.09 + t * 1.3)
                      + sin(((x - 80) * (x - 80) + (y - 60) * (y - 60)).squareRoot() * 0.12 - t * 2.2)
                let ph = v * 0.5 + .pi * t * 0.1
                let rr = UInt8(clamping: Int(128 + 120 * sin(ph)))
                let gg = UInt8(clamping: Int(128 + 120 * sin(ph + 2.094)))
                let bb = UInt8(clamping: Int(128 + 120 * sin(ph + 4.188)))
                for dy in 0..<2 {
                    let row = (py * 2 + dy) * SW * 4
                    for dx in 0..<2 {
                        let o = row + (px * 2 + dx) * 4
                        buf[o] = rr; buf[o + 1] = gg; buf[o + 2] = bb; buf[o + 3] = 255
                    }
                }
            }
        }
    }

    private func image() {
        fill(CGRect(x: 0, y: 0, width: SW, height: SH), 0, 0, 0)
        guard let img = dropped else {
            _ = text("DROP AN IMAGE ONTO THE WINDOW", x: 72, y: 118, 0.22, 1.0, 0.43)
            return
        }
        let s = max(CGFloat(SW) / CGFloat(img.width), CGFloat(SH) / CGFloat(img.height))
        let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
        ctx.draw(img, in: CGRect(x: (CGFloat(SW) - dw) / 2, y: (CGFloat(SH) - dh) / 2,
                                 width: dw, height: dh))
    }
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let painter = SourcePainter()
    var pPersist: MTLRenderPipelineState!
    var pBlurH: MTLRenderPipelineState!
    var pBlurV: MTLRenderPipelineState!
    var pComp: MTLRenderPipelineState!
    let sampler: MTLSamplerState
    let srcTex: MTLTexture
    let persist: [MTLTexture]
    let blurA: MTLTexture
    let blurB: MTLTexture
    var parity = 0
    var lastT = CACurrentMediaTime()
    var frames = 0
    var fpsT = 0.0
    weak var statusLabel: NSTextField?
    weak var view: MTKView?

    init(device: MTLDevice) throws {
        self.device = device
        queue = device.makeCommandQueue()!

        let lib = try device.makeLibrary(source: MSL, options: nil)
        func pipe(_ frag: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs")
            d.fragmentFunction = lib.makeFunction(name: frag)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        func tex(_ format: MTLPixelFormat, cpu: Bool = false) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: SW, height: SH, mipmapped: false)
            td.usage = cpu ? [.shaderRead] : [.shaderRead, .renderTarget]
            if !cpu { td.storageMode = .private }
            return device.makeTexture(descriptor: td)!
        }
        srcTex = tex(.rgba8Unorm_srgb, cpu: true)
        persist = [tex(.rgba16Float), tex(.rgba16Float)]
        blurA = tex(.rgba16Float)
        blurB = tex(.rgba16Float)

        super.init()
        pPersist = try pipe("fsPersist", .rgba16Float)
        pBlurH   = try pipe("fsBlurH", .rgba16Float)
        pBlurV   = try pipe("fsBlurV", .rgba16Float)
        pComp    = try pipe("fsComposite", .rgba16Float)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastT, 0.0001), 0.05))
        lastT = now

        // headroom: how far above SDR white this display can currently go
        let headroom = Float(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)

        frames += 1; fpsT += Double(dt)
        if fpsT >= 0.5 {
            let fps = Int((Double(frames) / fpsT).rounded())
            frames = 0; fpsT = 0
            let sz = view.drawableSize
            statusLabel?.stringValue = String(
                format: "output %.0f x %.0f px - %d fps\nEDR headroom now: %.2f x SDR white",
                sz.width, sz.height, fps, headroom)
        }

        painter.draw(now)
        srcTex.replace(region: MTLRegionMake2D(0, 0, SW, SH), mipmapLevel: 0,
                       withBytes: painter.ctx.data!, bytesPerRow: SW * 4)

        let s = params.maskStrength
        // per-channel spatial averages of the soft-profile masks (lateral
        // gaussian avg ~0.807, slot pill vertical duty ~0.75)
        let maskAvg: Float = [1.0, 0.269, 0.269, 0.202, 0.202][params.maskType]
        let comp = 1.0 / (1.0 - s * (1.0 - maskAvg))

        // Phosphor chromaticity -> sRGB matrices (row-major), derived from
        // SMPTE-C primaries R(.630,.340) G(.310,.595) B(.155,.070) with D65
        // or 9300K+8MPCD (x .2831, y .2971) white. SMPTE-C luma weights come
        // out .2124/.7011/.0866, matching the published coefficients.
        let mIdent: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let mSmpteC: [Float] = [0.9390, 0.0502, 0.0102,
                                0.0179, 0.9659, 0.0164,
                               -0.0016, -0.0044, 1.0060]
        let mSmpte93: [Float] = [0.7808, 0.0508, 0.0137,
                                 0.0149, 0.9746, 0.0220,
                                -0.0013, -0.0044, 1.3483]
        let m = params.phosphor == 1 ? mSmpteC : (params.phosphor == 2 ? mSmpte93 : mIdent)

        // P22 decay time constants (1/e, seconds): red Y2O2S:Eu ~1ms is the
        // slow one; green/blue sulfides are a few hundred microseconds.
        let tauR = 0.0010 * params.decayScale
        let tauG = 0.00025 * params.decayScale
        let tauB = 0.00010 * params.decayScale

        // Trinitron grille tubes are cylindrical: no vertical curvature
        let cyl: Float = (params.maskType == 1 || params.maskType == 2) ? 0.12 : 1.0

        var u: [Float] = [
            Float(view.drawableSize.width), Float(view.drawableSize.height), Float(SW), Float(SH),
            Float(now.truncatingRemainder(dividingBy: 3600)), dt, params.rolling ? 1 : 0,
            params.testStrip ? 1 : 0,
            params.sigMin, max(params.sigMax, params.sigMin + 0.01), params.sharp, 0,
            Float(params.maskType), s, comp, params.grain,
            params.curv, params.corner, params.vig, 0.94,
            min(params.peak, max(headroom, 1.0)), params.bright, params.halation, 0,
            m[0], m[3], m[6], 0,       // matrix column 0
            m[1], m[4], m[7], 0,       // column 1
            m[2], m[5], m[8], 0,       // column 2
            params.conv, params.gammaC / 2.2, cyl, params.interlace ? 1 : 0,
            tauR, tauG, tauB, 0,
        ]

        guard let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        let cur = parity; parity = 1 - parity

        func pass(_ p: MTLRenderPipelineState, _ target: MTLTexture, _ textures: [MTLTexture]) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
            e.setRenderPipelineState(p)
            e.setFragmentBytes(&u, length: 44 * 4, index: 0)
            e.setFragmentSamplerState(sampler, index: 0)
            for (i, t) in textures.enumerated() { e.setFragmentTexture(t, index: i) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        pass(pPersist, persist[cur], [srcTex, persist[1 - cur]])
        pass(pBlurH, blurA, [persist[cur]])
        pass(pBlurV, blurB, [blurA])
        pass(pComp, drawable.texture, [persist[cur], blurB])

        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - View (keys, drag & drop, fullscreen)

final class CRTView: MTKView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": params.scene = 0
        case "2": params.scene = 1
        case "3": params.scene = 2
        case "4": params.scene = 3
        case "r": params.rolling.toggle()
        case "t": params.testStrip.toggle()
        case "i": params.interlace.toggle()
        case "m": params.maskType = (params.maskType + 1) % 5
        case "f": window?.toggleFullScreen(nil)
        case "h": AppController.shared?.panel.setIsVisible(!(AppController.shared?.panel.isVisible ?? true))
        default: super.keyDown(with: event); return
        }
        AppController.shared?.syncControls()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.toggleFullScreen(nil) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = NSURL(from: sender.draggingPasteboard) as URL?,
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }
        (delegate as? Renderer)?.painter.dropped = cg
        params.scene = 3
        AppController.shared?.syncControls()
        return true
    }
}

// MARK: - App / UI

final class AppController: NSObject, NSApplicationDelegate {
    static var shared: AppController?
    var window: NSWindow!
    var panel: NSPanel!
    var renderer: Renderer!
    var scenePopup: NSPopUpButton!
    var maskPopup: NSPopUpButton!
    var rollingCheck: NSButton!
    var testCheck: NSButton!
    var interlaceCheck: NSButton!
    var phosphorPopup: NSPopUpButton!
    var sliderActions: [SliderAction] = []

    final class SliderAction: NSObject {
        let set: (Float) -> Void
        let out: NSTextField
        init(set: @escaping (Float) -> Void, out: NSTextField) { self.set = set; self.out = out }
        @objc func act(_ s: NSSlider) { set(s.floatValue); out.stringValue = String(format: "%.2f", s.floatValue) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared = self
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
        do { renderer = try Renderer(device: device) }
        catch { fatalError("shader compile failed: \(error)") }

        let rect = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "CRT·XDR"
        window.center()

        let view = CRTView(frame: rect, device: device)
        view.colorPixelFormat = .rgba16Float
        view.preferredFramesPerSecond = 120
        view.delegate = renderer
        renderer.view = view
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            layer.pixelFormat = .rgba16Float
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        buildPanel()
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildPanel() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let status = NSTextField(labelWithString: "starting…")
        status.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        status.textColor = .secondaryLabelColor
        renderer.statusLabel = status
        stack.addArrangedSubview(status)

        func popupRow(_ label: String, _ items: [String], _ sel: Int,
                      _ action: Selector) -> NSPopUpButton {
            let row = NSStackView()
            let l = NSTextField(labelWithString: label)
            l.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            l.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let pop = NSPopUpButton()
            pop.addItems(withTitles: items)
            pop.selectItem(at: sel)
            pop.target = self; pop.action = action
            pop.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            row.addArrangedSubview(l); row.addArrangedSubview(pop)
            stack.addArrangedSubview(row)
            return pop
        }
        scenePopup = popupRow("signal", ["terminal (P1)", "SMPTE bars", "plasma demo", "dropped image"],
                              params.scene, #selector(sceneChanged(_:)))
        maskPopup = popupRow("mask", ["none", "grille 0.3mm", "grille 0.6mm", "slot 0.3mm", "slot 0.6mm"],
                             params.maskType == 0 ? 0 : params.maskType,
                             #selector(maskChanged(_:)))
        phosphorPopup = popupRow("phosphors", ["sRGB (modern)", "SMPTE-C (D65)", "SMPTE-C 9300K"],
                                 params.phosphor, #selector(phosphorChanged(_:)))

        func slider(_ label: String, _ min: Float, _ max: Float, _ value: Float,
                    _ set: @escaping (Float) -> Void) {
            let row = NSStackView()
            let l = NSTextField(labelWithString: label)
            l.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            l.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let out = NSTextField(labelWithString: String(format: "%.2f", value))
            out.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            out.widthAnchor.constraint(equalToConstant: 38).isActive = true
            let action = SliderAction(set: set, out: out)
            sliderActions.append(action)
            let s = NSSlider(value: Double(value), minValue: Double(min), maxValue: Double(max),
                             target: action, action: #selector(SliderAction.act(_:)))
            s.isContinuous = true
            s.widthAnchor.constraint(equalToConstant: 130).isActive = true
            row.addArrangedSubview(l); row.addArrangedSubview(s); row.addArrangedSubview(out)
            stack.addArrangedSubview(row)
        }
        slider("peak limit x", 1, 8, params.peak) { params.peak = $0 }
        slider("brightness", 0.2, 2.5, params.bright) { params.bright = $0 }
        slider("mask strength", 0, 1, params.maskStrength) { params.maskStrength = $0 }
        slider("grain", 0, 0.3, params.grain) { params.grain = $0 }
        slider("beam min s", 0.10, 0.60, params.sigMin) { params.sigMin = $0 }
        slider("beam max s", 0.20, 1.00, params.sigMax) { params.sigMax = $0 }
        slider("h sharpness", 1, 4, params.sharp) { params.sharp = $0 }
        slider("halation", 0, 0.5, params.halation) { params.halation = $0 }
        slider("decay scale x", 0.1, 10, params.decayScale) { params.decayScale = $0 }
        slider("convergence", 0, 1.5, params.conv) { params.conv = $0 }
        slider("CRT gamma", 2.2, 2.6, params.gammaC) { params.gammaC = $0 }
        slider("curvature", 0, 0.25, params.curv) { params.curv = $0 }
        slider("corner r", 0.01, 0.2, params.corner) { params.corner = $0 }
        slider("vignette", 0, 0.8, params.vig) { params.vig = $0 }

        rollingCheck = NSButton(checkboxWithTitle: "rolling 60Hz scan",
                                target: self, action: #selector(rollingChanged(_:)))
        rollingCheck.state = params.rolling ? .on : .off
        rollingCheck.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stack.addArrangedSubview(rollingCheck)

        interlaceCheck = NSButton(checkboxWithTitle: "interlace (480i twitter)",
                                  target: self, action: #selector(interlaceChanged(_:)))
        interlaceCheck.state = params.interlace ? .on : .off
        interlaceCheck.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stack.addArrangedSubview(interlaceCheck)

        testCheck = NSButton(checkboxWithTitle: "EDR test strip (1x 2x 4x max)",
                             target: self, action: #selector(testChanged(_:)))
        testCheck.state = params.testStrip ? .on : .off
        testCheck.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stack.addArrangedSubview(testCheck)

        let hint = NSTextField(labelWithString: "keys: 1-4 scene · M mask · R rolling\nF fullscreen · H hide panel · drop an image")
        hint.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(hint)

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 10),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "controls"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        if let wf = window.screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: wf.maxX - stack.fittingSize.width - 30,
                                               y: wf.maxY - 30))
        }
        panel.orderFront(nil)
    }

    func buildMenu() {
        let menubar = NSMenu()
        let appItem = NSMenuItem()
        menubar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit CRT·XDR", action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = menubar
    }

    @objc func sceneChanged(_ p: NSPopUpButton) { params.scene = p.indexOfSelectedItem }
    @objc func maskChanged(_ p: NSPopUpButton) { params.maskType = p.indexOfSelectedItem }
    @objc func rollingChanged(_ b: NSButton) { params.rolling = b.state == .on }
    @objc func testChanged(_ b: NSButton) { params.testStrip = b.state == .on }
    @objc func interlaceChanged(_ b: NSButton) { params.interlace = b.state == .on }
    @objc func phosphorChanged(_ p: NSPopUpButton) { params.phosphor = p.indexOfSelectedItem }

    func syncControls() {
        scenePopup.selectItem(at: params.scene)
        maskPopup.selectItem(at: params.maskType)
        rollingCheck.state = params.rolling ? .on : .off
        testCheck.state = params.testStrip ? .on : .off
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - main

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
