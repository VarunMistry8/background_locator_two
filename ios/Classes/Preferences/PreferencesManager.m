//
//  PreferencesManager.m
//  background_locator_2
//
//  Created by Mehdi Sohrabi on 6/28/20.
//

#import "PreferencesManager.h"
#import "Globals.h"

@implementation PreferencesManager

+ (int64_t)getCallbackDispatcherHandle {
    id handle = [[NSUserDefaults standardUserDefaults]
                 objectForKey: kCallbackDispatcherKey];
    if (handle == nil) {
        return 0;
    }
    return [handle longLongValue];
}

+ (void)setCallbackDispatcherHandle:(int64_t)handle {
    [[NSUserDefaults standardUserDefaults]
     setObject:[NSNumber numberWithLongLong:handle]
     forKey:kCallbackDispatcherKey];
}

+ (int64_t)getCallbackHandle:(NSString *)key  {
    id handle = [[NSUserDefaults standardUserDefaults]
                 objectForKey: key];
    if (handle == nil) {
        return 0;
    }
    return [handle longLongValue];
}

+ (void)setCallbackHandle:(int64_t)handle key:(NSString *)key {
    [[NSUserDefaults standardUserDefaults]
     setObject:[NSNumber numberWithLongLong:handle]
     forKey: key];
}

+ (void)saveDistanceFilter:(double)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:kDistanceFilterKey];
}

+ (double)getDistanceFilter {
    // BUGFIX: doubleForKey returns 0.0 if the key has never been written (first install).
    // A distance filter of 0 means every sub-meter GPS jitter gets logged.
    // Fall back to 60m (matching the intended default) if not yet persisted.
    double val = [[NSUserDefaults standardUserDefaults] doubleForKey:kDistanceFilterKey];
    return (val > 0) ? val : 60.0;
}

+ (void)setObservingRegion:(BOOL)observing {
    [[NSUserDefaults standardUserDefaults] setBool:observing forKey:kPrefObservingRegion];
}

+ (BOOL)isObservingRegion {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kPrefObservingRegion];
}

+ (void)setServiceRunning:(BOOL)running {
    [[NSUserDefaults standardUserDefaults] setBool:running forKey:kPrefServiceRunning];
}

+ (BOOL)isServiceRunning {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kPrefServiceRunning];
}

+ (void)setStopWithTerminate:(BOOL)terminate {
    [[NSUserDefaults standardUserDefaults] setBool:terminate forKey:kPrefStopWithTerminate];
}

+ (BOOL)isStopWithTerminate {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kPrefStopWithTerminate];
}

@end
