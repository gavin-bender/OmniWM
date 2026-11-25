// SPDX-License-Identifier: GPL-2.0-only
#ifndef OMNIWM_KIWI_TOUCH_H
#define OMNIWM_KIWI_TOUCH_H

#include <stdint.h>

typedef struct OmniWMKiwiMonitor OmniWMKiwiMonitor;
typedef struct { float x, y; } OmniWMKiwiPoint;
typedef void (*OmniWMKiwiCallback)(uintptr_t token, const OmniWMKiwiPoint *_Nonnull points, int count, double timestamp);

OmniWMKiwiMonitor *_Nullable omniwm_open_kiwi_monitor(uintptr_t token, OmniWMKiwiCallback _Nonnull callback);
void omniwm_close_kiwi_monitor(OmniWMKiwiMonitor *_Nonnull monitor);
#endif
