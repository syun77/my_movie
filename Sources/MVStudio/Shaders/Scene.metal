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


struct ShapeUniforms {
    float4 geometry;
    float4 details;
    float4 color;
    float4 viewport;
    float4 mask;
};

float2 shapeVertex(int i, int count, constant ShapeUniforms &shape) {
    float2 unit;
    if (int(shape.details.y) == 1) {
        unit = i == 0 ? float2(0, -1) : (i == 1 ? float2(1, 1) : float2(-1, 1));
    } else {
        float angle = -M_PI_F / 2 + float(i) * 2 * M_PI_F / float(count);
        float radius = i % 2 == 0 ? 1 : shape.details.w;
        unit = float2(cos(angle), sin(angle)) * radius;
    }
    return unit * shape.geometry.zw * 0.5;
}

float shapeDistance(float2 point, constant ShapeUniforms &shape) {
    float2 p = point - shape.geometry.xy;
    float c = cos(shape.details.x), s = sin(shape.details.x);
    p = float2(c * p.x + s * p.y, -s * p.x + c * p.y);
    float2 halfSize = shape.geometry.zw * 0.5;
    int kind = int(shape.details.y);
    if (kind == 0) {
        float2 d = abs(p) - halfSize;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    }
    if (kind == 2) {
        float2 q = p / halfSize;
        float k = length(q);
        return k < 1e-6 ? -min(halfSize.x, halfSize.y) : (k - 1) / length(q / halfSize);
    }
    int count = kind == 1 ? 3 : int(shape.details.z) * 2;
    float distanceSquared = 1e20;
    bool inside = false;
    float2 a = shapeVertex(count - 1, count, shape);
    for (int i = 0; i < count; ++i) {
        float2 b = shapeVertex(i, count, shape);
        float2 edge = b - a;
        float2 nearest = a + edge * clamp(dot(p - a, edge) / max(dot(edge, edge), 1e-10), 0.0, 1.0);
        distanceSquared = min(distanceSquared, dot(p - nearest, p - nearest));
        if ((a.y > p.y) != (b.y > p.y)) {
            float crossing = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x;
            if (p.x < crossing) inside = !inside;
        }
        a = b;
    }
    return sqrt(distanceSquared) * (inside ? -1 : 1);
}

float shapeCoverage(float2 point, constant ShapeUniforms &shape, float feather) {
    if (shape.geometry.z <= 0 || shape.geometry.w <= 0) return 0;
    float distance = shapeDistance(point, shape);
    float transition = max(fwidth(distance), 0.001) + feather;
    return 1 - smoothstep(-transition * 0.5, transition * 0.5, distance);
}

float maskFactor(float2 point, constant ShapeUniforms &shape) {
    if (shape.mask.w == 0 || shape.mask.z == 0) return 1;
    float coverage = shapeCoverage(point, shape, shape.mask.y);
    if (shape.mask.x != 0) coverage = 1 - coverage;
    return mix(1.0, coverage, shape.mask.z);
}

fragment float4 coloredShape(Quad in [[stage_in]], constant ShapeUniforms &shape [[buffer(0)]]) {
    float2 point = (float2(in.uv.x, 1 - in.uv.y) * shape.viewport.xy - shape.viewport.z) / shape.viewport.w;
    float alpha = shapeCoverage(point, shape, 0) * shape.color.a;
    return float4(shape.color.rgb * alpha, alpha);
}

fragment float4 maskedClip(Quad in [[stage_in]], texture2d<float> image [[texture(0)]],
                           constant ShapeUniforms &shape [[buffer(0)]]) {
    return image.sample(linearSampler, in.uv) * maskFactor(in.uv * float2(1920, 1080), shape);
}

fragment float4 maskGuide(Quad in [[stage_in]], constant ShapeUniforms &shape [[buffer(0)]]) {
    if (shape.geometry.z <= 0 || shape.geometry.w <= 0) return 0;
    float d = shapeDistance(in.uv * float2(1920, 1080), shape);
    float alpha = 1 - smoothstep(1.0, 3.0, abs(d));
    return float4(float3(0.15, 0.7, 1) * alpha, alpha);
}

fragment float4 imageLayer(Quad in [[stage_in]], texture2d<float> image [[texture(0)]],
                           texture2d<float> glow [[texture(1)]], constant float4 &settings [[buffer(0)]], constant ShapeUniforms &mask [[buffer(1)]]) {
    float2 uv = (in.uv - 0.5) * settings.xy + 0.5;
    // Core Image renders with the bottom of its extent in the first texture row.
    uv.y = 1 - uv.y;
    float4 pixel = image.sample(linearSampler, uv);
    if (settings.z > 0) {
        float4 halo = glow.sample(linearSampler, uv) * settings.z;
        pixel.rgb += halo.rgb;
        pixel.a += (1 - pixel.a) * min(halo.a, 1.0);
    }
    return pixel * settings.w * maskFactor(in.uv * float2(1920, 1080), mask);
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

struct SpineVertex { float x, y, u, v, r, g, b, a; };
struct SpineRaster { float4 position [[position]]; float2 uv; float4 color; };
vertex SpineRaster spineVertex(uint id [[vertex_id]], device const SpineVertex *vertices [[buffer(0)]], constant float4 &bounds [[buffer(1)]]) {
    SpineVertex v = vertices[id];
    float2 p = (float2(v.x, v.y) - bounds.xy) / bounds.zw;
    return {float4(p.x * 2 - 1, p.y * 2 - 1, 0, 1), float2(v.u, v.v), float4(v.r, v.g, v.b, v.a)};
}
fragment float4 spineFragment(SpineRaster in [[stage_in]], texture2d<float> page [[texture(0)]], sampler sampling [[sampler(0)]], constant uint &pma [[buffer(0)]]) {
    float4 pixel = page.sample(sampling, in.uv);
    float3 rgb = pma ? (pixel.a > 0 ? saturate(pixel.rgb / pixel.a) : float3(0)) : pixel.rgb;
    float alpha = pixel.a * in.color.a;
    return float4(linearFromSRGB(saturate(rgb * in.color.rgb)) * alpha, alpha);
}
