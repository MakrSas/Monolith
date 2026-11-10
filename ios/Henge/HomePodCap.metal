#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// vphone's HomePod top cap (VPhoneHomePodShader's capFragment), as a SwiftUI colour effect. `leds` holds
// count × (x, y, r, g, b): position in the cap's unit square (y down), linear colour. The result is
// encoded to sRGB here, where vphone's sRGB render target does it.

static float stroke(float2 p, float2 center, bool plus, float aa) {
    float2 q = abs(p - center);
    float horizontal = max(q.x - 0.052, q.y - 0.0026);
    float vertical = max(q.x - 0.0026, q.y - 0.052);
    return 1.0 - smoothstep(-aa, aa, plus ? min(horizontal, vertical) : horizontal);
}

static float3 encode(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

[[stitchable]] half4 homePodCap(float2 position, half4 color, float4 box, device const float *leds, int ledsCount,
                                float plusLight, float minusLight) {
    // box: cap centre x/y and radius, in the view's points
    float radius = max(box.z, 1.0);
    float2 p = (position - box.xy) / (radius * 2.0) + 0.5;
    float r = length(p - 0.5) * 2.0;
    float aa = 0.65 / radius;
    const float3 background = float3(0.0044);
    if (r > 1.0 + aa * 2.0) return half4(half3(encode(background)), 1);
    float3 light = 0;
    float weightSum = 0;
    int count = ledsCount / 5;
    for (int i = 0; i < count; ++i) {
        float2 d = p - float2(leds[i * 5], leds[i * 5 + 1]);
        float d2 = dot(d, d);
        float weight = 0.86 * exp(-d2 / (2.0 * 0.155 * 0.155))
                     + 0.14 * exp(-d2 / (2.0 * 0.29 * 0.29));
        light += float3(leds[i * 5 + 2], leds[i * 5 + 3], leds[i * 5 + 4]) * weight;
        weightSum += weight;
    }
    light /= max(weightSum, 0.001);
    float edge = 1.0 - smoothstep(0.70, 0.985, r);
    light *= edge * 1.55;
    light = light / (1.0 + 0.45 * light);
    float glass = 0.0014 + 0.0015 * pow(max(0.0, 1.0 - r * r), 3.0);
    float reflection = 0.0022 * exp(-dot(p - float2(0.38, 0.24), p - float2(0.38, 0.24)) / 0.12);
    float3 surface = light + glass + reflection;
    float minus = stroke(p, float2(0.20, 0.5), false, aa * 0.5);
    float plus = stroke(p, float2(0.80, 0.5), true, aa * 0.5);
    surface = mix(surface, float3(0.006) + surface * 0.12, max(minus, plus));
    surface += float3(minus * minusLight + plus * plusLight) * 0.9;
    float rim = exp(-pow((r - 0.992) / max(aa * 1.7, 0.002), 2.0));
    surface += rim * 0.012;
    float cover = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);
    return half4(half3(encode(mix(background, surface, cover))), 1);
}
