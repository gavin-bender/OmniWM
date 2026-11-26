-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local symbols = table.freeze({
    cogwheel = "gearshape.fill",
    ["tiled-windows"] = "rectangle.split.2x1.fill",
    sliders = "slider.horizontal.3",
    ["apple-logo"] = "applelogo",
})

local artwork = table.freeze({
    ["gb-signature"] = "assets/gb-signature.png",
    ["gb-apple-cutout"] = "assets/gb-apple-cutout.png",
})

return function(choice: string?, locked: boolean?, glyph)
    local selected = choice or "cogwheel"
    if not locked and artwork[selected] then
        return ui.image{ image = artwork[selected], w = glyph.w, h = glyph.h }
    end
    glyph.name = if locked then "lock.fill" else symbols[selected] or symbols.cogwheel
    return ui.symbol(glyph)
end
