#import "BackgroundTaskHelper.h"

@implementation BackgroundTaskHelper {
    NSMutableDictionary<NSNumber *, NSString *> *_activeTasks;
    dispatch_queue_t _queue;
}

+ (instancetype)shared {
    static BackgroundTaskHelper *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BackgroundTaskHelper alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _activeTasks = [NSMutableDictionary dictionary];
        _queue = dispatch_queue_create("com.backgroundlocator.backgroundTask", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (UIBackgroundTaskIdentifier)begin:(NSString *)name {
    __block UIBackgroundTaskIdentifier taskId = UIBackgroundTaskInvalid;
    
    taskId = [[UIApplication sharedApplication] beginBackgroundTaskWithName:[NSString stringWithFormat:@"com.backgroundlocator.%@", name]
                                                          expirationHandler:^{
        NSLog(@"[BackgroundLocator] ⚠️ Background task '%@' expired by iOS — ending", name);
        // BUGFIX: Call endBackgroundTask directly to guarantee it runs
        // taskId is now assigned its real value (captured by __block)
        if (taskId != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:taskId];
            // Use dispatch_async (not dispatch_sync) to avoid deadlock if iOS
            // calls the expiration handler on our serial queue
            dispatch_async(self->_queue, ^{
                [self->_activeTasks removeObjectForKey:@(taskId)];
            });
        }
    }];
    
    if (taskId == UIBackgroundTaskInvalid) {
        NSLog(@"[BackgroundLocator] Background task '%@' denied by iOS", name);
        return UIBackgroundTaskInvalid;
    }
    
    dispatch_sync(_queue, ^{
        self->_activeTasks[@(taskId)] = name;
    });
    
    NSLog(@"[BackgroundLocator] Background task '%@' started (id=%lu)", name, (unsigned long)taskId);
    return taskId;
}

- (void)end:(UIBackgroundTaskIdentifier)taskId {
    if (taskId == UIBackgroundTaskInvalid) {
        return;
    }
    
    __block NSString *name = nil;
    dispatch_sync(_queue, ^{
        name = self->_activeTasks[@(taskId)];
        [self->_activeTasks removeObjectForKey:@(taskId)];
    });
    
    if (name == nil) {
        return;
    }
    
    [[UIApplication sharedApplication] endBackgroundTask:taskId];
    NSLog(@"[BackgroundLocator] Background task '%@' ended (id=%lu)", name, (unsigned long)taskId);
}

@end
