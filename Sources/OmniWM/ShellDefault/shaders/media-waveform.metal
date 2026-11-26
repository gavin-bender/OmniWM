// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

// Interpolate between pseudorandom levels. Peaks rise quickly and decay more slowly.
float randomLevel(uint step, uint lane) {
    uint bits = step * 747796405u + lane * 2891336453u + 1u;
    bits = ((bits >> ((bits >> 28u) + 4u)) ^ bits) * 277803737u;
    return float((bits >> 22u) ^ bits) / 4294967295.0;
}

float movingLevel(float time, uint lane) {
    uint step = uint(floor(time));
    float from = randomLevel(step, lane);
    float to = randomLevel(step + 1u, lane);
    float t = fract(time);
    return mix(from, to, smoothstep(0.0, to > from ? 0.50 : 1.0, t));
}

float4 shade(float2 uv, constant OmniShader& shader) {
    int bar = min(int(uv.x * 5.0), 4);
    float time = max(shader.time, 0.0);
    float phrase = movingLevel(time * 1.35, 0u);
    float band = movingLevel(time * (4.1 + 0.43 * bar) + bar * 0.37, uint(bar + 1));
    float height = (0.16 + 0.80 * band * (0.45 + 0.55 * phrase)) * shader.size.y;
    float cell = shader.size.x / 5.0;
    float2 point = float2((uv.x * shader.size.x) - (float(bar) + 0.5) * cell,
                         (uv.y - 0.5) * shader.size.y);
    float2 edge = abs(point) - float2(max(1.0, cell * 0.28), height * 0.5) + 1.0;
    float distance = length(max(edge, 0.0)) + min(max(edge.x, edge.y), 0.0) - 1.0;
    float alpha = clamp(0.5 - distance * shader.scale, 0.0, 1.0);
    return float4(0.62, 0.67, 0.98, alpha);
}
