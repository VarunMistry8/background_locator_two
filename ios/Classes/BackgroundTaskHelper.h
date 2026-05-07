#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BackgroundTaskHelper : NSObject

+ (instancetype)shared;

- (UIBackgroundTaskIdentifier)begin:(NSString *)name;
- (void)end:(UIBackgroundTaskIdentifier)taskId;

@end

NS_ASSUME_NONNULL_END
