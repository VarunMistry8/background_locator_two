#import "BackgroundActivitySessionManager.h"

@implementation BackgroundActivitySessionManager {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000
  CLBackgroundActivitySession *_session API_AVAILABLE(ios(17.0));
#endif
}

+ (instancetype)shared {
  static BackgroundActivitySessionManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[BackgroundActivitySessionManager alloc] init];
  });
  return instance;
}

- (void)start {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000
  if (@available(iOS 17.0, *)) {
    if (_session != nil) {
      NSLog(@"[BackgroundLocator] CLBackgroundActivitySession already active");
      return;
    }
    _session = [CLBackgroundActivitySession backgroundActivitySession];
    NSLog(@"[BackgroundLocator] CLBackgroundActivitySession started");
  }
#endif
}

- (void)stop {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000
  if (@available(iOS 17.0, *)) {
    if (_session == nil) {
      return;
    }
    [_session invalidate];
    _session = nil;
    NSLog(@"[BackgroundLocator] CLBackgroundActivitySession stopped");
  }
#endif
}

@end
