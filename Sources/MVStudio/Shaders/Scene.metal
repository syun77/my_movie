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

float4 sampleImageLayer(float2 point, texture2d<float> image, texture2d<float> glow, texture2d<float> glare, constant float &glareIntensity, constant float4 &settings) {
    float2 uv = (point - 0.5) * settings.xy + 0.5;
    // Core Image stores the bottom of its extent in the first texture row.
    uv.y = 1 - uv.y;
    constexpr sampler transparentSampler(coord::normalized, address::clamp_to_zero, filter::linear);
    float4 pixel = image.sample(transparentSampler, uv);
    if (settings.z > 0) {
        float4 halo = glow.sample(transparentSampler, uv) * settings.z;
        pixel.rgb += halo.rgb;
        pixel.a += (1 - pixel.a) * min(halo.a, 1.0);
    }
    if (glareIntensity > 0) {
        float4 rays = glare.sample(transparentSampler, uv) * glareIntensity;
        pixel.rgb += rays.rgb;
        pixel.a += (1 - pixel.a) * saturate(rays.a);
    }
    return pixel;
}

fragment float4 imageLayer(Quad in [[stage_in]], texture2d<float> image [[texture(0)]],
                           texture2d<float> glare [[texture(2)]], constant float &glareIntensity [[buffer(4)]],
                           texture2d<float> glow [[texture(1)]], constant float4 &settings [[buffer(0)]], constant ShapeUniforms &mask [[buffer(1)]]) {
    return sampleImageLayer(in.uv, image, glow, glare, glareIntensity, settings) * settings.w * maskFactor(in.uv * float2(1920, 1080), mask);
}

float2 zoomLoopPoint(float2 point, float2 center, float scale, float angle) {
    float2 p = (point - center) * float2(1920, 1080);
    float c = cos(angle), s = sin(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y) * scale / float2(1920, 1080) + center;
}

fragment float4 zoomLoopImage(Quad in [[stage_in]], texture2d<float> image [[texture(0)]],
                              texture2d<float> glare [[texture(2)]], constant float &glareIntensity [[buffer(4)]],
                           texture2d<float> glow [[texture(1)]], constant float4 &settings [[buffer(0)]],
                              constant ShapeUniforms &mask [[buffer(1)]], constant float4 &animation [[buffer(2)]],
                              constant float2 &center [[buffer(3)]]) {
    float phase = fract(animation.x * 0.3);
    float2 point = zoomLoopPoint(in.uv, center, exp(-phase * 3.7) / animation.y, -0.5 * phase);
    float2 next = zoomLoopPoint(point, center, exp(3.7), 0.5);
    float4 animated = mix(sampleImageLayer(point, image, glow, glare, glareIntensity, settings), sampleImageLayer(next, image, glow, glare, glareIntensity, settings), phase);
    animated.rgb *= animation.z;
    float4 pixel = mix(sampleImageLayer(in.uv, image, glow, glare, glareIntensity, settings), animated, animation.w);
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

// Frame-independent noise is shared by RGB and applied in output code values.
float outputDither(uint2 pixel) {
    uint hash = pixel.x * 0x9e3779b9u ^ pixel.y * 0x85ebca6bu ^ 0x68bc21ebu;
    hash ^= hash >> 16;
    hash *= 0x7feb352du;
    hash ^= hash >> 15;
    hash *= 0x846ca68bu;
    hash ^= hash >> 16;
    return float(hash >> 8) * (1.0 / 16777216.0) - 0.5;
}

fragment float4 outputColor(Quad in [[stage_in]], texture2d<float> scene [[texture(0)]],
                            constant uint &video [[buffer(0)]]) {
    float3 rgb = saturate(scene.sample(linearSampler, in.uv).rgb);
    if (video) {
        rgb = select(rgb * 4.5, 1.099 * pow(rgb, float3(0.45)) - 0.099, rgb >= 0.018);
    } else {
        rgb = select(rgb * 12.92, 1.055 * pow(rgb, float3(1.0 / 2.4)) - 0.055, rgb > 0.0031308);
    }
    float3 amplitude = min(float3(1.0 / 255.0), 2.0 * min(rgb, 1.0 - rgb));
    rgb += outputDither(uint2(in.position.xy)) * amplitude;
    return float4(saturate(rgb), 1);
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

struct FocusLine { float4 axis; float4 shape; };
struct FocusVertex {
    float4 position [[position]];
    float2 local;
    float3 shape [[flat]];
    float2 canvasPoint;
};
vertex FocusVertex focusQuad(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                            const device FocusLine *lines [[buffer(0)]], constant float4 &viewport [[buffer(1)]]) {
    FocusLine line = lines[instanceID];
    float padding = 2 / viewport.z;
    float2 uv = corners[vertexID];
    float2 local = float2(mix(line.shape.x - padding, line.shape.y + padding, uv.x),
                          mix(-line.shape.z - padding, line.shape.z + padding, uv.y));
    float2 direction = line.axis.zw;
    float2 point = (line.axis.xy + direction * local.x + float2(-direction.y, direction.x) * local.y) * viewport.z;
    return {float4(point.x / viewport.x * 2 - 1, 1 - point.y / viewport.y * 2, 0, 1), local, line.shape.xyz, point / viewport.z};
}
fragment float4 focusInk(FocusVertex in [[stage_in]], constant float4 &ink [[buffer(0)]], constant float4 &gap [[buffer(1)]]) {
    float slope = in.shape.z / (in.shape.y - in.shape.x);
    float side = ((in.local.x - in.shape.x) * slope - abs(in.local.y)) / sqrt(1 + slope * slope);
    float distance = min(side, min(in.local.x - in.shape.x, in.shape.y - in.local.x));
    float coverage = smoothstep(-0.5 * fwidth(distance), max(0.5 * fwidth(distance), 0.0001), distance);
    if (gap.z > 0 && gap.w > 0) {
        float radius = length((in.canvasPoint - gap.xy) / gap.zw);
        coverage *= smoothstep(1.0, 1.0 + max(fwidth(radius), 0.0001), radius);
    }
    float alpha = ink.a * coverage;
    return float4(linearFromSRGB(ink.rgb) * alpha, alpha);
}

struct SharpLine { float4 axis; float4 shape; float4 opacityScale; };
struct SharpVertex {
    float4 position [[position]];
    float2 local;
    float4 shape [[flat]];
    float opacityScale [[flat]];
};
vertex SharpVertex sharpQuad(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                            const device SharpLine *lines [[buffer(0)]], constant float4 &viewport [[buffer(1)]]) {
    SharpLine line = lines[instanceID];
    float padding = 2 / viewport.z;
    float2 uv = corners[vertexID];
    float2 local = float2(mix(line.shape.x - padding, line.shape.y + padding, uv.x),
                          mix(-line.shape.z - padding, line.shape.z + padding, uv.y));
    float2 direction = line.axis.zw;
    float2 point = (line.axis.xy + direction * local.x + float2(-direction.y, direction.x) * local.y) * viewport.z;
    return {float4(point.x / viewport.x * 2 - 1, 1 - point.y / viewport.y * 2, 0, 1), local, line.shape, line.opacityScale.x};
}
fragment float4 sharpInk(SharpVertex in [[stage_in]], constant float4 &ink [[buffer(0)]]) {
    float tip = max(in.shape.w, 0.0001);
    float side = min(in.shape.z - abs(in.local.y),
                     ((in.local.x - in.shape.x) * in.shape.z - abs(in.local.y) * tip) / sqrt(tip * tip + in.shape.z * in.shape.z));
    if (in.shape.w == 0) side = in.shape.z - abs(in.local.y);
    float distance = min(side, min(in.local.x - in.shape.x, in.shape.y - in.local.x));
    float coverage = smoothstep(-0.5 * fwidth(distance), max(0.5 * fwidth(distance), 0.0001), distance);
    float alpha = ink.a * coverage * in.opacityScale;
    return float4(linearFromSRGB(ink.rgb) * alpha, alpha);
}

// Octgrams: repeated intersecting box fields, accumulated along a moving ray.
float2 octRotate(float2 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float2(c * p.x + s * p.y, -s * p.x + c * p.y);
}
float octBox(float3 p, float scale) {
    float3 q = abs(p * scale) - float3(0.4, 0.4, 0.1);
    return -(length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0)) / 1.5;
}
float octField(float3 p, float time) {
    float shift = sin(time * 0.4) * 2.5;
    float scale = 2.0 - abs(sin(time * 0.4)) * 1.5;
    float result = -1e6;
    for (int i = 0; i < 4; ++i) {
        float3 q = p;
        if (i < 2) q.y += i == 0 ? shift : -shift;
        else q.x += i == 2 ? shift : -shift;
        q.xy = octRotate(q.xy, 0.8);
        result = max(result, octBox(q, scale));
    }
    float3 rotated = p;
    rotated.xy = octRotate(p.xy, 0.8);
    return max(result, max(octBox(rotated, 0.5), octBox(p, 0.5)) * 6.0);
}
fragment float4 octgrams(Quad in [[stage_in]], constant float4 &viewport [[buffer(0)]],
                        constant float4 &values [[buffer(1)]]) {
    float time = values.x;
    float2 p = (float2(in.uv.x, 1.0 - in.uv.y) * 2.0 - 1.0) * viewport.xy / min(viewport.x, viewport.y) / viewport.z;
    float3 origin = float3(0.0, -0.2, time * 4.0);
    float3 ray = normalize(float3(p, 1.5));
    ray.xy = octRotate(ray.xy, sin(time * 0.03) * 5.0);
    ray.yz = octRotate(ray.yz, sin(time * 0.05) * 0.2);
    float distance = 0.1, accumulated = 0.0;
    for (int i = 0; i < 99; ++i) {
        float3 point = origin + ray * distance;
        point = point - 2.0 - 4.0 * floor((point - 2.0) / 4.0) - 2.0;
        float d = max(abs(octField(point, time - float(i) * 0.01)), 0.01);
        accumulated += exp(-d * 23.0);
        distance += d * 0.55;
    }
    float3 color = float3(accumulated * 0.02) + float3(0.0, 0.2 * abs(sin(time)), 0.5 + sin(time) * 0.2);
    float alpha = saturate(1.0 - distance * (0.02 + 0.02 * sin(time))) * values.z;
    // The reference colors are display sRGB; the scene composites in linear sRGB.
    color *= values.y;
    color = select(color / 12.92, pow((color + 0.055) / 1.055, float3(2.4)), color > 0.04045);
    return float4(color * alpha, alpha);
}

float radialHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}
float radialSmoothNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = radialHash(i), b = radialHash(i + float2(1, 0));
    float c = radialHash(i + float2(0, 1)), d = radialHash(i + float2(1, 1));
    return (a + (b - a) * u.x + (c - a) * u.y + (a - b - c + d) * u.x * u.y) / 4.0;
}
float radialMirror(float t, float rotation) {
    return 2.0 * abs(fract(t + rotation) - 0.5);
}
float radialNoise(float t, float distance, float time) {
    float d = pow(distance, 0.01) - floor(time * 10.0) * 0.1;
    float f1 = radialSmoothNoise(float2(radialMirror(t, 0.1), d) * 44.2);
    float f2 = radialSmoothNoise(2.1 * float2(radialMirror(t, 0.4), d) * 44.2);
    float f3 = radialSmoothNoise(3.7 * float2(radialMirror(t, 0.8), d) * 44.2);
    float f4 = radialSmoothNoise(5.8 * float2(radialMirror(t, 0.0), d) * 44.2);
    return (f1 + 0.5 * f2 + 0.25 * f3 + 0.125 * f4) * 3.0;
}
float3 radialColor(float intensity) {
    float f = clamp(intensity * 0.95, 0.0, 1.0);
    float3 c = mix(float3(0, 0, 1.1), float3(0, 1, 1), f);
    c = mix(c, float3(1), f * 4.0 - 3.0);
    // GLSL mix permits extrapolation; clamp only the resulting display color.
    return saturate(c * (f + 0.1));
}
fragment float4 radialFocus(Quad in [[stage_in]], constant float4 &values [[buffer(0)]]) {
    float2 uv = 2.2 * (float2(in.uv.x, 1.0 - in.uv.y) - 0.5) * float2(1, 1080.0 / 1920.0) / values.y;
    float d = dot(uv, uv);
    float t = d > 0 ? 0.5 + atan2(uv.y, uv.x) / 6.28 : 0.5;
    float v = (-2.5 + radialNoise(t, d, values.x) * 4.5) * (0.8 * smoothstep(0.1, 0.65, d));
    float3 color = radialColor(v);
    return float4(linearFromSRGB(color) * values.z * values.w, 0);
}

// Warp Speed 2 by David Hoskins; chaotic inversion loop credited to Kali.
fragment float4 warpFlight(Quad in [[stage_in]], constant float4 &viewport [[buffer(0)]],
                           constant float4 &values [[buffer(1)]]) {
    float2 uv = (float2(in.uv.x, 1.0 - in.uv.y) * 2.0 - 1.0) / viewport.z;
    float time = (values.x - 2.0) * 58.0;
    float3 origin = float3(sin(time * 0.0032) * 0.3, 0.35 - cos(time * 0.005) * 0.3, time * 0.002);
    float distance = 0.0, accumulated = 0.0;
    float3 color = float3(0.0);
    for (int r = 0; r < 100; ++r) {
        float3 p = origin + distance * float3(uv, 0.05);
        p.z = fract(p.z);
        for (int i = 0; i < 10; ++i) {
            p = abs(p * 2.04) / max(dot(p, p), 1e-8) - 0.9;
        }
        accumulated += pow(dot(p, p), 0.7) * 0.06;
        color += float3(accumulated * 0.2 + 0.4, 12.0 - distance * 2.0, 0.1 + accumulated) * accumulated * 0.00003;
        distance += 0.025;
    }
    float3 light = tanh(color);
    float peak = max(light.r, max(light.g, light.b));
    float violet = light.r / max(peak, 1e-8);
    float3 palette = mix(float3(0.24, 0.18, 1.0), float3(0.65, 0.18, 1.0), violet);
    color = palette * saturate(peak * values.y);
    return float4(linearFromSRGB(color) * values.z, values.z);
}

kernel void glareSpread(texture2d<float, access::sample> source [[texture(0)]],
                        texture2d<float, access::write> target [[texture(1)]],
                        constant float2 &offset [[buffer(0)]], uint2 point [[thread_position_in_grid]]) {
    if (point.x >= target.get_width() || point.y >= target.get_height()) return;
    constexpr sampler transparent(coord::pixel, address::clamp_to_zero, filter::linear);
    float2 p = float2(point) + 0.5;
    float4 value = source.sample(transparent, p) * 0.5
        + (source.sample(transparent, p - offset) + source.sample(transparent, p + offset)) * 0.25;
    target.write(value, point);
}

kernel void glareMerge(texture2d<float, access::read> a [[texture(0)]],
                       texture2d<float, access::read> b [[texture(1)]],
                       texture2d<float, access::write> target [[texture(2)]], uint2 point [[thread_position_in_grid]]) {
    if (point.x >= target.get_width() || point.y >= target.get_height()) return;
    target.write((a.read(point) + b.read(point)) * 0.5, point);
}

// Lens Flare Example by peterekepeter (Unlicense), adapted for linear additive compositing.
float flareNoise(float t) {
    float i = floor(t), f = fract(t);
    float a = fract(sin(i * 127.1 + 311.7) * 43758.5453);
    float b = fract(sin((i + 1) * 127.1 + 311.7) * 43758.5453);
    return mix(a, b, f * f * (3 - 2 * f));
}
float flareGhost(float2 uv, float2 pos, float offset, float exponent, float gain) {
    return max(0.01 - pow(length(uv + offset * pos), exponent), 0.0) * gain;
}
fragment float4 lensFlare(Quad in [[stage_in]], constant float4 &values [[buffer(0)]]) {
    float2 aspect = float2(1920.0 / 1080.0, -1);
    float2 uv = (in.uv - 0.5) * aspect / values.z;
    float2 pos = (values.xy - 0.5) * aspect / values.z;
    float2 main = uv - pos;
    float2 uvd = uv * length(uv);
    float ang = dot(main, main) > 1e-12 ? atan2(main.x, main.y) : 0;
    float dist = pow(length(main), 0.1);
    float f0 = 1 / (length(main) * 16 + 1);
    f0 *= 1.8 + sin(flareNoise(sin(ang * 2 + pos.x) * 4 - cos(ang * 3 + pos.y)) * 16) * 0.1 + dist * 0.1;
    float3 c;
    for (uint channel = 0; channel < 3; ++channel) {
        float k = float(channel);
        float f2 = (0.25 - 0.02 * k) / (1 + 32 * pow(length(uvd + (0.8 + 0.05 * k) * pos), 2.0));
        float2 uvx = mix(uv, uvd, -0.5);
        float f4 = flareGhost(uvx, pos, 0.4 + 0.05 * k, 2.4, channel == 0 ? 6 : (channel == 1 ? 5 : 3));
        float f5 = flareGhost(mix(uv, uvd, -0.4), pos, 0.2 + 0.2 * k, 5.5, 2);
        float f6 = flareGhost(uvx, pos, -(0.3 + 0.025 * k), 1.6, channel == 0 ? 6 : (channel == 1 ? 3 : 5));
        c[channel] = (f2 + f4 + f5 + f6) * 1.3 - length(uvd) * 0.05 + f0;
    }
    c = max(c * float3(1.4, 1.2, 1), 0.0);
    float w = c.r + c.g + c.b;
    c = mix(c, float3(w * 0.5), saturate(w * 0.1));
    return float4(linearFromSRGB(c) * values.w, 0);
}

struct RadialBlurUniforms {
    float4 canvas; // width, height, padding, strength
    float4 quality; // normalized center x/y, sample limit, jitter
};

kernel void radialBlur(texture2d<float, access::sample> source [[texture(0)]],
                       texture2d<half, access::write> target [[texture(1)]],
                       constant RadialBlurUniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    constexpr sampler sampling(coord::pixel, address::clamp_to_zero, filter::linear);
    float2 point = float2(gid) + 0.5;
    float2 deltaUV = (point - u.canvas.z) / u.canvas.xy - u.quality.xy;
    float amount = min(1.0f, u.canvas.w * length(deltaUV));
    float2 travel = deltaUV * u.canvas.xy * amount;
    float distance = length(travel);
    // Even stratified pairs preserve the first moment of the interval with or without jitter.
    uint limit = max(2u, uint(u.quality.z) / 2u * 2u);
    uint count = min(limit, max(2u, uint(ceil(distance * 0.5f)) * 2u));
    float jitter = u.quality.w * smoothstep(1.0f, 2.0f, distance / float(count));
    float4 sum = 0;
    for (uint i = 0; i < count; i += 2) {
        uint hash = gid.x * 1973u + gid.y * 9277u + (i / 2u) * 26699u + 911u;
        hash = (hash ^ (hash >> 16u)) * 2246822519u;
        hash = (hash ^ (hash >> 13u)) * 3266489917u;
        hash ^= hash >> 16u;
        float offset = (float(hash & 65535u) / 65535.0f - 0.5f) * jitter;
        float t0 = (float(i) + 0.5f + offset) / float(count);
        float t1 = (float(i) + 1.5f - offset) / float(count);
        sum += source.sample(sampling, point - travel * t0);
        sum += source.sample(sampling, point - travel * t1);
    }
    target.write(half4(sum / float(count)), gid);
}

struct StraightLine { float4 axis; float4 shape; float4 opacityScale; };
struct StraightVertex {
    float4 position [[position]];
    float2 local;
    float4 shape [[flat]];
    float opacityScale [[flat]];
};
vertex StraightVertex straightQuad(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                  const device StraightLine *lines [[buffer(0)]], constant float4 &viewport [[buffer(1)]]) {
    StraightLine line = lines[instanceID];
    float padding = line.shape.w + 2 / viewport.z;
    float2 local = (corners[vertexID] * 2 - 1) * (line.shape.xy + padding);
    float2 direction = line.axis.zw;
    float2 point = (line.axis.xy + direction * local.x + float2(-direction.y, direction.x) * local.y) * viewport.z;
    return {float4(point.x / viewport.x * 2 - 1, 1 - point.y / viewport.y * 2, 0, 1), local, line.shape, line.opacityScale.x};
}
float straightFade(StraightVertex in) {
    return in.shape.z > 0 ? smoothstep(0.0, in.shape.z, in.shape.x - abs(in.local.x)) : 1.0;
}
fragment float4 straightInk(StraightVertex in [[stage_in]], constant float4 &ink [[buffer(0)]]) {
    float distance = min(in.shape.x - abs(in.local.x), in.shape.y - abs(in.local.y));
    float aa = max(fwidth(distance), 0.0001);
    float alpha = smoothstep(-aa * 0.5, aa * 0.5, distance) * straightFade(in) * ink.a * in.opacityScale;
    return float4(linearFromSRGB(ink.rgb) * alpha, alpha);
}
fragment float4 straightGlow(StraightVertex in [[stage_in]], constant float4 &ink [[buffer(0)]],
                             constant float &strength [[buffer(1)]]) {
    float outside = max(abs(in.local.y) - in.shape.y, 0.0);
    float halo = exp(-4 * outside * outside / (in.shape.w * in.shape.w));
    halo *= 1 - smoothstep(in.shape.w * 0.75, in.shape.w, outside);
    float end = 1 - smoothstep(in.shape.x, in.shape.x + in.shape.w, abs(in.local.x));
    float fade = in.shape.z > 0 ? smoothstep(-in.shape.w, in.shape.z, in.shape.x - abs(in.local.x)) : end;
    return float4(linearFromSRGB(ink.rgb) * ink.a * in.opacityScale * strength * halo * end * fade, 0);
}

struct RaysInstance { float4 axis; float4 bounds; float4 triangle; float4 style; };
struct RaysVertex {
    float4 position [[position]];
    float2 local;
    float4 triangle [[flat]];
    float4 style [[flat]];
};
vertex RaysVertex raysQuad(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                           const device RaysInstance *instances [[buffer(0)]], constant float4 &viewport [[buffer(1)]]) {
    RaysInstance ray = instances[instanceID];
    float2 local = mix(ray.bounds.xz, ray.bounds.yw, corners[vertexID]);
    float2 direction = ray.axis.zw;
    float2 point = (ray.axis.xy + direction * local.x + float2(-direction.y, direction.x) * local.y) * viewport.z;
    return {float4(point.x / viewport.x * 2 - 1, 1 - point.y / viewport.y * 2, 0, 1), local, ray.triangle, ray.style};
}
float raysCross(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }
float raysEdge(float2 a, float2 b, float2 p) {
    return raysCross(b - a, p - a) / max(length(b - a), 0.00001);
}
fragment float4 raysLight(RaysVertex in [[stage_in]], constant float4 &ink [[buffer(0)]]) {
    float3 color = linearFromSRGB(ink.rgb);
    float light;
    if (in.style.z > 0 && in.style.w > 0) {
        float radius = length(in.local / in.style.zw);
        float aa = max(fwidth(radius), 0.0001);
        float core = 1 - smoothstep(0.65 - aa, 1.0 + aa, radius);
        float halo = exp(-3 * radius * radius) * (1 - smoothstep(1.5, 2.0, radius));
        color = mix(color, float3(1), 1 - smoothstep(0.2, 0.8, radius));
        light = core + 0.6 * halo;
    } else {
        float2 b = in.triangle.xy, c = in.triangle.zw;
        float distance = min(raysEdge(float2(0), b, in.local), min(raysEdge(b, c, in.local), raysEdge(c, float2(0), in.local)));
        float aa = max(fwidth(distance), 0.0001);
        float core = smoothstep(-aa * 0.5, aa * 0.5, distance);
        float outside = max(-distance, 0.0);
        float halo = in.style.x > 0 ? exp(-4 * outside * outside / max(in.style.x * in.style.x, 0.0001))
            * (1 - smoothstep(in.style.x * 0.75, in.style.x, outside)) : 0;
        // Fade the outer tip without detaching the ray from the origin.
        float end = max(b.x, c.x);
        float fade = 1 - smoothstep(end * 0.94, end, in.local.x);
        light = (core + 0.35 * halo) * fade;
    }
    return float4(color * light * in.style.y * ink.a, 0);
}
