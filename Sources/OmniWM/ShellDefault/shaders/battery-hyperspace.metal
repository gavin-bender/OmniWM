// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

float4 shade(float2 uv, constant OmniShader& shader) {
    float2 point = (uv - float2(0.5, 0.42)) * shader.size;
    float distance = length(point);
    float reach = max(length(shader.size) * 0.75, 1.0);
    float radius = distance / reach;

    // Stars accelerate away from the center in High Power and coast inward in Low Power.
    bool lowPower = shader.values.x > 0.5;
    float lanes = lowPower ? 64.0 : 96.0;
    float angle = atan2(point.y, point.x) / (2.0 * M_PI_F) + 0.5;
    float lane = floor(angle * lanes);
    float2 seed = fract(sin((lane + 1.0) * float2(12.9898, 78.233)) * 43758.5453);
    float speed = lowPower ? -0.055 : 0.22;
    float travel = fract(shader.time * speed * (1.0 + 0.8 * seed.x) + seed.y);
    float head = travel * travel;
    float lengthBehindHead = 0.008 + head * (lowPower ? 0.045 : 0.135);
    float behind = lowPower ? radius - head : head - radius;
    float across = abs(fract(angle * lanes) - (0.22 + 0.56 * seed.x)) * distance * (2.0 * M_PI_F / lanes);
    float line = 1.0 - smoothstep(0.25, 1.3, across);
    float streak = line * (1.0 - smoothstep(0.0, lengthBehindHead, behind)) * smoothstep(-1.3 / reach, 0.0, behind);
    float light = streak * smoothstep(0.055, 0.24, radius) * (1.0 - smoothstep(0.88, 1.0, head));
    float3 color = mix(shader.colors[omni_accent].rgb, shader.colors[omni_foreground].rgb, 0.30 * seed.x);
    return float4(color, (lowPower ? 0.35 : 0.50) * light);
}
