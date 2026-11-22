// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "OmniWMSystemGestures.h"

#if defined(__arm64__)

#include <dlfcn.h>
#include <pthread.h>
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
typedef void (*controller_releaser)(void *);

typedef struct {
    metadata_accessor metadata;
    controller_allocator allocate;
    finger_count_getter read;
    finger_count_setter write;
    controller_releaser release;
} touch_spaces_api;

static pthread_once_t api_load = PTHREAD_ONCE_INIT;
static touch_spaces_api api;

static void load_touch_spaces_api(void)
{
    void *library = dlopen(
        "/System/Library/PrivateFrameworks/WindowManager.framework/Versions/A/WindowManager",
        RTLD_LAZY | RTLD_LOCAL
    );
    if (library == NULL) {
        return;
    }

    touch_spaces_api resolved = {
        .metadata = (metadata_accessor)dlsym(library, "$s13WindowManager27ExposePreferencesControllerCMa"),
        .allocate = (controller_allocator)dlsym(library, "$s13WindowManager27ExposePreferencesControllerCACycfC"),
        .read = (finger_count_getter)dlsym(library,
            "$s13WindowManager27ExposePreferencesControllerC40systemGesturesSpaceSwapMinimumPointCountSiSgvg"),
        .write = (finger_count_setter)dlsym(library,
            "$s13WindowManager27ExposePreferencesControllerC40systemGesturesSpaceSwapMinimumPointCountSiSgvs"),
        .release = (controller_releaser)dlsym(library, "swift_release")
    };
    if (resolved.metadata == NULL || resolved.allocate == NULL || resolved.read == NULL
        || resolved.write == NULL || resolved.release == NULL) {
        dlclose(library);
        return;
    }
    api = resolved;
}

bool omniwm_touch_spaces_preference_available(void)
{
    if (pthread_main_np() == 0) {
        return false;
    }
    pthread_once(&api_load, load_touch_spaces_api);
    return api.read != NULL;
}

static void *make_controller(void)
{
    void *metadata = api.metadata(0).metadata;
    return metadata == NULL ? NULL : api.allocate(metadata);
}

bool omniwm_touch_spaces_finger_count(int *finger_count)
{
    if (!omniwm_touch_spaces_preference_available()) {
        return false;
    }
    void *controller = make_controller();
    if (controller == NULL) {
        return false;
    }
    swift_optional_int setting = api.read(controller);
    api.release(controller);

    if (setting.is_nil == 1) {
        *finger_count = 0;
        return true;
    }
    if (setting.is_nil == 0 && (setting.value == 3 || setting.value == 4)) {
        *finger_count = (int)setting.value;
        return true;
    }
    return false;
}

bool omniwm_set_touch_spaces_finger_count(int finger_count)
{
    if ((finger_count != 0 && finger_count != 3 && finger_count != 4)
        || !omniwm_touch_spaces_preference_available()) {
        return false;
    }
    void *controller = make_controller();
    if (controller == NULL) {
        return false;
    }
    api.write((swift_optional_int){ .value = finger_count, .is_nil = finger_count == 0 }, controller);
    api.release(controller);

    int observed;
    return omniwm_touch_spaces_finger_count(&observed) && observed == finger_count;
}

#else

bool omniwm_touch_spaces_preference_available(void)
{
    return false;
}

bool omniwm_touch_spaces_finger_count(int *finger_count)
{
    (void)finger_count;
    return false;
}

bool omniwm_set_touch_spaces_finger_count(int finger_count)
{
    (void)finger_count;
    return false;
}

#endif
