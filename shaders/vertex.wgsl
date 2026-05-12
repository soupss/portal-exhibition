struct VertexOutput {
    @builtin(position) gl_Position: vec4<f32>,
}

var<private> positions: array<vec2<f32>, 6> = array<vec2<f32>, 6>(vec2<f32>(-1f, -1f), vec2<f32>(1f, -1f), vec2<f32>(-1f, 1f), vec2<f32>(1f, -1f), vec2<f32>(-1f, 1f), vec2<f32>(1f, 1f));
var<private> gl_Position: vec4<f32>;
var<private> gl_VertexIndex_1: u32;

fn main_1() {
    let _e3 = gl_VertexIndex_1;
    let _e5 = positions[_e3];
    gl_Position = vec4<f32>(_e5.x, _e5.y, 0f, 1f);
    return;
}

@vertex 
fn main(@builtin(vertex_index) gl_VertexIndex: u32) -> VertexOutput {
    gl_VertexIndex_1 = gl_VertexIndex;
    main_1();
    let _e30 = gl_Position;
    return VertexOutput(_e30);
}
