struct Uniforms {
    projection: mat4x4f,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var image_texture: texture_2d<f32>;
@group(0) @binding(2) var image_sampler: sampler;

struct VertIn {
    @location(0) pos: vec2f,
    @location(1) color: vec4f,
    @location(2) uv: vec2f,
    @location(3) round: vec4f, // (local_u, local_v, r/width, r/height)
}

struct VertOut {
    @builtin(position) clip_pos: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
    @location(2) round: vec4f,
}

@vertex fn vs(in: VertIn) -> VertOut {
    var out: VertOut;
    out.clip_pos = uniforms.projection * vec4f(in.pos, 0.0, 1.0);
    out.color = in.color;
    out.uv = in.uv;
    out.round = in.round;
    return out;
}

@fragment fn fs(in: VertOut) -> @location(0) vec4f {
    let lu = in.round.x;
    let lv = in.round.y;
    let rx = in.round.z;
    let ry = in.round.w;

    // Derivatives computed here, in top-level uniform control flow.
    // fwidth(lu) ≈ 1 / element_width_pixels.
    let pixel_u = fwidth(lu);
    let pixel_v = fwidth(lv);

    // Nearest corner centre in local-UV space.
    let cx = select(rx, 1.0 - rx, lu >= 0.5);
    let cy = select(ry, 1.0 - ry, lv >= 0.5);

    // Guard against rx/ry == 0 to avoid divide-by-zero.
    let srx = max(rx, 1e-4);
    let sry = max(ry, 1e-4);

    // Normalised distance from corner centre; d == 1.0 is the circle edge.
    let d = length(vec2f((lu - cx) / srx, (lv - cy) / sry));

    // Anti-aliasing width in normalised-d units, derived from pixel size.
    let fw = (pixel_u / srx + pixel_v / sry) * 0.5;

    // Only apply masking inside a corner zone.
    let in_corner = (lu < rx || lu > 1.0 - rx) && (lv < ry || lv > 1.0 - ry);
    let corner_mask = 1.0 - smoothstep(1.0 - fw, 1.0 + fw, d);
    let alpha_mask = select(1.0, corner_mask, in_corner && rx > 0.0);

    let sampled = textureSample(image_texture, image_sampler, in.uv) * in.color;
    return vec4f(sampled.rgb, sampled.a * alpha_mask);
}
