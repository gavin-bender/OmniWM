// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "OmniWMSystemGestures.h"

#include <pthread.h>
#include <stddef.h>

#if defined(__arm64__)

#include <dlfcn.h>
#include <stdint.h>

// The arm64 Swift ABI passes Int? as an Int payload and a one-byte nil tag.
typedef struct {
    intptr_t value;
    uint8_t is_nil;
} swift_optional_int;

typedef struct {
    void *metadata;
    intptr_t state;
} swift_metadata_response;

typedef swift_metadata_response __attribute__((swiftcall)) (*metadata_accessor)(intptr_t);
typedef void * __attribute__((swiftcall)) (*controller_allocator)(void * __attribute__((swift_context)));
typedef swift_optional_int __attribute__((swiftcall)) (*finger_count_getter)(void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*finger_count_setter)(swift_optional_int, void * __attribute__((swift_context)));
typedef bool __attribute__((swiftcall)) (*bool_getter)(void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*bool_setter)(bool, void * __attribute__((swift_context)));
typedef void (*controller_releaser)(void *);

#define PREFERENCE_CONTROLLER "$s13WindowManager27ExposePreferencesControllerC"
#define BOOL_SYMBOLS(property) { PREFERENCE_CONTROLLER property "Sbvg", PREFERENCE_CONTROLLER property "Sbvs" }

static const struct {
    const char *read;
    const char *write;
} bool_preference_symbols[] = {
    [OmniWMNativeGestureTrackpadMissionControl] = BOOL_SYMBOLS("32showMissionControlGestureEnabled"),
    [OmniWMNativeGestureTrackpadAppExpose] = BOOL_SYMBOLS("07showAppC14GestureEnabled"),
    [OmniWMNativeGestureTouchMissionControl] = BOOL_SYMBOLS("35systemGesturesMissionControlEnabled"),
    [OmniWMNativeGestureTouchAppExpose] = BOOL_SYMBOLS("017systemGesturesAppC7Enabled"),
};

#define BOOL_PREFERENCE_COUNT (sizeof(bool_preference_symbols) / sizeof(bool_preference_symbols[0]))

typedef struct {
    bool_getter read;
    bool_setter write;
} bool_preference_accessors;

typedef struct {
    metadata_accessor metadata;
    controller_allocator allocate;
    controller_releaser release;
    finger_count_getter read_touch_spaces;
    finger_count_setter write_touch_spaces;
    bool_preference_accessors bool_preferences[BOOL_PREFERENCE_COUNT];
} native_gesture_api;

static pthread_once_t api_load = PTHREAD_ONCE_INIT;
static native_gesture_api api;

static void load_native_gesture_api(void)
{
    void *library = dlopen(
        "/System/Library/PrivateFrameworks/WindowManager.framework/Versions/A/WindowManager",
        RTLD_LAZY | RTLD_LOCAL
    );
    if (library == NULL) {
        return;
    }

    native_gesture_api resolved = {
        .metadata = (metadata_accessor)dlsym(library, PREFERENCE_CONTROLLER "Ma"),
        .allocate = (controller_allocator)dlsym(library, PREFERENCE_CONTROLLER "ACycfC"),
        .release = (controller_releaser)dlsym(library, "swift_release"),
        .read_touch_spaces = (finger_count_getter)dlsym(
            library, PREFERENCE_CONTROLLER "40systemGesturesSpaceSwapMinimumPointCountSiSgvg"),
        .write_touch_spaces = (finger_count_setter)dlsym(
            library, PREFERENCE_CONTROLLER "40systemGesturesSpaceSwapMinimumPointCountSiSgvs"),
    };
    if (resolved.metadata == NULL || resolved.allocate == NULL || resolved.release == NULL) {
        dlclose(library);
        return;
    }

    for (size_t index = 0; index < BOOL_PREFERENCE_COUNT; index++) {
        if (bool_preference_symbols[index].read == NULL) {
            continue;
        }
        resolved.bool_preferences[index].read = (bool_getter)dlsym(library, bool_preference_symbols[index].read);
        resolved.bool_preferences[index].write = (bool_setter)dlsym(library, bool_preference_symbols[index].write);
    }
    api = resolved;
}

bool omniwm_native_gesture_available(OmniWMNativeGesturePreference gesture)
{
    if (pthread_main_np() == 0) {
        return false;
    }
    pthread_once(&api_load, load_native_gesture_api);
    if (gesture == OmniWMNativeGestureTouchSpaces) {
        return api.read_touch_spaces != NULL && api.write_touch_spaces != NULL;
    }
    size_t index = (size_t)gesture;
    return index < BOOL_PREFERENCE_COUNT && api.bool_preferences[index].read != NULL
        && api.bool_preferences[index].write != NULL;
}

static void *make_controller(void)
{
    void *metadata = api.metadata(0).metadata;
    return metadata == NULL ? NULL : api.allocate(metadata);
}

bool omniwm_native_gesture_value(OmniWMNativeGesturePreference gesture, int *value)
{
    if (!omniwm_native_gesture_available(gesture)) {
        return false;
    }
    void *controller = make_controller();
    if (controller == NULL) {
        return false;
    }

    if (gesture != OmniWMNativeGestureTouchSpaces) {
        *value = api.bool_preferences[gesture].read(controller) ? 1 : 0;
        api.release(controller);
        return true;
    }

    swift_optional_int setting = api.read_touch_spaces(controller);
    api.release(controller);
    if (setting.is_nil == 1) {
        *value = 0;
        return true;
    }
    if (setting.is_nil == 0 && (setting.value == 3 || setting.value == 4)) {
        *value = (int)setting.value;
        return true;
    }
    return false;
}

bool omniwm_set_native_gesture_value(OmniWMNativeGesturePreference gesture, int value)
{
    bool valid_value = gesture == OmniWMNativeGestureTouchSpaces
        ? (value == 0 || value == 3 || value == 4) : (value == 0 || value == 1);
    if (!valid_value || !omniwm_native_gesture_available(gesture)) {
        return false;
    }
    void *controller = make_controller();
    if (controller == NULL) {
        return false;
    }

    if (gesture == OmniWMNativeGestureTouchSpaces) {
        api.write_touch_spaces((swift_optional_int){ .value = value, .is_nil = value == 0 }, controller);
    } else {
        api.bool_preferences[gesture].write(value == 1, controller);
    }
    api.release(controller);

    int observed;
    return omniwm_native_gesture_value(gesture, &observed) && observed == value;
}

#else

bool omniwm_native_gesture_available(OmniWMNativeGesturePreference gesture)
{
    (void)gesture;
    return false;
}

bool omniwm_native_gesture_value(OmniWMNativeGesturePreference gesture, int *value)
{
    (void)gesture;
    (void)value;
    return false;
}

bool omniwm_set_native_gesture_value(OmniWMNativeGesturePreference gesture, int value)
{
    (void)gesture;
    (void)value;
    return false;
}

#endif
