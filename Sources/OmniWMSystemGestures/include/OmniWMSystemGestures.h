// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#ifndef OMNIWM_SYSTEM_GESTURES_H
#define OMNIWM_SYSTEM_GESTURES_H

#include <stdbool.h>
#include "OmniWMKiwiTouch.h"
#include "OmniWMDockSlide.h"

typedef enum OmniWMNativeGesturePreference {
    OmniWMNativeGestureTouchSpaces = 0,
    OmniWMNativeGestureTrackpadMissionControl,
    OmniWMNativeGestureTrackpadAppExpose,
    OmniWMNativeGestureTouchMissionControl,
    OmniWMNativeGestureTouchAppExpose,
} OmniWMNativeGesturePreference;

// The Spaces preference has values 0 (off), 3 or 4. The other preferences use 0 (off) and 1 (on).
bool omniwm_native_gesture_available(OmniWMNativeGesturePreference gesture);
bool omniwm_native_gesture_value(OmniWMNativeGesturePreference gesture, int *_Nonnull value);
bool omniwm_set_native_gesture_value(OmniWMNativeGesturePreference gesture, int value);

// Runtime fallback when building against an SDK older than macOS 27.3.
bool omniwm_set_window_direct_touch_system_gestures_disabled(void *_Nonnull window, bool disabled);

#endif
