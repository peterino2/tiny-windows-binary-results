struct Output { float4 position : SV_POSITION; float3 color : COLOR; };
Output VSMain(uint id : SV_VertexID) {
    const float2 positions[3] = {float2(0, 0.6), float2(0.6, -0.6), float2(-0.6, -0.6)};
    const float3 colors[3] = {float3(0.95, 0.25, 0.20), float3(0.20, 0.45, 0.95), float3(0.20, 0.80, 0.35)};
    Output o; o.position = float4(positions[id], 0, 1); o.color = colors[id]; return o;
}
float4 PSMain(Output input) : SV_TARGET { return float4(input.color, 1); }
