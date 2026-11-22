// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#ifndef OMNIWM_SYSTEM_GESTURES_H
#define OMNIWM_SYSTEM_GESTURES_H

#include <stdbool.h>

bool omniwm_touch_spaces_preference_available(void);
bool omniwm_touch_spaces_finger_count(int *_Nonnull finger_count);
bool omniwm_set_touch_spaces_finger_count(int finger_count);

#endif
