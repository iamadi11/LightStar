/// Metal source for the Canvas's picture, compiled at run time like the
/// fluid's (`swift test` covers it). One frame: particles ride the flow into a
/// fading trail buffer; the scene pass draws the animation's look over them
/// at the colour texture's size; a bloom chain makes bright colour glow; the
/// final pass adds the glow, rolls off highlights (into EDR headroom when the
/// screen has it), and adds film grain. The lights read the scene's mipmaps,
/// so sparkle and grain never reach the room.
enum CanvasShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    constexpr sampler displaySampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

    struct DisplayOut { float4 position [[position]]; float2 uv; };

    vertex DisplayOut displayVertex(uint vid [[vertex_id]]) {
        // One triangle covering the target.
        float2 pos = float2((vid << 1) & 2, vid & 2);
        DisplayOut o;
        o.position = float4(pos * 2.0 - 1.0, 0, 1);
        o.uv = float2(pos.x, 1.0 - pos.y);
        return o;
    }

    struct DisplayParams {
        int look;            // CanvasStyle order: liquid, aura, lava, aurora, ocean, nebula, ink
        float time;          // seconds of drift (slowed by Reduce Motion)
        float trailGain;     // how strongly the particle trails show
        float wet;           // liquid-glass shading amount
        float exposure;      // breathing, music pulse, wind-down dimming
        float pad0;
        float2 pad1;
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

    uint pcg(uint v) {
        uint state = v * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }
    float rnd(uint v) { return float(pcg(v)) * (1.0 / 4294967295.0); }

    // Liquid glass: light from the upper left on a surface whose height is
    // the colour's strength, with a thin-film tint on the brightest glints.
    float3 wetShade(float3 c, texture2d<float, access::sample> dye, float2 uv, float amount) {
        if (amount <= 0) return c;
        // Broad bumps (a coarse mip) plus fine ripples, so whole folds catch the light.
        float2 t = 6.0 / float2(dye.get_width(), dye.get_height());
        float l = length(dye.sample(displaySampler, uv - float2(t.x, 0), level(2.5)).rgb);
        float r = length(dye.sample(displaySampler, uv + float2(t.x, 0), level(2.5)).rgb);
        float u = length(dye.sample(displaySampler, uv - float2(0, t.y), level(2.5)).rgb);
        float b = length(dye.sample(displaySampler, uv + float2(0, t.y), level(2.5)).rgb);
        float3 n = normalize(float3(l - r, u - b, 0.22));
        float3 light = normalize(float3(-0.45, 0.55, 0.7));
        float diffuse = clamp(dot(n, light) + 0.5, 0.7, 1.08);
        float3 h = normalize(light + float3(0, 0, 1));
        float spec = pow(max(dot(n, h), 0.0), 42.0);
        float ndv = n.z;
        float3 film = 0.5 + 0.5 * cos(6.2831 * (float3(0.0, 0.33, 0.67) + 1.6 * ndv));
        float presence = smoothstep(0.03, 0.25, max(c.r, max(c.g, c.b)));
        return c * mix(1.0, diffuse, amount) + spec * mix(float3(1.0), film, 0.45) * 0.85 * amount * presence;
    }

    float3 lookColour(texture2d<float, access::sample> dye, float2 uv, constant DisplayParams &d) {
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
        return c;
    }

    // The look, its liquid-glass shading and the particle trails, at the
    // colour texture's own size. Values may pass 1 (glints, trails): the
    // final pass rolls them off.
    fragment float4 sceneFragment(DisplayOut in [[stage_in]],
                                  texture2d<float, access::sample> dye [[texture(0)]],
                                  texture2d<float, access::sample> trail [[texture(1)]],
                                  constant DisplayParams &d [[buffer(0)]]) {
        float3 c = lookColour(dye, in.uv, d);
        c = wetShade(c, dye, in.uv, d.wet);
        float3 tr = max(trail.sample(linearClamp, in.uv).rgb, 0.0);
        if (d.look == 6) {
            // Ink: the particles are fine flecks of ink settling on the paper.
            c *= 1.0 - min(dot(tr, float3(0.3, 0.5, 0.2)) * d.trailGain, 0.55);
        } else {
            c += tr * d.trailGain;
        }
        return float4(max(c * d.exposure, 0.0), 1.0);
    }

    // MARK: particles

    struct Particle { float2 pos; float age; float life; };

    struct ParticleParams {
        float2 simTexel;     // velocity is in cells per second
        float dt;
        float time;
        float curlNoise;     // extra swirl, canvas-heights per second
        float drift;         // steady rise (negative = up), canvas-heights per second
        float aspect;
        uint count;
        uint frame;
        float lifeMin;
        float lifeMax;
        float speed;
        float4 burst;        // x, y, radius, >0 = respawn some particles there this frame
    };

    float2 curlAt(float2 p, float t) {
        // Curl of a smooth potential: divergence-free, so it swirls without clumping.
        float e = 0.01;
        float2 q = p * float2(3.0, 3.0);
        #define PSI(x, y) (sin((x) * 1.7 + t * 0.21) * cos((y) * 1.3 - t * 0.17) + 0.5 * sin((x) * 3.9 - (y) * 2.3 + t * 0.31))
        float dx = (PSI(q.x + e, q.y) - PSI(q.x - e, q.y)) / (2.0 * e);
        float dy = (PSI(q.x, q.y + e) - PSI(q.x, q.y - e)) / (2.0 * e);
        #undef PSI
        return float2(dy, -dx);
    }

    kernel void particleUpdate(device Particle* particles [[buffer(0)]],
                               constant ParticleParams& p [[buffer(1)]],
                               texture2d<float, access::sample> velocity [[texture(0)]],
                               uint id [[thread_position_in_grid]]) {
        if (id >= p.count) return;
        Particle q = particles[id];
        q.age += p.dt;
        float2 v = velocity.sample(linearClamp, q.pos).xy * p.simTexel;
        float2 swirl = curlAt(float2(q.pos.x * p.aspect, q.pos.y), p.time) * p.curlNoise;
        swirl.x /= p.aspect;
        q.pos += (v * p.speed + swirl + float2(0, p.drift)) * p.dt;
        uint seed = id * 9781u + p.frame * 6271u;
        bool burstHere = p.burst.w > 0 && (id & 7u) == 0u;
        if (burstHere || q.age > q.life || any(q.pos < 0.0) || any(q.pos > 1.0)) {
            if (burstHere) {
                float a = rnd(seed) * 6.2831, r = sqrt(rnd(seed + 1u)) * p.burst.z;
                q.pos = p.burst.xy + float2(cos(a) * r / p.aspect, sin(a) * r);
            } else {
                q.pos = float2(rnd(seed), rnd(seed + 1u));
            }
            q.age = 0;
            q.life = mix(p.lifeMin, p.lifeMax, rnd(seed + 2u));
        }
        particles[id] = q;
    }

    struct PointParams { float intensity; float size; float whiten; float pad; };
    struct PointOut { float4 position [[position]]; float size [[point_size]]; float4 color; };

    vertex PointOut particleVertex(uint vid [[vertex_id]],
                                   const device Particle* particles [[buffer(0)]],
                                   constant PointParams& pp [[buffer(1)]],
                                   texture2d<float, access::sample> dye [[texture(0)]]) {
        Particle q = particles[vid];
        float3 c = max(dye.sample(displaySampler, q.pos, level(1.0)).rgb, 0.0);
        float peak = max(c.r, max(c.g, c.b));
        // The colour under it at full strength, shown only where there is colour.
        float3 col = mix(c / max(peak, 1e-3), float3(1.0), pp.whiten) * smoothstep(0.04, 0.5, peak);
        float fade = smoothstep(0.0, 0.4, q.age) * (1.0 - smoothstep(q.life - 0.8, q.life, q.age));
        PointOut o;
        o.position = float4(q.pos.x * 2.0 - 1.0, 1.0 - q.pos.y * 2.0, 0, 1);
        o.size = pp.size;
        o.color = float4(col * fade * pp.intensity, 1.0);
        return o;
    }

    fragment float4 particleFragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
        float r = length(pc - 0.5) * 2.0;
        return in.color * saturate(1.0 - r * r);
    }

    struct TrailParams { float2 simTexel; float dt; float decay; };

    // Trails fade and drift with the flow, so particle tracks become silk.
    kernel void trailFade(texture2d<float, access::sample> trail [[texture(0)]],
                          texture2d<float, access::sample> velocity [[texture(1)]],
                          texture2d<float, access::write> out [[texture(2)]],
                          constant TrailParams& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
        float2 back = uv - p.dt * velocity.sample(linearClamp, uv).xy * p.simTexel;
        out.write(trail.sample(linearClamp, back) * p.decay, gid);
    }

    // MARK: bloom (dual-filter down/up chain with a soft-knee threshold)

    struct BloomParams { float2 texel; float threshold; float knee; };

    fragment float4 bloomPrefilter(DisplayOut in [[stage_in]],
                                   texture2d<float, access::sample> src [[texture(0)]],
                                   constant BloomParams& b [[buffer(0)]]) {
        float3 c = max(src.sample(linearClamp, in.uv).rgb, 0.0);
        float bright = max(c.r, max(c.g, c.b));
        float soft = clamp(bright - b.threshold + b.knee, 0.0, 2.0 * b.knee);
        soft = soft * soft / (4.0 * b.knee + 1e-4);
        float contribution = max(soft, bright - b.threshold) / max(bright, 1e-4);
        return float4(c * contribution, 1.0);
    }

    fragment float4 bloomDown(DisplayOut in [[stage_in]],
                              texture2d<float, access::sample> src [[texture(0)]],
                              constant BloomParams& b [[buffer(0)]]) {
        float2 h = b.texel * 0.5, uv = in.uv;
        float3 s = src.sample(linearClamp, uv).rgb * 4.0;
        s += src.sample(linearClamp, uv - h).rgb;
        s += src.sample(linearClamp, uv + h).rgb;
        s += src.sample(linearClamp, uv + float2(h.x, -h.y)).rgb;
        s += src.sample(linearClamp, uv - float2(h.x, -h.y)).rgb;
        return float4(s / 8.0, 1.0);
    }

    fragment float4 bloomUp(DisplayOut in [[stage_in]],
                            texture2d<float, access::sample> src [[texture(0)]],
                            constant BloomParams& b [[buffer(0)]]) {
        float2 h = b.texel * 0.5, uv = in.uv;
        float3 s = src.sample(linearClamp, uv + float2(-h.x * 2.0, 0)).rgb;
        s += src.sample(linearClamp, uv + float2(-h.x, h.y)).rgb * 2.0;
        s += src.sample(linearClamp, uv + float2(0, h.y * 2.0)).rgb;
        s += src.sample(linearClamp, uv + float2(h.x, h.y)).rgb * 2.0;
        s += src.sample(linearClamp, uv + float2(h.x * 2.0, 0)).rgb;
        s += src.sample(linearClamp, uv + float2(h.x, -h.y)).rgb * 2.0;
        s += src.sample(linearClamp, uv + float2(0, -h.y * 2.0)).rgb;
        s += src.sample(linearClamp, uv + float2(-h.x, -h.y)).rgb * 2.0;
        return float4(s / 12.0, 1.0);
    }

    // MARK: final

    struct FinalParams {
        float bloomGain;
        float headroom;      // 1 on SDR; the screen's EDR headroom otherwise
        float grain;
        float time;
        float2 resolution;
        float2 pad;
    };

    fragment float4 finalFragment(DisplayOut in [[stage_in]],
                                  texture2d<float, access::sample> scene [[texture(0)]],
                                  texture2d<float, access::sample> bloom [[texture(1)]],
                                  constant FinalParams& f [[buffer(0)]]) {
        float3 c = max(scene.sample(displaySampler, in.uv).rgb, 0.0);
        c += max(bloom.sample(linearClamp, in.uv).rgb, 0.0) * f.bloomGain;
        // Roll off highlights by the brightest channel, keeping the hue: up to
        // white on SDR, into the extra brightness an HDR screen has.
        float m = max(c.r, max(c.g, c.b));
        float knee = 0.8;
        if (m > knee) {
            float room = max(f.headroom, 1.0) - knee;
            float nm = knee + room * (1.0 - exp(-(m - knee) / room));
            c *= nm / m;
        }
        // Film grain (stronger in the mid-tones) plus triangular dither, so
        // smooth gradients don't band.
        uint2 px = uint2(in.uv * f.resolution);
        uint seed = px.x * 1973u + px.y * 9277u + uint(f.time * 60.0) * 26699u;
        float n = rnd(seed) + rnd(seed ^ 0x9E3779B9u) - 1.0;
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        c += n * (f.grain * (0.35 + luma * (1.0 - min(luma, 1.0)) * 2.0) + 1.0 / 255.0);
        return float4(max(c, 0.0), 1.0);
    }

    // MARK: lights

    struct LightParams { float gain; float white; float warm; float pad; };

    // A 48×27 copy for the room: the scene's mipmaps average each light zone,
    // before glow and grain. Moods can pull it toward white and dim it.
    fragment float4 lightFragment(DisplayOut in [[stage_in]],
                                  texture2d<float, access::sample> scene [[texture(0)]],
                                  constant LightParams& l [[buffer(0)]]) {
        float3 c = max(scene.sample(displaySampler, in.uv).rgb, 0.0);
        float m = max(c.r, max(c.g, c.b));
        if (m > 1.0) c /= m;
        float3 white = l.warm > 0.5 ? float3(1.0, 0.62, 0.3) : float3(1.0, 0.92, 0.82);
        c = mix(c, white * max(m, 0.35), l.white) * l.gain;
        return float4(clamp(c, 0.0, 1.0), 1.0);
    }
    """
}
