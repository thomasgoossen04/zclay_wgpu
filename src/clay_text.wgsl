struct Uniforms {
    projection: mat4x4f,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var font_texture: texture_2d<f32>;
@group(0) @binding(2) var font_sampler: sampler;

struct VertIn {
    @location(0) pos: vec2f,
    @location(1) color: vec4f,
    @location(2) uv: vec2f,
}

struct VertOut {
    @builtin(position) clip_pos: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
}

@vertex fn vs(in: VertIn) -> VertOut {
    var out: VertOut;
    out.clip_pos = uniforms.projection * vec4f(in.pos, 0.0, 1.0);
    out.color = in.color;
    out.uv = in.uv;
    return out;
}

@fragment fn fs(in: VertOut) -> @location(0) vec4f {
    let alpha = textureSample(font_texture, font_sampler, in.uv).r;
    return vec4f(in.color.rgb, in.color.a * alpha);
}
