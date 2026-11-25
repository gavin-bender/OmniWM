// SPDX-License-Identifier: GPL-2.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>

typedef struct {
    uint32_t window;
    float baseWidth, baseHeight;
    CGPoint target;
    bool resetFirst, apply;
} OmniWMDockSlideMove;

bool omniwm_dock_slide_available(void);
bool omniwm_dock_scroll_window(uint32_t window, CGRect target);
bool omniwm_dock_slide_geometry(uint32_t window, CGRect *_Nonnull base, CGAffineTransform *_Nonnull transform);
bool omniwm_dock_slide_at_position(CGAffineTransform transform, CGPoint position);
bool omniwm_dock_slide_submit(const OmniWMDockSlideMove *_Nonnull moves, size_t count);
bool omniwm_dock_slide_restore_translation(uint32_t window);
