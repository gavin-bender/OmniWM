// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

// Both designs use curves monotonic in y. Solve for the point on the curve
// at this scanline, then project the horizontal offset onto its normal.
float curveDistance(float2 p, float2 a, float2 b, float2 c, float2 d) {
    float2 k1 = 3.0 * (b - a);
    float2 k2 = 3.0 * (a - 2.0*b + c);
    float2 k3 = d - a + 3.0*(b - c);
    float t = saturate((p.y - a.y) / (d.y - a.y));
    for (int step = 0; step < 4; ++step) {
        float y = a.y + t * (k1.y + t * (k2.y + t * k3.y));
        t = saturate(t - (y - p.y) / (k1.y + t * (2.0*k2.y + 3.0*t*k3.y)));
    }
    float2 q = a + t * (k1 + t * (k2 + t*k3));
    if (t == 0.0 || t == 1.0) return length(p - q);
    float2 tangent = normalize(k1 + t * (2.0*k2 + 3.0*t*k3));
    return abs(dot(p - q, float2(-tangent.y, tangent.x)));
}

float stroke(float distance, float width, float aa) {
    return 1.0 - smoothstep(width * 0.5 - aa, width * 0.5 + aa, distance);
}

float4 shade(float2 uv, constant OmniShader& shader) {
    float2 p = uv * shader.size;
    float w = shader.size.x, h = shader.size.y;
    float aa = 0.65 / max(1.0, shader.scale);
    float opacity = 0.0;
    if (shader.values.x > 0.5) {
        if (p.y > 154.0) return float4(0.0);
        float remaining = 1.0 - saturate(shader.time / 3.0);
        float drift = 20.0 * (1.0 - remaining*remaining*remaining);
        for (int i = 0; i < 7; ++i) {
            float offset = 9.0 * float(i);
            float distance = curveDistance(p, float2(0.32*w + offset, -15.0),
                float2(0.85*w - 0.3*offset, 8.0 + drift), float2(0.54*w + offset, 70.0 + drift),
                float2(w + 8.0, 97.0 + offset));
            float alpha = (0.15 + 0.26*sin((i + 1)*M_PI_F/8.0)) * stroke(distance, i == 3 ? 2.0 : 1.1, aa);
            opacity += (1.0 - opacity) * alpha;
        }
    } else if (p.x >= 0.56*w - 5.0) {
        for (int i = 0; i < 2; ++i) {
            float distance = curveDistance(p - float2(i * 9.0, 0.0), float2(0.56*w, h + 8.0),
                float2(0.95*w, 0.73*h), float2(0.76*w, 0.38*h), float2(0.98*w, -8.0));
            float phase = 1.0 - uv.y - shader.time / 4.8 - i*0.065;
            float crest = pow(0.5 + 0.5*cos(2.0*M_PI_F*phase), 8.0);
            float light = 0.12 + 0.64*crest;
            opacity += (1.0 - opacity) * 0.12*light * stroke(distance, 8.0, aa);
            opacity += (1.0 - opacity) * light * stroke(distance, 2.0, aa);
        }
    }
    return float4(shader.colors[omni_accent].rgb, opacity);
}
