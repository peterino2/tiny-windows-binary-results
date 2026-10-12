struct VertexOutput {
    float4 position : SV_POSITION;
    float3 color : COLOR;
};

// Generate three vertices directly: no vertex buffer is needed.
VertexOutput VSMain(uint id : SV_VertexID) {
    const float2 positions[3] = {
        float2(0.0, 0.65), float2(0.65, -0.65), float2(-0.65, -0.65)
    };
    const float3 colors[3] = {
        float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1)
    };
    VertexOutput output;
    output.position = float4(positions[id], 0.0, 1.0);
    output.color = colors[id];
    return output;
}

float4 PSMain(VertexOutput input) : SV_TARGET {
    return float4(input.color, 1.0);
}
