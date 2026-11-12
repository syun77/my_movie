#include <metal_stdlib>
using namespace metal;

struct Quad {
    float4 position [[position]];
    float2 uv;
};

constant float2 corners[] = {
    float2(0, 0), float2(0, 1), float2(1, 0), float2(1, 1)
};
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

vertex Quad fullscreen(uint vertexID [[vertex_id]]) {
    float2 uv = corners[vertexID];
    return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
}

fragment float4 imageLayer(Quad in [[stage_in]], texture2d<float> image [[texture(0)]],
                           texture2d<float> glow [[texture(1)]], constant float4 &settings [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * settings.xy + 0.5;
    // Core Image renders with the bottom of its extent in the first texture row.
    uv.y = 1 - uv.y;
    float4 pixel = image.sample(linearSampler, uv);
    if (settings.z > 0) {
        float4 halo = glow.sample(linearSampler, uv) * settings.z;
        pixel.rgb += halo.rgb;
        pixel.a += (1 - pixel.a) * min(halo.a, 1.0);
    }
    return pixel * settings.w;
}

float3 linearFromSRGB(float3 value) {
    return select(value / 12.92, pow((value + 0.055) / 1.055, float3(2.4)), value > 0.04045);
}

fragment float4 artwork(Quad in [[stage_in]], texture2d<float> overlay [[texture(0)]]) {
    float4 pixel = overlay.sample(linearSampler, in.uv);
    if (pixel.a > 0) {
        pixel.rgb = linearFromSRGB(saturate(pixel.rgb / pixel.a)) * pixel.a;
    }
    return pixel;
}

struct Particle {
    float4 position [[position]];
    float2 uv;
    float opacity;
    float index;
};

vertex Particle particleQuad(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                             constant float4 *instances [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
    float4 particle = instances[instanceID];
    float2 uv = corners[vertexID] * 2 - 1;
    float2 position = (particle.xy + uv * (particle.z * 0.5)) / size * 2 - 1;
    return {float4(position.x, -position.y, 0, 1), uv, particle.w, float(instanceID)};
}

fragment float4 particleLight(Particle in [[stage_in]], constant float4 &palette [[buffer(0)]]) {
    float2 uv = in.uv;
    float radius = length(uv);
    float edge = 1 - smoothstep(0.68, 1.0, radius);
    float halo = exp(-7 * radius * radius) * 0.52;
    float core = 1 - smoothstep(0.025, 0.24, radius);
    float2 axes = abs(uv);
    float2 diagonals = abs(float2(uv.x + uv.y, uv.x - uv.y)) * 0.7071;
    float rays = exp(-34 * min(axes.x, axes.y) - 3.2 * max(axes.x, axes.y));
    rays += 0.55 * exp(-37 * min(diagonals.x, diagonals.y) - 4.5 * max(diagonals.x, diagonals.y));

    float3 base = palette.rgb;
    float baseHue = atan2(1.73205 * (base.g - base.b), 2 * base.r - base.g - base.b + 1e-6) / 6.2831853;
    float offset = (fract(in.index * 0.618034) - 0.5) * 0.25;
    float hue = baseHue + palette.w + (in.index < 0.5 ? 0.5 : offset);
    float3 spectrum = saturate(abs(fract(hue + float3(0, 0.666667, 0.333333)) * 6 - 3) - 1);
    float tint = mix(0.45, 0.9, max(base.r, max(base.g, base.b)) - min(base.r, min(base.g, base.b)));
    float3 coloredLight = linearFromSRGB(mix(float3(1), spectrum, tint));
    float gain = in.opacity * edge;
    return float4((coloredLight * (halo + rays * 0.6) + core * 1.2) * gain,
                  saturate((halo + rays + core) * gain));
}

fragment float4 emberLight(Particle in [[stage_in]]) {
    float shape = fract(in.index * 0.618034);
    float angle = mix(-0.72, 0.58, shape);
    float sine = sin(angle), cosine = cos(angle);
    float2 uv = float2(dot(in.uv, float2(cosine, sine)), dot(in.uv, float2(-sine, cosine)));
    float edge = 1 - smoothstep(0.65, 1.0, length(in.uv));
    float core = 1 - smoothstep(0.1, 1.0, length(uv * float2(mix(4.5, 6.2, shape), 2.4)));
    float halo = 1 - smoothstep(0.0, 1.0, length(float2(uv.x * 1.45, uv.y - 0.09)));
    float light = in.opacity * edge;
    float3 warm = mix(float3(0.95, 0.15, 0.015), float3(1.65, 0.64, 0.16), in.opacity);
    float3 glow = float3(0.57, 0.125, 0.012) * halo * halo * halo;
    return float4((warm * core + glow) * light, max(core, halo) * light);
}

fragment float4 snowFlake(Particle in [[stage_in]]) {
    float alpha = (1 - smoothstep(0.0, 1.0, length(in.uv))) * in.opacity;
    return float4(alpha);
}

fragment float4 orbLight(Particle in [[stage_in]], constant float3 *colors [[buffer(0)]],
                         constant float &saturation [[buffer(1)]]) {
    const float coreRadius = 0.2;
    float radius = length(in.uv);
    float glow = coreRadius / max(radius, coreRadius);
    float alpha = in.opacity * glow * (1 - smoothstep(coreRadius, 1.0, radius));
    float3 color = linearFromSRGB(colors[uint(in.index)] * 1.5);
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luminance), color, saturation);
    return float4(color * alpha, alpha);
}

fragment float4 outputColor(Quad in [[stage_in]], texture2d<float> scene [[texture(0)]],
                            constant uint &video [[buffer(0)]]) {
    float3 rgb = saturate(scene.sample(linearSampler, in.uv).rgb);
    if (video) {
        rgb = select(rgb * 4.5, 1.099 * pow(rgb, float3(0.45)) - 0.099, rgb >= 0.018);
    } else {
        rgb = select(rgb * 12.92, 1.055 * pow(rgb, float3(1.0 / 2.4)) - 0.055, rgb > 0.0031308);
    }
    return float4(rgb, 1);
}

kernel void bloomHighlights(texture2d<float, access::read> image [[texture(0)]],
                            texture2d<float, access::write> emission [[texture(1)]],
                            constant float &threshold [[buffer(0)]], uint2 point [[thread_position_in_grid]]) {
    if (point.x >= image.get_width() || point.y >= image.get_height()) return;
    float4 pixel = image.read(point);
    float3 color = pixel.rgb / max(pixel.a, 1e-6);
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float mask = saturate((luma - threshold) / (1 - threshold)) * pixel.a;
    emission.write(float4(color * mask, mask), point);
}

struct Placement {
    float2 origin;
    float2 horizontal;
    float2 vertical;
    float2 targetSize;
};

vertex Quad positionedImage(uint vertexID [[vertex_id]], constant Placement &placement [[buffer(0)]]) {
    float2 uv = corners[vertexID];
    float2 pixel = placement.origin + placement.horizontal * uv.x + placement.vertical * uv.y;
    float2 position = pixel / placement.targetSize * 2 - 1;
    return {float4(position.x, -position.y, 0, 1), uv};
}

fragment float4 sourceImage(Quad in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    return source.sample(linearSampler, in.uv);
}
