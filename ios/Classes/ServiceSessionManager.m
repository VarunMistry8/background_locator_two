#import "ServiceSessionManager.h"

@implementation ServiceSessionManager {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000
    CLServiceSession *_session API_AVAILABLE(ios(18.0));
#endif
}

+ (instancetype)shared {
    static ServiceSessionManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ServiceSessionManager alloc] init];
    });
    return instance;
}

- (void)start {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000
    if (@available(iOS 18.0, *)) {
        if (_session != nil) {
            NSLog(@"[BackgroundLocator] CLServiceSession already active");
            return;
        }
        _session = [CLServiceSession sessionRequiringAuthorization:CLServiceSessionAuthorizationRequirementAlways];
        NSLog(@"[BackgroundLocator] CLServiceSession started");
    }
#endif
}

- (void)stop {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000
    if (@available(iOS 18.0, *)) {
        if (_session == nil) {
            return;
        }
        if ([_session respondsToSelector:@selector(invalidate)]) {
            [_session performSelector:@selector(invalidate)];
        }
        _session = nil;
        NSLog(@"[BackgroundLocator] CLServiceSession stopped");
    }
#endif
}

@end
