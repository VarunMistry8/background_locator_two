#import "BackgroundLocatorPlugin.h"
#import "Globals.h"
#import "Utils/Util.h"
#import "Preferences/PreferencesManager.h"
#import "InitPluggable.h"
#import "DisposePluggable.h"
#import "BackgroundTaskHelper.h"
#import "BackgroundActivitySessionManager.h"
#import "ServiceSessionManager.h"
#import <BackgroundTasks/BackgroundTasks.h>

/// BGAppRefreshTask identifier — must match Info.plist BGTaskSchedulerPermittedIdentifiers
static NSString *const kBGRefreshTaskId = @"background.location.tracking.refresh";

@implementation BackgroundLocatorPlugin {
    FlutterEngine *_headlessRunner;
    FlutterMethodChannel *_callbackChannel;
    FlutterMethodChannel *_mainChannel;
    NSObject<FlutterPluginRegistrar> *_registrar;
    CLLocationManager *_locationManager;
    CLLocation* _lastLocation;
    CLLocation* _lastLoggedLocation;  // Track last logged location for distance filtering
    CLLocation* _currentLocation;     // Updated on every valid update (for geofence on kill)
    double _geofenceRadius;           // Configurable geofence radius (default 100m)
    NSMutableArray *_pendingLocationMaps; // Buffer for locations arriving before isolate is ready
    NSTimer *_flushTimer;             // Retries flushing pending locations until isolate warms up
}

static FlutterPluginRegistrantCallback registerPlugins = nil;
static BackgroundLocatorPlugin *instance = nil;

#pragma mark FlutterPlugin Methods

+ (void)registerWithRegistrar:(nonnull NSObject<FlutterPluginRegistrar> *)registrar {
    @synchronized(self) {
        if (instance == nil) {
            instance = [[BackgroundLocatorPlugin alloc] init:registrar];
            [registrar addApplicationDelegate:instance];
        }
    }
}

+ (void)setPluginRegistrantCallback:(FlutterPluginRegistrantCallback)callback {
    registerPlugins = callback;
}

+ (BackgroundLocatorPlugin *) getInstance {
    return instance;
}

- (void)invokeMethod:(NSString*_Nonnull)method arguments:(id _Nullable)arguments {
    // Return if flutter engine is not ready
    NSString *isolateId = [_headlessRunner isolateId];
    if (_callbackChannel == nil || isolateId == nil) {
        return;
    }
    
    [_callbackChannel invokeMethod:method arguments:arguments];
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
    MethodCallHelper *callHelper = [[MethodCallHelper alloc] init];
    [callHelper handleMethodCall:call result:result delegate:self];
}

//https://medium.com/@calvinlin_96474/ios-11-continuous-background-location-update-by-swift-4-12ce3ac603e3
// iOS will launch the app when new location received
- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Check to see if we're being launched due to a location event.
    if (launchOptions[UIApplicationLaunchOptionsLocationKey] != nil) {
        // Restart the headless service.
        [self startLocatorService:[PreferencesManager getCallbackDispatcherHandle]];
        [PreferencesManager setObservingRegion:YES];
    }
    // BUGFIX: Removed problematic else if that would stop/restart tracking incorrectly
    
    // Register BGAppRefreshTask handler (iOS 13+).
    // Must be registered before didFinishLaunchingWithOptions returns.
    if (@available(iOS 13.0, *)) {
        [[BGTaskScheduler sharedScheduler]
            registerForTaskWithIdentifier:kBGRefreshTaskId
            usingQueue:nil
            launchHandler:^(__kindof BGTask *task) {
                [self handleBGAppRefreshTask:task];
            }
        ];
        NSLog(@"[BackgroundLocator] BGAppRefreshTask handler registered");
    }
    
    // Note: if we return NO, this vetos the launch of the application.
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    if ([PreferencesManager isServiceRunning]) {
        [_locationManager startMonitoringSignificantLocationChanges];
    }
}

-(void)applicationWillTerminate:(UIApplication *)application {
    if([PreferencesManager isStopWithTerminate]){
        // Tracking should stop — removeLocator clears all regions, so don't create a geofence first
        [self removeLocator];
    } else {
        // BUGFIX: Use _currentLocation (updated on every valid location) instead of _lastLocation
        // _lastLocation is only set after moving 60m, so if app killed before 60m move, no geofence would be created
        [self observeRegionForLocation:_currentLocation ?: _lastLocation];
    }
}

#pragma mark - BGAppRefreshTask

/// Schedules the next BGAppRefreshTask wake-up.
///
/// iOS controls when this actually fires — the earliestBeginDate is a hint,
/// not a guarantee. Typical minimum is 15 minutes, actual timing may be longer.
- (void)scheduleBGAppRefreshTask {
    if (@available(iOS 13.0, *)) {
        BGAppRefreshTaskRequest *request =
            [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kBGRefreshTaskId];
        // Earliest wake-up: match the tracking interval, floor at 15 minutes.
        NSString *intervalStr = [[NSUserDefaults standardUserDefaults]
                                  stringForKey:@"flutter.trackingInterval"];
        NSTimeInterval interval = intervalStr ? [intervalStr doubleValue] : 900;
        if (interval < 900) interval = 900; // iOS enforces ~15 min minimum anyway
        request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:interval];
        
        NSError *error = nil;
        BOOL submitted = [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error];
        if (submitted) {
            NSLog(@"[BackgroundLocator] ✅ BGAppRefreshTask scheduled (earliest in %.0fs)", interval);
        } else {
            NSLog(@"[BackgroundLocator] ⚠️ BGAppRefreshTask submit failed: %@", error.localizedDescription);
        }
    }
}

/// Cancels any pending BGAppRefreshTask.
- (void)cancelBGAppRefreshTask {
    if (@available(iOS 13.0, *)) {
        [[BGTaskScheduler sharedScheduler] cancelTaskRequestWithIdentifier:kBGRefreshTaskId];
        NSLog(@"[BackgroundLocator] BGAppRefreshTask cancelled");
    }
}

/// Called by iOS when the BGAppRefreshTask fires (app may have been killed).
///
/// What this does:
/// 1. Restarts the headless Flutter runner so location callbacks work.
/// 2. Restarts location updates to get a fresh fix → triggers didUpdateLocations.
/// 3. Ensures significant location changes are active (fallback wake-up).
/// 4. Re-schedules the next BGAppRefreshTask so the chain continues.
/// 5. Completes the task after allowing time for a location fix.
- (void)handleBGAppRefreshTask:(BGTask *)task API_AVAILABLE(ios(13.0)) {
    NSLog(@"[BackgroundLocator] 🔔 BGAppRefreshTask fired — restarting tracking");
    
    // Guard: only restart if tracking was previously active
    if (![PreferencesManager isServiceRunning]) {
        NSLog(@"[BackgroundLocator] Service not running — skipping restart");
        [task setTaskCompletedWithSuccess:YES];
        return;
    }
    
    // Request background execution time for the restart + location fix
    UIBackgroundTaskIdentifier bgTaskId = [[BackgroundTaskHelper shared] begin:@"bgRefreshRestart"];
    
    // BUGFIX: Use a flag to prevent double-completion if both expiration and timer fire
    __block BOOL taskCompleted = NO;
    
    // Set expiration handler in case iOS reclaims before we finish
    task.expirationHandler = ^{
        NSLog(@"[BackgroundLocator] ⚠️ BGAppRefreshTask expired — cleaning up");
        // W1 FIX: Stop continuous GPS on expiration to prevent indeterminate GPS state
        [self->_locationManager stopUpdatingLocation];
        [[BackgroundTaskHelper shared] end:bgTaskId];
        if (!taskCompleted) {
            taskCompleted = YES;
            [task setTaskCompletedWithSuccess:NO];
        }
    };
    
    // 1. Restart the headless Flutter runner (so didUpdateLocations can call into Dart)
    int64_t callbackHandle = [PreferencesManager getCallbackDispatcherHandle];
    if (callbackHandle != 0) {
        [self startLocatorService:callbackHandle];
        NSLog(@"[BackgroundLocator] Headless runner restarted from BGAppRefreshTask");
    }
    
    // 2. Re-arm geofence immediately with last known location so we have coverage
    //    even if no new fix arrives within the 20s window
    CLLocation *rearmLocation = _currentLocation ?: _lastLocation;
    if (rearmLocation != nil) {
        [self observeRegionForLocation:rearmLocation];
        NSLog(@"[BackgroundLocator] Geofence re-armed at last known location");
    }
    
    // 3. Restart location updates and significant location changes
    [_locationManager startUpdatingLocation];
    [_locationManager startMonitoringSignificantLocationChanges];
    NSLog(@"[BackgroundLocator] Location updates restarted from BGAppRefreshTask");
    
    // 4. Re-schedule the next wake-up IMMEDIATELY so the chain continues
    [self scheduleBGAppRefreshTask];
    
    // 5. Allow ~20 seconds for a location fix to arrive and be processed,
    //    then STOP continuous GPS (geofence + SLC will handle next wake-up)
    //    to avoid battery drain from GPS running indefinitely.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSLog(@"[BackgroundLocator] BGAppRefreshTask window complete — stopping continuous GPS");
        [_locationManager stopUpdatingLocation]; // Stop GPS; geofence/SLC will wake next time
        [[BackgroundTaskHelper shared] end:bgTaskId];
        if (!taskCompleted) {
            taskCompleted = YES;
            [task setTaskCompletedWithSuccess:YES];
        }
    });
}

- (void) observeRegionForLocation:(CLLocation *)location {
    if (location == nil) {
        return;
    }
    
    // Stop monitoring all existing geofences
    for (CLRegion* existingRegion in [_locationManager monitoredRegions]) {
        [_locationManager stopMonitoringForRegion:existingRegion];
    }
    
    // Create moving geofence with 100m radius (better coverage than distanceFilter)
    CLCircularRegion* region = [[CLCircularRegion alloc] initWithCenter:location.coordinate
                                                         radius:_geofenceRadius
                                                     identifier:@"moving_geofence"];
    region.notifyOnEntry = NO;
    region.notifyOnExit = YES;
    
    [_locationManager startMonitoringForRegion:region];
    
    NSLog(@"[BackgroundLocator] Created moving geofence at lat=%.6f, lon=%.6f, radius=%.0fm", 
          location.coordinate.latitude, 
          location.coordinate.longitude, 
          _geofenceRadius);
}

- (void) prepareLocationMap:(CLLocation*) location {
    _lastLocation = location;
    NSDictionary<NSString*,NSNumber*>* locationMap = [Util getLocationMap:location];
    
    [self sendLocationEvent:locationMap];
}

#pragma mark LocationManagerDelegate Methods
- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (locations.count == 0) {
        return;
    }
    
    CLLocation* location = [locations lastObject];
    
    // Validate location quality
    if (location.horizontalAccuracy < 0) {
        NSLog(@"[BackgroundLocator] ⚠️ Invalid location (accuracy < 0) - skipping");
        return;
    }
    
    // CRITICAL: Always update current location for geofence creation on app termination
    _currentLocation = location;
    
    // CRITICAL: Request background execution time for the entire operation
    UIBackgroundTaskIdentifier bgTaskId = [[BackgroundTaskHelper shared] begin:@"locationUpdate"];
    
    // Distance filtering: Only log if moved more than distanceFilter from last logged location
    BOOL shouldLog = YES;
    double distanceFilter = [PreferencesManager getDistanceFilter];
    
    if (_lastLoggedLocation != nil) {
        CLLocationDistance distance = [location distanceFromLocation:_lastLoggedLocation];
        
        if (distance < distanceFilter) {
            shouldLog = NO;
            NSLog(@"[BackgroundLocator] Skipping - moved only %.1fm (< %.0fm threshold)", distance, distanceFilter);
        } else {
            NSLog(@"[BackgroundLocator] ✅ Moved %.1fm - processing location (accuracy: %.1fm)", distance, location.horizontalAccuracy);
        }
    } else {
        NSLog(@"[BackgroundLocator] First location - processing (accuracy: %.1fm)", location.horizontalAccuracy);
    }
    
    if (shouldLog) {
        // Update last logged location
        _lastLoggedLocation = location;
        
        // Send location to Flutter
        [self prepareLocationMap: location];
        
        // Update moving geofence to follow user
        [self observeRegionForLocation: location];
    }
    
    // Handle geofence wake-up scenario
    if([PreferencesManager isObservingRegion]) {
        // App was woken by geofence exit - continue tracking (don't stop!)
        [PreferencesManager setObservingRegion:NO];
        NSLog(@"[BackgroundLocator] App woken by geofence exit - continuing tracking");
    }
    
    // End background task
    [[BackgroundTaskHelper shared] end:bgTaskId];
}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region {
    NSLog(@"[BackgroundLocator] 🚪 Exited geofence: %@", region.identifier);
    
    // CRITICAL: Request background time so we don't get suspended before getting a location
    // iOS gives limited execution time when waking app from geofence
    UIBackgroundTaskIdentifier bgTaskId = [[BackgroundTaskHelper shared] begin:@"geofenceExit"];
    
    // Stop monitoring the old geofence
    [_locationManager stopMonitoringForRegion:region];
    
    // Start getting location updates (will create new geofence in didUpdateLocations)
    [_locationManager startUpdatingLocation];
    
    NSLog(@"[BackgroundLocator] 🔄 Restarted location updates after geofence exit");
    
    // End task after a delay to allow first location fix to arrive.
    // W5 FIX: Increased from 2s to 5s — cold GPS or indoor scenarios may need more time
    // for didUpdateLocations to fire and create its own background task.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[BackgroundTaskHelper shared] end:bgTaskId];
    });
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    NSLog(@"[BackgroundLocator] ❌ Location error: %@", error.localizedDescription);
    
    // Handle specific error codes
    if (error.code == kCLErrorDenied) {
        NSLog(@"[BackgroundLocator] Location permission denied by user");
        // Could notify Flutter here if needed
    } else if (error.code == kCLErrorLocationUnknown) {
        NSLog(@"[BackgroundLocator] Location temporarily unavailable - will retry");
        // This is transient, CLLocationManager will retry automatically
    }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    CLAuthorizationStatus status;
    
    if (@available(iOS 14.0, *)) {
        status = manager.authorizationStatus;
    } else {
        status = [CLLocationManager authorizationStatus];
    }
    
    NSLog(@"[BackgroundLocator] 🔐 Authorization changed to: %d", (int)status);
    
    switch (status) {
        case kCLAuthorizationStatusNotDetermined:
            NSLog(@"[BackgroundLocator] Permission not determined yet");
            break;
            
        case kCLAuthorizationStatusRestricted:
            NSLog(@"[BackgroundLocator] ❌ Location permission restricted (parental controls or MDM)");
            break;
            
        case kCLAuthorizationStatusDenied:
            NSLog(@"[BackgroundLocator] ❌ Location permission denied by user");
            break;
            
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            NSLog(@"[BackgroundLocator] ⚠️ Only 'When In Use' permission granted - background tracking requires 'Always'");
            // Request upgrade to Always if service should be running
            if ([PreferencesManager isServiceRunning]) {
                [_locationManager requestAlwaysAuthorization];
            }
            break;
            
        case kCLAuthorizationStatusAuthorizedAlways:
            NSLog(@"[BackgroundLocator] ✅ 'Always' permission granted");
            
            // Start tracking if service should be running
            if ([PreferencesManager isServiceRunning]) {
                // Bootstrap _currentLocation from last known position
                CLLocation *lastKnown = [_locationManager location];
                if (lastKnown != nil && lastKnown.horizontalAccuracy >= 0) {
                    _currentLocation = lastKnown;
                    [self observeRegionForLocation:lastKnown];
                    NSLog(@"[BackgroundLocator] Initial geofence created from last known location (accuracy: %.1fm)", lastKnown.horizontalAccuracy);
                }
                
                // Start location updates
                [_locationManager startUpdatingLocation];
                [_locationManager startMonitoringSignificantLocationChanges];
                
                NSLog(@"[BackgroundLocator] ✅ Location tracking started after permission grant");
            }
            break;
            
        default:
            NSLog(@"[BackgroundLocator] Unknown authorization status: %d", (int)status);
            break;
    }
}

- (void)locationManager:(CLLocationManager *)manager monitoringDidFailForRegion:(CLRegion *)region withError:(NSError *)error {
    NSLog(@"[BackgroundLocator] ❌ Geofence monitoring failed for %@: %@", region.identifier, error.localizedDescription);
    
    // BUGFIX: Use _currentLocation (updated on every valid fix) first, fall back to _lastLocation.
    // _lastLocation is nil until the user has moved 60m, so recovery would silently fail without this.
    CLLocation *recoveryLocation = _currentLocation ?: _lastLocation;
    if (recoveryLocation != nil) {
        NSLog(@"[BackgroundLocator] Attempting to recreate geofence");
        [self observeRegionForLocation:recoveryLocation];
    }
}

#pragma mark LocatorPlugin Methods
- (void) sendLocationEvent: (NSDictionary<NSString*,NSNumber*>*)location {
    NSDictionary *map = @{
                     kArgCallback : @([PreferencesManager getCallbackHandle:kCallbackKey]),
                     kArgLocation: location
                     };
    
    NSString *isolateId = [_headlessRunner isolateId];
    if (_callbackChannel == nil || isolateId == nil) {
        // Isolate not ready yet (first-run warmup) — buffer and retry
        if (_pendingLocationMaps == nil) {
            _pendingLocationMaps = [NSMutableArray array];
        }
        if (_pendingLocationMaps.count < 10) { // Cap buffer at 10 locations
            [_pendingLocationMaps addObject:map];
            NSLog(@"[BackgroundLocator] Isolate not ready — buffered location (%lu pending)", (unsigned long)_pendingLocationMaps.count);
        }
        // Start flush timer if not already running
        if (_flushTimer == nil) {
            _flushTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          target:self
                                                        selector:@selector(flushPendingLocations)
                                                        userInfo:nil
                                                         repeats:YES];
        }
        return;
    }
    
    // Flush any buffered locations before sending the new one
    [self flushPendingLocations];
    
    [_callbackChannel invokeMethod:kBCMSendLocation arguments:map];
}

- (void)flushPendingLocations {
    NSString *isolateId = [_headlessRunner isolateId];
    if (_callbackChannel == nil || isolateId == nil) {
        return; // Still not ready — timer will retry
    }
    
    // Stop the retry timer
    if (_flushTimer != nil) {
        [_flushTimer invalidate];
        _flushTimer = nil;
    }
    
    if (_pendingLocationMaps.count == 0) {
        return;
    }
    
    NSLog(@"[BackgroundLocator] Isolate ready — flushing %lu buffered location(s)", (unsigned long)_pendingLocationMaps.count);
    for (NSDictionary *pendingMap in _pendingLocationMaps) {
        [_callbackChannel invokeMethod:kBCMSendLocation arguments:pendingMap];
    }
    [_pendingLocationMaps removeAllObjects];
}

- (instancetype)init:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    
    _headlessRunner = [[FlutterEngine alloc] initWithName:@"LocatorIsolate" project:nil allowHeadlessExecution:YES];
    _registrar = registrar;
    [self prepareLocationManager];
    
    _mainChannel = [FlutterMethodChannel methodChannelWithName:kChannelId
                                               binaryMessenger:[registrar messenger]];
    [registrar addMethodCallDelegate:self channel:_mainChannel];
    
    _callbackChannel =
    [FlutterMethodChannel methodChannelWithName:kBackgroundChannelId
                                binaryMessenger:[_headlessRunner binaryMessenger] ];
    return self;
}

- (void) prepareLocationManager {
    _locationManager = [[CLLocationManager alloc] init];
    [_locationManager setDelegate:self];
    _locationManager.pausesLocationUpdatesAutomatically = NO;
    _geofenceRadius = 100.0;  // Default 100m geofence radius
}

#pragma mark MethodCallHelperDelegate

- (void)startLocatorService:(int64_t)handle {
    [PreferencesManager setCallbackDispatcherHandle:handle];
    FlutterCallbackInformation *info = [FlutterCallbackCache lookupCallbackInformation:handle];
    if (info == nil) {
        NSLog(@"[BackgroundLocator] ❌ Failed to find callback info for handle %lld — aborting service start", handle);
        return;
    }
    
    // C1 FIX: If the engine already has a live isolate, don't restart it.
    // FlutterEngine.runWithEntrypoint silently returns NO on a second call,
    // so we must check and recreate the engine if the isolate is dead.
    NSString *existingIsolate = [_headlessRunner isolateId];
    if (existingIsolate != nil) {
        NSLog(@"[BackgroundLocator] Headless runner already active (isolate=%@) — skipping restart", existingIsolate);
        return;
    }
    
    // Recreate engine since the previous one's isolate is dead
    _headlessRunner = [[FlutterEngine alloc] initWithName:@"LocatorIsolate" project:nil allowHeadlessExecution:YES];
    _callbackChannel = [FlutterMethodChannel methodChannelWithName:kBackgroundChannelId
                                                   binaryMessenger:[_headlessRunner binaryMessenger]];
    
    NSString *entrypoint = info.callbackName;
    NSString *uri = info.callbackLibraryPath;
    [_headlessRunner runWithEntrypoint:entrypoint libraryURI:uri];
    
    if (registerPlugins == nil) {
        NSLog(@"[BackgroundLocator] ❌ registerPlugins not set — aborting headless registration");
        return;
    }

    // Register plugins every time — the headless runner is recreated on each start
    registerPlugins(_headlessRunner);
    
    [_registrar addMethodCallDelegate:self channel:_callbackChannel];
}

- (void)registerLocator:(int64_t)callback
           initCallback:(int64_t)initCallback
  initialDataDictionary:(NSDictionary*)initialDataDictionary
        disposeCallback:(int64_t)disposeCallback
               settings: (NSDictionary*)settings {
    // Check current authorization status before requesting
    CLAuthorizationStatus currentStatus;
    if (@available(iOS 14.0, *)) {
        currentStatus = _locationManager.authorizationStatus;
    } else {
        currentStatus = [CLLocationManager authorizationStatus];
    }
    
    NSLog(@"[BackgroundLocator] Current authorization status: %d", (int)currentStatus);
    
    // Request authorization if not already granted
    if (currentStatus != kCLAuthorizationStatusAuthorizedAlways) {
        NSLog(@"[BackgroundLocator] Requesting 'Always' authorization...");
        [self->_locationManager requestAlwaysAuthorization];
    }
        
    long accuracyKey = [[settings objectForKey:kSettingsAccuracy] longValue];
    CLLocationAccuracy accuracy = [Util getAccuracy:accuracyKey];
    double distanceFilter= [[settings objectForKey:kSettingsDistanceFilter] doubleValue];
    bool  showsBackgroundLocationIndicator=[[settings objectForKey:kSettingsShowsBackgroundLocationIndicator] boolValue];
    bool  stopWithTerminate=[[settings objectForKey:kSettingsStopWithTerminate] boolValue];

    // iOS 16.4+ compatible configuration
    _locationManager.desiredAccuracy = accuracy;
    _locationManager.distanceFilter = kCLDistanceFilterNone;  // Critical for iOS 16.4+ - filter in code instead
    _locationManager.activityType = CLActivityTypeOtherNavigation;  // Optimized for continuous tracking
    
    if (@available(iOS 11.0, *)) {
      _locationManager.showsBackgroundLocationIndicator = showsBackgroundLocationIndicator;
    }
    
    if (@available(iOS 9.0, *)) {
        _locationManager.allowsBackgroundLocationUpdates = YES;
    }
    
    [PreferencesManager saveDistanceFilter:distanceFilter];
    [PreferencesManager setStopWithTerminate:stopWithTerminate];

    [PreferencesManager setCallbackHandle:callback key:kCallbackKey];
    
    InitPluggable *initPluggable = [[InitPluggable alloc] init];
    [initPluggable setCallback:initCallback];
    [initPluggable onServiceStart:initialDataDictionary];
    
    DisposePluggable *disposePluggable = [[DisposePluggable alloc] init];
    [disposePluggable setCallback:disposeCallback];
    
    // Start iOS 17+ background activity session
    [[BackgroundActivitySessionManager shared] start];
    
    // Start iOS 18+ service session
    [[ServiceSessionManager shared] start];
    
    // Reset last logged location when starting tracking
    _lastLoggedLocation = nil;
    
    // Bootstrap _currentLocation from last known position so a geofence exists
    // even if the user kills the app before the first live GPS fix arrives
    CLLocation *lastKnown = [_locationManager location];
    if (lastKnown != nil && lastKnown.horizontalAccuracy >= 0) {
        _currentLocation = lastKnown;
        [self observeRegionForLocation:lastKnown];
        NSLog(@"[BackgroundLocator] Initial geofence bootstrapped from last known location (accuracy: %.1fm)", lastKnown.horizontalAccuracy);
    }
    
    // Only start location updates if we already have 'Always' permission
    // Otherwise, wait for locationManagerDidChangeAuthorization callback
    if (currentStatus == kCLAuthorizationStatusAuthorizedAlways) {
        [_locationManager startUpdatingLocation];
        [_locationManager startMonitoringSignificantLocationChanges];
        NSLog(@"[BackgroundLocator] ✅ Started location updates (permission already granted)");
    } else {
        NSLog(@"[BackgroundLocator] ⏳ Waiting for authorization grant before starting location updates");
    }
    
    // Schedule BGAppRefreshTask so iOS can wake the app even when killed
    [self scheduleBGAppRefreshTask];
    
    NSLog(@"[BackgroundLocator] Tracking started with iOS 16.4+ configuration (distanceFilter in code: %.0fm, geofence: %.0fm)", distanceFilter, _geofenceRadius);
    NSLog(@"[BackgroundLocator] iOS 17/18 sessions started for enhanced background reliability");
}

- (void)removeLocator {
    if (_locationManager == nil) {
        return;
    }
    
    // Request background time for cleanup
    UIBackgroundTaskIdentifier bgTaskId = [[BackgroundTaskHelper shared] begin:@"stopTracking"];
    
    @synchronized (self) {
        [_locationManager stopUpdatingLocation];
        
        if (@available(iOS 9.0, *)) {
            _locationManager.allowsBackgroundLocationUpdates = NO;
        }
        
        [_locationManager stopMonitoringSignificantLocationChanges];

        for (CLRegion* region in [_locationManager monitoredRegions]) {
            [_locationManager stopMonitoringForRegion:region];
        }
        
        // Reset tracking state
        _lastLoggedLocation = nil;
    }
    
    // Stop iOS 17+ background activity session
    [[BackgroundActivitySessionManager shared] stop];
    
    // Stop iOS 18+ service session
    [[ServiceSessionManager shared] stop];
    
    // Cancel pending BGAppRefreshTask — tracking is intentionally stopped
    [self cancelBGAppRefreshTask];
    
    DisposePluggable *disposePluggable = [[DisposePluggable alloc] init];
    [disposePluggable onServiceDispose];
    
    NSLog(@"[BackgroundLocator] Tracking stopped and cleaned up");
    
    // End background task
    [[BackgroundTaskHelper shared] end:bgTaskId];
}

- (void) setServiceRunning:(BOOL) value {
    @synchronized(self) {
        [PreferencesManager setServiceRunning:value];
    }
}

- (BOOL)isServiceRunning{
    return [PreferencesManager isServiceRunning];
}

- (BOOL)isStopWithTerminate{
    return [PreferencesManager isStopWithTerminate];
}

@end
