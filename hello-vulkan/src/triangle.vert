#version 450
layout(location = 0) out vec3 color;
void main() {
    vec2 positions[3] = vec2[](vec2(0, -0.6), vec2(0.6, 0.6), vec2(-0.6, 0.6));
    vec3 colors[3] = vec3[](vec3(0.95, 0.25, 0.20), vec3(0.20, 0.45, 0.95), vec3(0.20, 0.80, 0.35));
    gl_Position = vec4(positions[gl_VertexIndex], 0, 1);
    color = colors[gl_VertexIndex];
}
