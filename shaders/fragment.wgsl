struct Camera {
    pos: vec3<f32>,
    right: vec3<f32>,
    forward: vec3<f32>,
    up: vec3<f32>,
}

struct Uniform {
    resolution: vec2<f32>,
    t: f32,
    camera: Camera,
}

struct FragmentOutput {
    @location(0) frag_color: vec4<f32>,
}

@group(0) @binding(0) 
var rendertarget: texture_2d<f32>;
@group(0) @binding(1) 
var _sampler: sampler;
@group(1) @binding(0) 
var<uniform> u: Uniform;
var<private> frag_color: vec4<f32>;
var<private> gl_FragCoord_1: vec4<f32>;

fn main_1() {
    var uv: vec2<f32>;

    let _e11 = gl_FragCoord_1;
    let _e13 = u;
    uv = (_e11.xy / _e13.resolution);
    let _e17 = uv;
    let _e18 = textureSample(rendertarget, _sampler, _e17);
    frag_color = _e18;
    return;
}

@fragment 
fn main(@builtin(position) gl_FragCoord: vec4<f32>) -> FragmentOutput {
    gl_FragCoord_1 = gl_FragCoord;
    main_1();
    let _e16 = frag_color;
    return FragmentOutput(_e16);
}
