-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

-- The content measures the panel. Its shader stretches to the same bounds.
return function(props)
    local background = props.backgroundShader
    if not background then return ui.column(props) end
    props.backgroundShader = nil
    background.radius = props.radius
    local layers = { w = props.w, h = props.h, background }
    for _, key in { "radius", "material", "fill", "border", "borderWidth", "shadow", "shadowRadius" } do
        layers[key], props[key] = props[key], nil
    end
    layers[2] = ui.column(props)
    return ui.stack(layers)
end
