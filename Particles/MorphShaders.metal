#include <metal_stdlib>
using namespace metal;

struct MorphPoint {
    float4 place;   // xy rest in the unit box, z cue, w seed
    float4 color;   // straight rgba
};

struct MorphUniforms {
    float2 viewport;    // the canvas, in points
    float2 origin;      // top-left of the unit box, in points
    float  side;        // the box's side, in points
    float  progress;    // 0…1 through the morph
    float  time;
    float  pointSize;   // in points
    float  scale;       // drawable pixels per point
    float  fade;        // the handover to and from the real pictures
    float  spread;      // how far off the straight line a mote is thrown
    float  swirl;       // how far the cloud turns while it is apart, radians
    float  wander;      // how wide each mote swims on its own
};

/// The share of the morph given over to staggering take-off: the last mote
/// leaves this far in, and every mote still lands by the end.
constant float kStagger = 0.22;

static inline float hash(float seed) {
    return fract(sin(seed * 127.1 + 13.7) * 43758.5453);
}

static inline float2 rotate(float2 v, float angle) {
    const float s = sin(angle);
    const float c = cos(angle);
    return float2(v.x * c - v.y * s, v.x * s + v.y * c);
}

/// Out hard and slowing down, then creeping and rushing home: ease-out over
/// the half that comes apart, ease-in over the half that gathers. The two meet
/// at the waist of the flight, where the swarm is at its loosest.
static inline float ease(float t) {
    float shaped;
    if (t < 0.5) {
        const float u = 1.0 - t * 2.0;
        shaped = 0.5 - 0.5 * u * u * u;
    } else {
        const float u = t * 2.0 - 1.0;
        shaped = 0.5 + 0.5 * u * u * u;
    }
    // A thread of plain linear progress mixed back in, so the swarm keeps
    // creeping towards the next picture instead of coming to a dead stop at
    // the waist, where the two eases meet.
    return mix(t, shaped, 0.82);
}

struct MoteOut {
    float4 position [[position]];
    float  size     [[point_size]];
    float4 color    [[user(locn0)]];
};

struct MoteIn {
    float4 position [[position]];
    float4 color    [[user(locn0)]];
};

vertex MoteOut morph_vertex(uint vid [[vertex_id]],
                            device const MorphPoint *from [[buffer(0)]],
                            device const MorphPoint *to [[buffer(1)]],
                            constant MorphUniforms &u [[buffer(2)]])
{
    const MorphPoint a = from[vid];
    const MorphPoint b = to[vid];

    const float cue = a.place.z;
    const float seed = a.place.w;
    const float h1 = hash(seed);
    const float h2 = hash(seed + 1.3);
    const float h3 = hash(seed + 2.7);

    const float t = saturate((u.progress - cue * kStagger) / (1.0 - kStagger));
    const float e = ease(t);

    // Each mote travels a bowed path whose waist is pushed off the straight
    // line between its two homes — so the picture bursts apart before it
    // gathers again, rather than sliding mote by mote into the next one.
    const float2 middle = float2(0.5, 0.5);
    const float2 waist = (a.place.xy + b.place.xy) * 0.5;
    float2 away = waist - middle;
    const float span = length(away);
    away = span > 1e-3 ? away / span : float2(0.0, -1.0);

    // Every mote takes its own bearing, leaning outwards without being bound
    // to it, and most of them barely leave the middle while a few carry much
    // further. A clean radial shove would blow the swarm into a ring with a
    // hole punched through it; this keeps it a cloud.
    const float bearing = h1 * 6.2831853;
    const float2 blend = mix(float2(cos(bearing), sin(bearing)), away, 0.32);
    const float2 heading = blend / max(length(blend), 1e-3);
    const float2 control = waist + heading * (0.14 + u.spread * h2 * h2);

    const float inverse = 1.0 - e;
    float2 place = inverse * inverse * a.place.xy
        + 2.0 * inverse * e * control
        + e * e * b.place.xy;

    // Nothing hangs still while it is apart: the whole cloud turns on the way
    // out and unwinds on the way back, and every mote swims its own small
    // circle at its own pace. Both are tied to `loose`, so they are spent by
    // the time the motes reach either picture and neither one is blurred.
    const float loose = sin(e * M_PI_F);
    place = middle + rotate(place - middle, u.swirl * loose);

    const float swim = u.time * (1.4 + 1.6 * h3) + seed * 6.2831853;
    place += float2(cos(swim), sin(swim * 1.07 + 1.7)) * u.wander * loose;

    // The mote holds the colour it was lifted from well into the crossing,
    // then repaints itself over a short stretch and arrives in the colour of
    // its new place — rather than spending the whole flight as a wash halfway
    // between the two pictures.
    float4 color = mix(a.color, b.color, smoothstep(0.42, 0.74, e));
    // Near-white motes would be lost against the white screen while they are
    // off the picture, so the brightest of them are shaded a little in flight.
    const float lum = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb *= 1.0 - loose * 0.30 * smoothstep(0.5, 1.0, lum);

    const float2 point = u.origin + place * u.side;

    MoteOut out;
    out.position = float4(point.x / u.viewport.x * 2.0 - 1.0,
                          1.0 - point.y / u.viewport.y * 2.0,
                          0.0,
                          1.0);
    out.size = max(u.pointSize * u.scale * (0.78 + 0.5 * h3) * mix(1.0, 1.35, loose), 1.0);
    out.color = float4(color.rgb, color.a * u.fade);
    return out;
}

fragment float4 morph_fragment(MoteIn in [[stage_in]],
                               float2 coord [[point_coord]])
{
    const float d = length(coord - 0.5) * 2.0;
    const float mask = 1.0 - smoothstep(0.42, 1.0, d);
    const float alpha = in.color.a * mask;
    if (alpha <= 0.002) {
        discard_fragment();
    }
    // Premultiplied, to match the pipeline's blend factors.
    return float4(in.color.rgb * alpha, alpha);
}
