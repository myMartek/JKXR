#include <metal_stdlib>
using namespace metal;

// Referenzdreieck, gegen das später das ANGLE-gerenderte Bild verglichen wird.
// Bewusst minimal: wenn hier etwas nicht stimmt, liegt es an der
// CompositorServices-Anbindung und nicht an GLES-Übersetzung.

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

struct Uniforms {
    float4x4 modelViewProjection;
};

// `amplification_id` wählt das Auge aus. Ohne diesen Parameter bekämen beide
// Augen dieselbe Matrix — das Bild wäre da, aber ohne jede Stereo-Wirkung.
vertex VertexOut triangle_vertex(uint vid [[vertex_id]],
                                 ushort ampID [[amplification_id]],
                                 constant Uniforms *uniforms [[buffer(0)]]) {
    // Positionen im Modellraum. Wo das Dreieck im Raum landet, bestimmt
    // ausschließlich die Matrix — hier steht bewusst keine Annahme über die
    // Blickrichtung mehr drin.
    const float3 positions[3] = {
        float3(-0.3, -0.3, 0.0),
        float3( 0.3, -0.3, 0.0),
        float3( 0.0,  0.3, 0.0),
    };
    const float3 colors[3] = {
        float3(1.0, 0.2, 0.2),
        float3(0.2, 1.0, 0.3),
        float3(0.3, 0.4, 1.0),
    };

    VertexOut out;
    out.position = uniforms[ampID].modelViewProjection * float4(positions[vid], 1.0);
    out.color = colors[vid];
    return out;
}

fragment float4 triangle_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}

// Blit-Pfad: zeichnet eine von ANGLE befüllte Textur bildschirmfüllend.
// Damit lässt sich die GLES-Ausgabe in dieselbe Drawable bringen, ohne den
// restlichen Renderpfad zu ändern.

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadOut blit_vertex(uint vid [[vertex_id]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0),
    };
    QuadOut out;
    out.position = float4(corners[vid], 0.0, 1.0);
    out.uv = corners[vid] * float2(0.5, -0.5) + 0.5;
    return out;
}

fragment float4 blit_fragment(QuadOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return src.sample(s, in.uv);
}

// Bildschirmfüllender Hintergrund, knapp vor der fernen Ebene.
//
// Prüft, ob der Compositor Farbe nur dort zeigt, wo Tiefe *ungleich dem
// Clear-Wert* steht. Der erste Anlauf nutzte blit_vertex mit z = 0.0 — bei
// Reversed-Z genau der Wert, auf den der Tiefenpuffer geleert wird. Der
// Hintergrund schrieb damit dieselbe Tiefe, die schon dastand, und konnte
// nichts beweisen.
//
// 1e-4 entspricht einer sehr großen, aber endlichen Entfernung: weit hinter
// allem anderen, aber unterscheidbar von "unendlich weit weg".
vertex QuadOut background_vertex(uint vid [[vertex_id]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0),
    };
    QuadOut out;
    out.position = float4(corners[vid], 1e-4, 1.0);
    out.uv = corners[vid] * float2(0.5, -0.5) + 0.5;
    return out;
}

fragment float4 background_fragment(QuadOut in [[stage_in]]) {
    return float4(0.0, 0.25, 0.35, 1.0);
}
