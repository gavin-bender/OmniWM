// SPDX-License-Identifier: GPL-2.0-only
#import <Foundation/Foundation.h>

@protocol OmniWMPowerModeService
- (void)setMode:(NSInteger)mode onBattery:(BOOL)onBattery reply:(void (^ _Nonnull)(BOOL))reply
    NS_SWIFT_NAME(setMode(_:onBattery:reply:));
@end
