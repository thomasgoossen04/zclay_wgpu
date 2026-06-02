struct Uniforms {
    projection: mat4x4f,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VertIn {
    @location(0) pos: vec2f,
    @location(1) color: vec4f,
}

struct VertOut {
    @builtin(position) clip_pos: vec4f,
    @location(0) color: vec4f,
}

@vertex fn vs(in: VertIn) -> VertOut {
    var out: VertOut;
    out.clip_pos = uniforms.projection * vec4f(in.pos, 0.0, 1.0);
    out.color = in.color;
    return out;
}

@fragment fn fs(in: VertOut) -> @location(0) vec4f {
    return in.color;
}
