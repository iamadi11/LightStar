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

    struct DisplayParams {
        int look;            // CanvasStyle order: liquid, aura, lava, aurora, ocean, nebula, ink
        float time;          // seconds of drift (slowed by Reduce Motion)
        float2 pad;
        float4 palette[4];   // the animation's first hues as RGB
    };

    // Compress brightness, not each channel: a per-channel curve pulled bright
    // colours towards white and dim ones towards grey (dull). Then vibrance:
    // push colours away from their own grey so mixed folds stay vivid.
    float3 popTone(float3 c, float gain) {
        float peak = max(c.r, max(c.g, c.b));
        if (peak < 1e-4) return float3(0);
        c = c / peak * (1.0 - exp(-peak * gain));
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        float chroma = (peak - min(c.r, min(c.g, c.b))) / peak;
        return clamp(mix(float3(luma), c, 1.35 + 0.25 * chroma), 0.0, 1.0);
    }

    // The colour at full strength: what a thin line or a solid blob shows.
    float3 pure(float3 c) { return c / max(max(c.r, max(c.g, c.b)), 1e-4); }

    float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

    // A fixed star field; each star twinkles slowly on its own beat.
    float stars(float2 uv, float aspect, float density, float time) {
        float2 g = uv * float2(density * aspect, density);
        float2 cell = floor(g);
        float h = hash(cell);
        if (h < 0.93) return 0;
        float2 off = float2(hash(cell + 7.1), hash(cell + 3.3)) * 0.6 + 0.2;
        float r = length(g - cell - off);
        float size = 0.05 + 0.12 * fract(h * 97.0);
        float twinkle = 0.7 + 0.3 * sin(time * (0.4 + 0.8 * fract(h * 31.0)) + h * 60.0);
        return exp(-r * r / (size * size)) * twinkle * (0.4 + 0.6 * fract(h * 13.0));
    }

    // Edges where the colour folds: the bright lines of glowing water.
    float folds(texture2d<float, access::sample> dye, float2 uv) {
        float2 t = 2.0 / float2(dye.get_width(), dye.get_height());
        float3 gx = dye.sample(displaySampler, uv + float2(t.x, 0)).rgb - dye.sample(displaySampler, uv - float2(t.x, 0)).rgb;
        float3 gy = dye.sample(displaySampler, uv + float2(0, t.y)).rgb - dye.sample(displaySampler, uv - float2(0, t.y)).rgb;
        return smoothstep(0.02, 0.25, length(gx) + length(gy));
    }

    fragment float4 displayFragment(DisplayOut in [[stage_in]],
                                    texture2d<float, access::sample> dye [[texture(0)]],
                                    constant DisplayParams &d [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = float(dye.get_width()) / float(dye.get_height());
        float3 a = max(dye.sample(displaySampler, uv).rgb, 0.0);
        float peak = max(a.r, max(a.g, a.b));
        float3 c;
        switch (d.look) {
        case 1: {
            // Aura: the liquid blurred into a soft, slowly shifting gradient.
            float3 soft = max(dye.sample(displaySampler, uv, level(6)).rgb, 0.0)
                        + 0.5 * max(dye.sample(displaySampler, uv, level(4)).rgb, 0.0);
            c = max(popTone(soft, 4.0) * 0.95, d.palette[2].rgb * 0.05);
            break;
        }
        case 2: {
            // Lava lamp: wax blobs rising and sinking, merging where they meet.
            float2 p = float2(uv.x * aspect, uv.y);
            float field = 0;
            float3 col = float3(0);
            for (int i = 0; i < 7; i++) {
                float fi = float(i);
                float h1 = hash(float2(fi, 1.3)), h2 = hash(float2(fi, 7.7)), h3 = hash(float2(fi, 4.1));
                float r = 0.07 + 0.06 * h1;
                float x = (0.15 + 0.7 * h2) * aspect + 0.06 * sin(d.time * 0.07 * (1.0 + h3) + fi * 2.1);
                float y = 0.5 + 0.45 * sin(d.time * (0.05 + 0.04 * h3) + fi * 1.7);
                float2 delta = p - float2(x, y);
                float f = r * r / max(dot(delta, delta), 1e-5);
                field += f;
                col += d.palette[i % 4].rgb * f;
            }
            col /= max(field, 1e-4);
            float inside = smoothstep(0.97, 1.03, field);   // a crisp wax edge
            float shade = 0.6 + 0.4 * smoothstep(1.0, 3.0, field);
            float3 glass = mix(float3(0.03, 0.0, 0.02), float3(0.1, 0.02, 0.04), uv.y);   // lit from below
            c = glass + col * 0.18 * smoothstep(0.4, 0.97, field) + col * inside * shade
              + popTone(a, 1.5) * 0.35 * (1.0 - inside);   // stirs show as warm glow
            break;
        }
        case 3: {
            // Aurora: two curtains hanging from a bright lower edge, in fine rays.
            float3 sky = mix(float3(0.0, 0.01, 0.04), float3(0.01, 0.03, 0.07), uv.y);
            float3 sum = float3(0);
            for (int k = 0; k < 2; k++) {
                float fk = float(k);
                float yc = 0.62 - 0.14 * fk + 0.07 * sin(uv.x * 3.1 + d.time * 0.09 + fk * 2.0)
                         + 0.035 * sin(uv.x * 7.7 - d.time * 0.13 + fk) + 0.015 * sin(uv.x * 17.0 + d.time * 0.21);
                float above = yc - uv.y;
                float curtain = above > 0 ? exp(-above / (0.16 - 0.05 * fk)) : exp(above / 0.012);
                // Uneven rays: three unrelated frequencies, so no regular bars.
                float rays = 0.72 + 0.12 * sin(uv.x * 61.0 + 3.0 * sin(uv.x * 11.0 + d.time * 0.17) + fk * 5.0)
                           + 0.1 * sin(uv.x * 147.3 - d.time * 0.23) + 0.06 * sin(uv.x * 389.7 + d.time * 0.11);
                float3 tint = mix(d.palette[k].rgb, d.palette[3].rgb, smoothstep(0.02, 0.3, above));
                sum += tint * curtain * rays * (1.0 - 0.45 * fk);
            }
            // Stirs and drift add more light, drawn upward like the curtains.
            float3 streak = float3(0);
            float w = 0;
            for (int i = 0; i < 6; i++) {
                float k = float(i) / 5.0;
                streak += max(dye.sample(displaySampler, uv + float2(0, k * 0.12), level(2)).rgb, 0.0) * (1.0 - k);
                w += 1.0 - k;
            }
            c = sky + sum * 0.9 + popTone(streak / w, 2.0) * 0.3 + stars(uv, aspect, 140.0, d.time) * 0.5;
            break;
        }
        case 4: {
            // Ocean glow: bioluminescent edges where the water folds, on a dark sea.
            float3 sea = mix(float3(0.0, 0.015, 0.05), float3(0.0, 0.04, 0.09), uv.y);
            float edge = folds(dye, uv);
            float3 halo = max(dye.sample(displaySampler, uv, level(4)).rgb, 0.0);
            c = sea + pure(a) * edge * smoothstep(0.02, 0.15, peak) * 0.95 + popTone(halo, 1.2) * 0.4
              + float3(0.6, 0.9, 1.0) * edge * edge * 0.2 * smoothstep(0.1, 0.4, peak);
            break;
        }
        case 5: {
            // Nebula: soft clouds over a twinkling star field.
            float3 cloud = max(dye.sample(displaySampler, uv, level(2)).rgb, 0.0);
            float3 neb = popTone(mix(a, cloud, 0.6), 1.4) * 0.8;
            float s = stars(uv, aspect, 120.0, d.time);
            c = float3(0.0, 0.0, 0.015) + neb + float3(0.9, 0.93, 1.0) * s * (1.0 - 0.6 * max(neb.r, max(neb.g, neb.b)));
            break;
        }
        case 6: {
            // Ink: colour soaking into warm paper.
            float ink = 1.0 - exp(-peak * 2.8);
            c = mix(float3(0.97, 0.95, 0.9), pure(a) * 0.8, ink);
            break;
        }
        default:
            // Liquid: paint in water.
            c = popTone(a, 2.2);
        }
        return float4(clamp(c, 0.0, 1.0), 1.0);
    }
    """
}
