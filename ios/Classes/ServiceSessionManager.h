#import <Foundation/Foundation.h>

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000
#import <CoreLocation/CoreLocation.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface ServiceSessionManager : NSObject

+ (instancetype)shared;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
