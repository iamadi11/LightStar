/// Metal source for the Canvas fluid, compiled at run time with
/// `makeLibrary(source:)` so `swift test` can build and test it (SwiftPM's CLI
/// doesn't compile .metal files). Stable-fluids steps after Pavel Dobryakov's
/// WebGL Fluid Simulation (MIT): curl, vorticity, divergence, Jacobi pressure,
/// gradient subtract, advection, splats. Everything works in texture rows
/// (+y is down the screen); "T" is the next row throughout, so the maths is
/// the original's in index space and the vorticity sign stays consistent.
enum FluidShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    // Drawing a big colour texture into a smaller target needs its mipmaps:
    // plain linear sampling skips texels and shimmers.
    constexpr sampler displaySampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

    struct FluidParams {
        float2 simTexel;     // 1 / velocity texture size
        float dt;
        float dissipation;
        float2 point;        // splat centre, 0…1, y down
        float radius;
        float aspect;
        float4 value;        // splat colour or velocity
        float curl;
        float pressureDecay;
        uint2 origin;        // top-left texel of a patch-only dispatch
    };

    static inline bool outside(uint2 gid, uint w, uint h) { return gid.x >= w || gid.y >= h; }

    template <typename T>
    static inline float4 at(T tex, int2 p) {
        int2 size = int2(tex.get_width(), tex.get_height());
        return tex.read(uint2(clamp(p, int2(0), size - 1)));
    }

    kernel void advect(texture2d<float, access::sample> velocity [[texture(0)]],
                       texture2d<float, access::sample> source [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       constant FluidParams& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, out.get_width(), out.get_height())) return;
        float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
        float2 back = uv - p.dt * velocity.sample(linearClamp, uv).xy * p.simTexel;
        out.write(source.sample(linearClamp, back) / (1.0 + p.dissipation * p.dt), gid);
    }

    kernel void curl(texture2d<float, access::read> velocity [[texture(0)]],
                     texture2d<float, access::write> out [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, out.get_width(), out.get_height())) return;
        int2 g = int2(gid);
        float L = at(velocity, g - int2(1, 0)).y, R = at(velocity, g + int2(1, 0)).y;
        float T = at(velocity, g + int2(0, 1)).x, B = at(velocity, g - int2(0, 1)).x;
        out.write(float4(0.5 * (R - L - T + B)), gid);
    }

    kernel void vorticity(texture2d<float, access::read> velocity [[texture(0)]],
                          texture2d<float, access::read> curlTex [[texture(1)]],
                          texture2d<float, access::write> out [[texture(2)]],
                          constant FluidParams& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, out.get_width(), out.get_height())) return;
        int2 g = int2(gid);
        float L = at(curlTex, g - int2(1, 0)).x, R = at(curlTex, g + int2(1, 0)).x;
        float T = at(curlTex, g + int2(0, 1)).x, B = at(curlTex, g - int2(0, 1)).x;
        float C = at(curlTex, g).x;
        float2 force = 0.5 * float2(abs(T) - abs(B), abs(R) - abs(L));
        force /= length(force) + 0.0001;
        force *= p.curl * C;
        force.y *= -1.0;
        float2 v = at(velocity, g).xy + force * p.dt;
        out.write(float4(clamp(v, -1000.0, 1000.0), 0, 0), gid);
    }

    kernel void divergence(texture2d<float, access::read> velocity [[texture(0)]],
                           texture2d<float, access::write> out [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint w = out.get_width(), h = out.get_height();
        if (outside(gid, w, h)) return;
        int2 g = int2(gid);
        float2 C = at(velocity, g).xy;
        // Walls reflect the flow back in.
        float L = gid.x == 0 ? -C.x : at(velocity, g - int2(1, 0)).x;
        float R = gid.x + 1 >= w ? -C.x : at(velocity, g + int2(1, 0)).x;
        float B = gid.y == 0 ? -C.y : at(velocity, g - int2(0, 1)).y;
        float T = gid.y + 1 >= h ? -C.y : at(velocity, g + int2(0, 1)).y;
        out.write(float4(0.5 * (R - L + T - B)), gid);
    }

    kernel void clear(texture2d<float, access::write> out [[texture(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, out.get_width(), out.get_height())) return;
        out.write(float4(0), gid);
    }

    kernel void scale(texture2d<float, access::read> source [[texture(0)]],
                      texture2d<float, access::write> out [[texture(1)]],
                      constant FluidParams& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, out.get_width(), out.get_height())) return;
        out.write(source.read(gid) * p.pressureDecay, gid);
    }

    kernel void jacobi(texture2d<float, access::read> pressure [[texture(0)]],
                       texture2d<float, access::read> divergenceTex [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, out.get_width(), out.get_height())) return;
        int2 g = int2(gid);
        float L = at(pressure, g - int2(1, 0)).x, R = at(pressure, g + int2(1, 0)).x;
        float T = at(pressure, g + int2(0, 1)).x, B = at(pressure, g - int2(0, 1)).x;
        out.write(float4((L + R + B + T - at(divergenceTex, g).x) * 0.25), gid);
    }

    kernel void gradientSubtract(texture2d<float, access::read> pressure [[texture(0)]],
                                 texture2d<float, access::read> velocity [[texture(1)]],
                                 texture2d<float, access::write> out [[texture(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, out.get_width(), out.get_height())) return;
        int2 g = int2(gid);
        float L = at(pressure, g - int2(1, 0)).x, R = at(pressure, g + int2(1, 0)).x;
        float T = at(pressure, g + int2(0, 1)).x, B = at(pressure, g - int2(0, 1)).x;
        float2 v = at(velocity, g).xy - float2(R - L, T - B);
        out.write(float4(v, 0, 0), gid);
    }

    kernel void splat(texture2d<float, access::read> source [[texture(0)]],
                      texture2d<float, access::write> out [[texture(1)]],
                      constant FluidParams& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, out.get_width(), out.get_height())) return;
        float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
        float2 d = uv - p.point;
        d.x *= p.aspect;
        out.write(source.read(gid) + exp(-dot(d, d) / p.radius) * p.value, gid);
    }

    // Adds a splat to the colour in place, over only the patch it reaches
    // (dispatched from `origin`), instead of rewriting the whole texture.
    kernel void splatPatch(texture2d<float, access::read_write> dye [[texture(0)]],
                           constant FluidParams& p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 g = gid + p.origin;
        if (outside(g, dye.get_width(), dye.get_height())) return;
        float2 uv = (float2(g) + 0.5) / float2(dye.get_width(), dye.get_height());
        float2 d = uv - p.point;
        d.x *= p.aspect;
        dye.write(dye.read(g) + exp(-dot(d, d) / p.radius) * p.value, g);
    }

    struct DisplayOut { float4 position [[position]]; float2 uv; };

    vertex DisplayOut displayVertex(uint vid [[vertex_id]]) {
        // One triangle covering the screen.
        float2 pos = float2((vid << 1) & 2, vid & 2);
        DisplayOut o;
        o.position = float4(pos * 2.0 - 1.0, 0, 1);
        o.uv = float2(pos.x, 1.0 - pos.y);
        return o;
    }

    fragment float4 displayFragment(DisplayOut in [[stage_in]],
                                    texture2d<float, access::sample> dye [[texture(0)]]) {
        float3 c = max(dye.sample(displaySampler, in.uv).rgb, 0.0);
        // Compress brightness, not each channel: a per-channel curve pulled
        // bright colours towards white and dim ones towards grey (dull).
        float peak = max(c.r, max(c.g, c.b));
        if (peak < 1e-4) return float4(0, 0, 0, 1);
        float mapped = 1.0 - exp(-peak * 2.2);
        c = c / peak * mapped;
        // Vibrance: push colours away from their own grey, more where they're
        // already colourful, so mixed folds stay vivid instead of muddy.
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        float chroma = peak > 0 ? (peak - min(c.r, min(c.g, c.b))) / max(peak, 1e-4) : 0;
        c = max(mix(float3(luma), c, 1.35 + 0.25 * chroma), 0.0);
        return float4(min(c, 1.0), 1.0);
    }
    """
}
