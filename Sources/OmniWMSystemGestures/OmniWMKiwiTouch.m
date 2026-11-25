// SPDX-License-Identifier: GPL-2.0-only
#import "OmniWMKiwiTouch.h"
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <mach/mach_time.h>

// The Kiwi screen sends a capacitive image in addition to smaller axis reports.
// Only the image has enough information to pair the X and Y of separate fingers.
enum { rows = 54, columns = 82, cells = rows * columns, profiles = 5, maxContacts = 16 };

typedef struct {
    bool calibrated[profiles];
    int16_t background[profiles][cells];
    uint16_t weight[cells];
    uint16_t pending[cells];
} KiwiDecoder;

struct OmniWMKiwiMonitor {
    IOHIDManagerRef manager;
    OmniWMKiwiCallback callback;
    uintptr_t token;
    double secondsPerTick;
    int previousCount;
    KiwiDecoder decoder;
};

static void addNeighbor(KiwiDecoder *decoder, int index, int *end, int *mass, int *sumX, int *sumY)
{
    int weight = decoder->weight[index];
    if (weight == 0) return;
    decoder->weight[index] = 0;
    decoder->pending[(*end)++] = index;
    *mass += weight;
    *sumX += weight * (index % columns);
    *sumY += weight * (index / columns);
}

// Return -1 for unrelated or unsupported reports. Zero is a real lift.
static int decode(KiwiDecoder *decoder, const uint8_t *report, CFIndex length, OmniWMKiwiPoint *points)
{
    enum { image = 61, metadata = image + 2 * cells, profileOffset = metadata + 46, scanOffset = metadata + 49 };
    const uint8_t header[] = {0x5a, 1, 2, 0, 0x20, 0x18, 0};
    const uint8_t dimensions[] = {2, rows, columns, 0};
    if (length != 17861 || memcmp(report, header, sizeof(header)) != 0 ||
        memcmp(report + image - sizeof(dimensions), dimensions, sizeof(dimensions)) != 0) return -1;
    unsigned profile = report[profileOffset];
    unsigned scan = report[scanOffset];
    if (profile >= profiles || (scan != 0 && scan != 254 && scan != 255)) return -1;

    // Idle scans cycle through gain profiles. Subtract only a reference acquired
    // at the same gain. When starting under a finger, learn exposed cells as it moves.
    bool seed = !decoder->calibrated[profile] || scan != 0;
    int16_t *background = decoder->background[profile];
    for (int i = 0; i < cells; i++) {
        int16_t sample;
        memcpy(&sample, report + image + 2 * i, sizeof(sample));
        if (seed || sample > background[i]) background[i] = sample;
        int difference = background[i] - sample;
        decoder->weight[i] = difference > 150 ? MIN(difference, 2048) : 0;
    }
    decoder->calibrated[profile] = true;
    if (seed) return 0;

    int count = 0;
    for (int i = 0; i < cells; i++) {
        if (decoder->weight[i] == 0) continue;
        int end = 0, mass = 0, sumX = 0, sumY = 0;
        addNeighbor(decoder, i, &end, &mass, &sumX, &sumY);
        for (int j = 0; j < end; j++) {
            int at = decoder->pending[j];
            if (at % columns > 0) addNeighbor(decoder, at - 1, &end, &mass, &sumX, &sumY);
            if (at % columns + 1 < columns) addNeighbor(decoder, at + 1, &end, &mass, &sumX, &sumY);
            if (at >= columns) addNeighbor(decoder, at - columns, &end, &mass, &sumX, &sumY);
            if (at + columns < cells) addNeighbor(decoder, at + columns, &end, &mass, &sumX, &sumY);
        }
        if (end < 3 || end > 32) continue;
        if (count == maxContacts) break;
        points[count++] = (OmniWMKiwiPoint){
            ((float)sumX / mass + 0.5f) / columns,
            1.0f - ((float)sumY / mass + 0.5f) / rows
        };
    }
    return count;
}

static void onReport(void *context, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length, uint64_t timestamp)
{
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput || reportID != 0) return;
    OmniWMKiwiMonitor *monitor = context;
    OmniWMKiwiPoint points[maxContacts];
    int count = decode(&monitor->decoder, report, length, points);
    if (count < 0 || (count == 0 && monitor->previousCount == 0)) return;
    monitor->previousCount = count;
    monitor->callback(monitor->token, points, count, timestamp * monitor->secondsPerTick);
}

OmniWMKiwiMonitor *omniwm_open_kiwi_monitor(uintptr_t token, OmniWMKiwiCallback callback)
{
    OmniWMKiwiMonitor *monitor = calloc(1, sizeof(*monitor));
    if (!monitor) return NULL;
    monitor->manager = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
    if (!monitor->manager) { free(monitor); return NULL; }
    monitor->callback = callback;
    monitor->token = token;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    monitor->secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    NSDictionary *match = @{ @kIOHIDDeviceUsagePageKey: @13, @kIOHIDDeviceUsageKey: @4, @kIOHIDProductKey: @"Kiwi" };
    IOHIDManagerSetDeviceMatching(monitor->manager, (__bridge CFDictionaryRef)match);
    IOHIDManagerRegisterInputReportWithTimeStampCallback(monitor->manager, onReport, monitor);
    IOHIDManagerScheduleWithRunLoop(monitor->manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn result = IOHIDManagerOpen(monitor->manager, kIOHIDOptionsTypeNone);
    CFSetRef devices = IOHIDManagerCopyDevices(monitor->manager);
    bool matched = devices && CFSetGetCount(devices) == 1;
    if (devices) CFRelease(devices);
    if (result != kIOReturnSuccess || !matched) {
        omniwm_close_kiwi_monitor(monitor);
        return NULL;
    }
    return monitor;
}

void omniwm_close_kiwi_monitor(OmniWMKiwiMonitor *monitor)
{
    IOHIDManagerUnscheduleFromRunLoop(monitor->manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDManagerClose(monitor->manager, kIOHIDOptionsTypeNone);
    CFRelease(monitor->manager);
    free(monitor);
}
