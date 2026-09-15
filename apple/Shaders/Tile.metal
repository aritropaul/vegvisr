//  Tile.metal
//  One textured quad per visible tile, plus flat symbology for markers.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
};

struct TileVertexIn {
    float2 position [[attribute(0)]];   // unit quad, (0,0)..(1,1)
    float2 uv       [[attribute(1)]];
};

struct TileVertexOut {
    float4 position [[position]];
    float2 uv;
    float  fade;
};

struct TileInstance {
    float4 rect;    // x, y, w, h in world units
    float4 uvRect;  // u, v, du, dv — the part of the texture this quad shows
    float  fade;    // 1 = crisp tile, <1 = coarse ancestor showing through
    float  _pad0, _pad1, _pad2;
};

vertex TileVertexOut tile_vertex(TileVertexIn in [[stage_in]],
                                  constant Uniforms &u [[buffer(1)]],
                                  constant TileInstance &inst [[buffer(2)]])
{
    TileVertexOut out;
    float2 world = inst.rect.xy + in.position * inst.rect.zw;
    out.position = u.viewProjection * float4(world, 0.0, 1.0);
    // A tile normally shows its whole texture, but a coarse ancestor standing
    // in for a missing tile must show only the quarter (or sixteenth) of itself
    // that covers this ground. Drawing all of it squashed into one tile's rect
    // puts visibly wrong terrain on screen until the real tile lands.
    out.uv = inst.uvRect.xy + in.uv * inst.uvRect.zw;
    out.fade = inst.fade;
    return out;
}

fragment float4 tile_fragment(TileVertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler samp [[sampler(0)]])
{
    float4 c = tex.sample(samp, in.uv);
    return float4(c.rgb, c.a * in.fade);
}

// --- markers ----------------------------------------------------------------
//
// One textured quad per marker. The symbology is rasterised on the CPU from the
// same paths the web build draws — a dark halo, a translucent dark fill and a
// thin coloured stroke — because an outline glyph is not something a signed
// distance field reproduces honestly.

struct MarkerInstance {
    float2 world;
    float  sizePx;     // quad side in points
    float  _pad;
};

struct MarkerVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex MarkerVertexOut marker_vertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      constant Uniforms &u [[buffer(1)]],
                                      constant MarkerInstance *inst [[buffer(2)]],
                                      constant float2 &viewportPx [[buffer(3)]])
{
    float2 corner = float2(float(vid & 1u), float(vid >> 1u));
    MarkerInstance m = inst[iid];

    float4 clip = u.viewProjection * float4(m.world, 0.0, 1.0);
    float2 offsetPx = (corner - 0.5) * m.sizePx;
    float2 ndc = offsetPx / viewportPx * 2.0 * clip.w;

    MarkerVertexOut out;
    out.position = clip + float4(ndc, 0.0, 0.0);
    // The glyph context is flipped to y-down at rasterisation time, and a
    // CGContext's first row is the visual bottom — which is also v=0. So the
    // quad's corner maps straight through.
    out.uv = corner;
    return out;
}

fragment float4 marker_fragment(MarkerVertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler samp [[sampler(0)]])
{
    float4 c = tex.sample(samp, in.uv);
    if (c.a <= 0.002) discard_fragment();
    return c;
}

