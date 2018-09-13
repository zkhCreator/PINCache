//  PINCache is a modified version of TMCache
//  Modifications by Garrett Moon
//  Copyright (c) 2015 Pinterest. All rights reserved.

#import "PINMemoryCache.h"

#import <pthread.h>
#import <PINOperation/PINOperation.h>

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
#import <UIKit/UIKit.h>
#endif

static NSString * const PINMemoryCachePrefix = @"com.pinterest.PINMemoryCache";
static NSString * const PINMemoryCacheSharedName = @"PINMemoryCacheSharedName";

@interface PINMemoryCache ()
@property (copy, nonatomic) NSString *name;
@property (strong, nonatomic) PINOperationQueue *operationQueue;
@property (assign, nonatomic) pthread_mutex_t mutex;
@property (strong, nonatomic) NSMutableDictionary *dictionary;
@property (strong, nonatomic) NSMutableDictionary *createdDates;
@property (strong, nonatomic) NSMutableDictionary *accessDates;
@property (strong, nonatomic) NSMutableDictionary *costs;
@property (strong, nonatomic) NSMutableDictionary *ageLimits;
@end

@implementation PINMemoryCache

@synthesize name = _name;
@synthesize ageLimit = _ageLimit;
@synthesize costLimit = _costLimit;
@synthesize totalCost = _totalCost;
@synthesize ttlCache = _ttlCache;
@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize didReceiveMemoryWarningBlock = _didReceiveMemoryWarningBlock;
@synthesize didEnterBackgroundBlock = _didEnterBackgroundBlock;

#pragma mark - Initialization -

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    __unused int result = pthread_mutex_destroy(&_mutex);
    NSCAssert(result == 0, @"Failed to destroy lock in PINMemoryCache %p. Code: %d", (void *)self, result);
}

- (instancetype)init
{
    return [self initWithOperationQueue:[PINOperationQueue sharedOperationQueue]];
}

- (instancetype)initWithOperationQueue:(PINOperationQueue *)operationQueue
{
    return [self initWithName:PINMemoryCacheSharedName operationQueue:operationQueue];
}

- (instancetype)initWithName:(NSString *)name operationQueue:(PINOperationQueue *)operationQueue
{
    return [self initWithName:name operationQueue:operationQueue ttlCache:NO];
}

- (instancetype)initWithName:(NSString *)name operationQueue:(PINOperationQueue *)operationQueue ttlCache:(BOOL)ttlCache
{
    if (self = [super init]) {
        __unused int result = pthread_mutex_init(&_mutex, NULL);
        NSAssert(result == 0, @"Failed to init lock in PINMemoryCache %@. Code: %d", self, result);
        
        _name = [name copy];
        _operationQueue = operationQueue;
        _ttlCache = ttlCache;
        
        _dictionary = [[NSMutableDictionary alloc] init];
        _createdDates = [[NSMutableDictionary alloc] init];
        _accessDates = [[NSMutableDictionary alloc] init];
        _costs = [[NSMutableDictionary alloc] init];
        _ageLimits = [[NSMutableDictionary alloc] init];
        
        _willAddObjectBlock = nil;
        _willRemoveObjectBlock = nil;
        _willRemoveAllObjectsBlock = nil;
        
        _didAddObjectBlock = nil;
        _didRemoveObjectBlock = nil;
        _didRemoveAllObjectsBlock = nil;
        
        _didReceiveMemoryWarningBlock = nil;
        _didEnterBackgroundBlock = nil;
        
        _ageLimit = 0.0;
        _costLimit = 0;
        _totalCost = 0;
        
        _removeAllObjectsOnMemoryWarning = YES;
        _removeAllObjectsOnEnteringBackground = YES;
        
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0 && !TARGET_OS_WATCH
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveEnterBackgroundNotification:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarningNotification:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        
#endif
    }
    return self;
}

+ (PINMemoryCache *)sharedCache
{
    static PINMemoryCache *cache;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        cache = [[PINMemoryCache alloc] init];
    });

    return cache;
}

#pragma mark - Private Methods -

// 收到系统通知之后清理缓存
- (void)didReceiveMemoryWarningNotification:(NSNotification *)notification {
    if (self.removeAllObjectsOnMemoryWarning)
        [self removeAllObjectsAsync:nil];

    [self removeExpiredObjects];

    [self.operationQueue scheduleOperation:^{
        [self lock];
            PINCacheBlock didReceiveMemoryWarningBlock = self->_didReceiveMemoryWarningBlock;
        [self unlock];
        
        if (didReceiveMemoryWarningBlock)
            didReceiveMemoryWarningBlock(self);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 进入后台之后清理缓存
- (void)didReceiveEnterBackgroundNotification:(NSNotification *)notification
{
    if (self.removeAllObjectsOnEnteringBackground)
        [self removeAllObjectsAsync:nil];

    [self.operationQueue scheduleOperation:^{
        [self lock];
            PINCacheBlock didEnterBackgroundBlock = self->_didEnterBackgroundBlock;
        [self unlock];

        if (didEnterBackgroundBlock)
            didEnterBackgroundBlock(self);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 删除对应的对象并执行对应的 value
- (void)removeObjectAndExecuteBlocksForKey:(NSString *)key
{
    // 加锁，增加前置和后置操作
    [self lock];
        id object = _dictionary[key];
        NSNumber *cost = _costs[key];
        PINCacheObjectBlock willRemoveObjectBlock = _willRemoveObjectBlock;
        PINCacheObjectBlock didRemoveObjectBlock = _didRemoveObjectBlock;
    [self unlock];

    // 前置操作
    if (willRemoveObjectBlock)
        willRemoveObjectBlock(self, key, object);

    [self lock];
        // 在所有对象中移除这个缓存的对象
        if (cost)
            _totalCost -= [cost unsignedIntegerValue];

        [_dictionary removeObjectForKey:key];
        [_createdDates removeObjectForKey:key];
        [_accessDates removeObjectForKey:key];
        [_costs removeObjectForKey:key];
        [_ageLimits removeObjectForKey:key];
    [self unlock];
    
    if (didRemoveObjectBlock)
        didRemoveObjectBlock(self, key, nil);
}

// 根据过期时间进行清理，如果超过就清除
- (void)trimMemoryToDate:(NSDate *)trimDate
{
    [self lock];
        NSArray *keysSortedByCreatedDate = [_createdDates keysSortedByValueUsingSelector:@selector(compare:)];
        NSDictionary *createdDates = [_createdDates copy];
        NSDictionary *ageLimits = [_ageLimits copy];
    [self unlock];
    
    for (NSString *key in keysSortedByCreatedDate) { // oldest objects first
        NSDate *createdDate = createdDates[key];
        NSTimeInterval ageLimit = [ageLimits[key] doubleValue];
        if (!createdDate || ageLimit > 0.0)
            continue;
        
        if ([createdDate compare:trimDate] == NSOrderedAscending) { // older than trim date
            [self removeObjectAndExecuteBlocksForKey:key];
        } else {
            break;
        }
    }
}

// 删除所有时间过期的对象
- (void)removeExpiredObjects
{
    //  对读取时间进行加锁，保证能够数据正确
    [self lock];
        NSDictionary<NSString *, NSDate *> *createdDates = [_createdDates copy];
        NSDictionary<NSString *, NSNumber *> *ageLimits = [_ageLimits copy];
        NSTimeInterval globalAgeLimit = self->_ageLimit;
    //  对读取时间进行解锁
    [self unlock];

    // 根据当前时间判断这个对象是否需要进行移除
    NSDate *now = [NSDate date];
    for (NSString *key in ageLimits) {
        NSDate *createdDate = createdDates[key];
        NSTimeInterval ageLimit = [ageLimits[key] doubleValue] ?: globalAgeLimit;
        if (!createdDate)
            continue;

        NSDate *expirationDate = [createdDate dateByAddingTimeInterval:ageLimit];
        if ([expirationDate compare:now] == NSOrderedAscending) { // Expiration date has passed
            // 移除对应对象
            [self removeObjectAndExecuteBlocksForKey:key];
        }
    }
}

// 根据空间大小来处理对应超过限制的对象
- (void)trimToCostLimit:(NSUInteger)limit
{
    // 总量默认为 0
    NSUInteger totalCost = 0;
    
    // 锁定
    [self lock];
    // 将现在已经有的总量进行赋值
        totalCost = _totalCost;
    // 对所有的总量进行排序获得顺序对象
        NSArray *keysSortedByCost = [_costs keysSortedByValueUsingSelector:@selector(compare:)];
    [self unlock];
    
    // 如果未超过，那么直接进行返回
    if (totalCost <= limit) {
        return;
    }

    //  反向删除，如果内容小于限制了就不再删除，空间最大的先删除
    for (NSString *key in [keysSortedByCost reverseObjectEnumerator]) { // costliest objects first
        [self removeObjectAndExecuteBlocksForKey:key];

        [self lock];
            totalCost = _totalCost;
        [self unlock];
        
        if (totalCost <= limit)
            break;
    }
}

// 根据总共占空间的限制是否超过进行删除
- (void)trimToCostLimitByDate:(NSUInteger)limit
{
    //  判断这个对象是否有缓存状态
    if (self.isTTLCache) {
        // 尝试移除已经超过时间的对象
        [self removeExpiredObjects];
    }

    // 初始化总量
    NSUInteger totalCost = 0;
    
    [self lock];
    
    // 将现在已经有的总量进行赋值
        totalCost = _totalCost;
    // 对所有的时间进行排序获得顺序对象
        NSArray *keysSortedByAccessDate = [_accessDates keysSortedByValueUsingSelector:@selector(compare:)];
    [self unlock];
    
    if (totalCost <= limit)
        return;

    // 同样进行移除
    for (NSString *key in keysSortedByAccessDate) { // oldest objects first
        [self removeObjectAndExecuteBlocksForKey:key];

        [self lock];
            totalCost = _totalCost;
        [self unlock];
        if (totalCost <= limit)
            break;
    }
}

// 根据生命周期进行限制
- (void)trimToAgeLimitRecursively
{
    // 获得最长生命周期时间
    [self lock];
        NSTimeInterval ageLimit = _ageLimit;
    [self unlock];
    
    if (ageLimit == 0.0)
        return;

    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-ageLimit];
    
    // 先根据时间清理一波
    [self trimMemoryToDate:date];
    
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ageLimit * NSEC_PER_SEC));
    dispatch_after(time, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        // Ensure that ageLimit is the same as when we were scheduled, otherwise, we've been
        // rescheduled (another dispatch_after was issued) and should cancel.
        BOOL shouldReschedule = YES;
        [self lock];
        // 保证每次清除的都是和当前 PINMemoryCache 的时间一致的。
            if (ageLimit != self->_ageLimit) {
                shouldReschedule = NO;
            }
        [self unlock];
        
        if (shouldReschedule) {
            [self.operationQueue scheduleOperation:^{
                // 递归清除
                [self trimToAgeLimitRecursively];
            } withPriority:PINOperationQueuePriorityHigh];
        }
    });
}

#pragma mark - Public Asynchronous Methods -

// 异步获得对应的键值对是否有效
- (void)containsObjectForKeyAsync:(NSString *)key completion:(PINCacheObjectContainmentBlock)block
{
    // 保证 key value 有效
    if (!key || !block)
        return;
    
    [self.operationQueue scheduleOperation:^{
        BOOL containsObject = [self containsObjectForKey:key];
        
        block(containsObject);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 异步获得对象
- (void)objectForKeyAsync:(NSString *)key completion:(PINCacheObjectBlock)block
{
    if (block == nil) {
      return;
    }
    
    [self.operationQueue scheduleOperation:^{
        id object = [self objectForKey:key];
        
        block(self, key, object);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 异步设置对象，递进
- (void)setObjectAsync:(id)object forKey:(NSString *)key completion:(PINCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key withCost:0 completion:block];
}

// 异步设置对象，递进
- (void)setObjectAsync:(id)object forKey:(NSString *)key withAgeLimit:(NSTimeInterval)ageLimit completion:(PINCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key withCost:0 ageLimit:ageLimit completion:block];
}

// 异步设置对象，递进
- (void)setObjectAsync:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost completion:(PINCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key withCost:cost ageLimit:0.0 completion:block];
}

// 异步设置对象，递进
- (void)setObjectAsync:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost ageLimit:(NSTimeInterval)ageLimit completion:(PINCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self setObject:object forKey:key withCost:cost ageLimit:ageLimit];
        
        if (block)
            block(self, key, object);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 异步移除对象
- (void)removeObjectForKeyAsync:(NSString *)key completion:(PINCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self removeObjectForKey:key];
        
        if (block)
            block(self, key, nil);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 异步根据时间删除对象
- (void)trimToDateAsync:(NSDate *)trimDate completion:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self trimToDate:trimDate];
        
        if (block)
            block(self);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 异步根据空间占有量删除对象
- (void)trimToCostAsync:(NSUInteger)cost completion:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self trimToCost:cost];
        
        if (block)
            block(self);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 异步根据使用时间删除对象
- (void)trimToCostByDateAsync:(NSUInteger)cost completion:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self trimToCostByDate:cost];
        
        if (block)
            block(self);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 异步根据超时删除对象
- (void)removeExpiredObjectsAsync:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self removeExpiredObjects];

        if (block)
            block(self);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 异步删除所有对象
- (void)removeAllObjectsAsync:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self removeAllObjects];
        
        if (block)
            block(self);
    } withPriority:PINOperationQueuePriorityHigh];
}

// 遍历所有有效对象
- (void)enumerateObjectsWithBlockAsync:(PINCacheObjectEnumerationBlock)block completionBlock:(PINCacheBlock)completionBlock
{
    [self.operationQueue scheduleOperation:^{
        [self enumerateObjectsWithBlock:block];
        
        if (completionBlock)
            completionBlock(self);
    } withPriority:PINOperationQueuePriorityHigh];
}

#pragma mark - Public Synchronous Methods -
// 同步检查时候存在
- (BOOL)containsObjectForKey:(NSString *)key
{
    // 键是否有效，否则直接返回不存在
    if (!key)
        return NO;
    
    // 锁定
    [self lock];
    // 值中是否存在
        BOOL containsObject = (_dictionary[key] != nil);
    [self unlock];
    return containsObject;
}

// 同步获得对象
- (nullable id)objectForKey:(NSString *)key
{
    if (!key)
        return nil;
    
    NSDate *now = [NSDate date];
    [self lock];
        id object = nil;
        // If the cache should behave like a TTL cache, then only fetch the object if there's a valid ageLimit and  the object is still alive
        NSTimeInterval ageLimit = [_ageLimits[key] doubleValue] ?: self->_ageLimit;
    // 只有有效的值才能返回
        if (!self->_ttlCache || ageLimit <= 0 || fabs([[_createdDates objectForKey:key] timeIntervalSinceDate:now]) < ageLimit) {
            object = _dictionary[key];
        }
    [self unlock];
    
    // 更新最近一次的使用时间
    if (object) {
        [self lock];
            _accessDates[key] = now;
        [self unlock];
    }

    return object;
}

// 根据 key 进行存储
- (id)objectForKeyedSubscript:(NSString *)key
{
    return [self objectForKey:key];
}

// 递进调用
- (void)setObject:(id)object forKey:(NSString *)key
{
    [self setObject:object forKey:key withCost:0];
}

// 递进调用
- (void)setObject:(id)object forKey:(NSString *)key withAgeLimit:(NSTimeInterval)ageLimit
{
    [self setObject:object forKey:key withCost:0 ageLimit:ageLimit];
}

// 递进调用
- (void)setObject:(id)object forKeyedSubscript:(NSString *)key
{
    if (object == nil) {
        [self removeObjectForKey:key];
    } else {
        [self setObject:object forKey:key];
    }
}

// 递进调用
- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost
{
    [self setObject:object forKey:key withCost:cost ageLimit:0.0];
}

- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost ageLimit:(NSTimeInterval)ageLimit
{
    NSAssert(ageLimit <= 0.0 || (ageLimit > 0.0 && _ttlCache), @"ttlCache must be set to YES if setting an object-level age limit.");
    // 保证键值对有效
    if (!key || !object)
        return;
    
    // 锁定，用于设定前置操作和后置操作和容量限制
    [self lock];
        PINCacheObjectBlock willAddObjectBlock = _willAddObjectBlock;
        PINCacheObjectBlock didAddObjectBlock = _didAddObjectBlock;
        NSUInteger costLimit = _costLimit;
    [self unlock];
    
    // 先执行添加前置操作
    if (willAddObjectBlock)
        willAddObjectBlock(self, key, object);
    
    // 锁定，开始进行操作
    [self lock];
    // 需要添加的内容的原始大小
        NSNumber* oldCost = _costs[key];
        if (oldCost)
            // 删除原始大小
            _totalCost -= [oldCost unsignedIntegerValue];

        // 创建当前更新的时间
        NSDate *now = [NSDate date];
        _dictionary[key] = object;  // 缓存值
        _createdDates[key] = now;   // 第一次被创建的时间
        _accessDates[key] = now;    //  最近一次使用的时间
        _costs[key] = @(cost);  // 就算完的新的值的大小

        if (ageLimit > 0.0) {
            // 如果有缓存，那么就确定一个缓存时间长度
            _ageLimits[key] = @(ageLimit);
        } else {
            // 不再需要缓存
            [_ageLimits removeObjectForKey:key];
        }
        // 计算出总大小
        _totalCost += cost;
    [self unlock];
    
    // 完成添加
    if (didAddObjectBlock)
        didAddObjectBlock(self, key, object);
    
    // 超过限制，然后就进行分割
    if (costLimit > 0)
        [self trimToCostByDate:costLimit];
}

// 移除对应的 key 的对象
- (void)removeObjectForKey:(NSString *)key
{
    // 判断值是否有效
    if (!key)
        return;
    
    // 移除这个对象
    [self removeObjectAndExecuteBlocksForKey:key];
}

- (void)trimToDate:(NSDate *)trimDate
{
    if (!trimDate)
        return;
    
    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }
    
    [self trimMemoryToDate:trimDate];
}

- (void)trimToCost:(NSUInteger)cost
{
    [self trimToCostLimit:cost];
}

- (void)trimToCostByDate:(NSUInteger)cost
{
    [self trimToCostLimitByDate:cost];
}

- (void)removeAllObjects
{
    [self lock];
        PINCacheBlock willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
        PINCacheBlock didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
    [self unlock];
    
    if (willRemoveAllObjectsBlock)
        willRemoveAllObjectsBlock(self);
    
    [self lock];
        [_dictionary removeAllObjects];
        [_createdDates removeAllObjects];
        [_accessDates removeAllObjects];
        [_costs removeAllObjects];
        [_ageLimits removeAllObjects];
    
        _totalCost = 0;
    [self unlock];
    
    if (didRemoveAllObjectsBlock)
        didRemoveAllObjectsBlock(self);
    
}

// 枚举同步调用所有对象
- (void)enumerateObjectsWithBlock:(PIN_NOESCAPE PINCacheObjectEnumerationBlock)block
{
    // 判断是否需要进行回调
    if (!block)
        return;
    
    // 锁定
    [self lock];
        NSDate *now = [NSDate date];
    // 根据创建时间进行排序
        NSArray *keysSortedByCreatedDate = [_createdDates keysSortedByValueUsingSelector:@selector(compare:)];
        
        for (NSString *key in keysSortedByCreatedDate) {
            // If the cache should behave like a TTL cache, then only fetch the object if there's a valid ageLimit and  the object is still alive
            // 没有设定时间的默认使用默认时间
            NSTimeInterval ageLimit = [_ageLimits[key] doubleValue] ?: self->_ageLimit;
            
            // 保证使用的对象是有效的
            if (!self->_ttlCache || ageLimit <= 0 || fabs([[_createdDates objectForKey:key] timeIntervalSinceDate:now]) < ageLimit) {
                BOOL stop = NO;
                block(self, key, _dictionary[key], &stop);
                if (stop)
                    break;
            }
        }
    [self unlock];
}

#pragma mark - Public Thread Safe Accessors -
// 在每次设置前和读取前进行设置，保证线程安全
- (PINCacheObjectBlock)willAddObjectBlock
{
    [self lock];
        PINCacheObjectBlock block = _willAddObjectBlock;
    [self unlock];

    return block;
}

- (void)setWillAddObjectBlock:(PINCacheObjectBlock)block
{
    [self lock];
        _willAddObjectBlock = [block copy];
    [self unlock];
}

- (PINCacheObjectBlock)willRemoveObjectBlock
{
    [self lock];
        PINCacheObjectBlock block = _willRemoveObjectBlock;
    [self unlock];

    return block;
}

- (void)setWillRemoveObjectBlock:(PINCacheObjectBlock)block
{
    [self lock];
        _willRemoveObjectBlock = [block copy];
    [self unlock];
}

- (PINCacheBlock)willRemoveAllObjectsBlock
{
    [self lock];
        PINCacheBlock block = _willRemoveAllObjectsBlock;
    [self unlock];

    return block;
}

- (void)setWillRemoveAllObjectsBlock:(PINCacheBlock)block
{
    [self lock];
        _willRemoveAllObjectsBlock = [block copy];
    [self unlock];
}

- (PINCacheObjectBlock)didAddObjectBlock
{
    [self lock];
        PINCacheObjectBlock block = _didAddObjectBlock;
    [self unlock];

    return block;
}

- (void)setDidAddObjectBlock:(PINCacheObjectBlock)block
{
    [self lock];
        _didAddObjectBlock = [block copy];
    [self unlock];
}

- (PINCacheObjectBlock)didRemoveObjectBlock
{
    [self lock];
        PINCacheObjectBlock block = _didRemoveObjectBlock;
    [self unlock];

    return block;
}

- (void)setDidRemoveObjectBlock:(PINCacheObjectBlock)block
{
    [self lock];
        _didRemoveObjectBlock = [block copy];
    [self unlock];
}

- (PINCacheBlock)didRemoveAllObjectsBlock
{
    [self lock];
        PINCacheBlock block = _didRemoveAllObjectsBlock;
    [self unlock];

    return block;
}

- (void)setDidRemoveAllObjectsBlock:(PINCacheBlock)block
{
    [self lock];
        _didRemoveAllObjectsBlock = [block copy];
    [self unlock];
}

- (PINCacheBlock)didReceiveMemoryWarningBlock
{
    [self lock];
        PINCacheBlock block = _didReceiveMemoryWarningBlock;
    [self unlock];

    return block;
}

- (void)setDidReceiveMemoryWarningBlock:(PINCacheBlock)block
{
    [self lock];
        _didReceiveMemoryWarningBlock = [block copy];
    [self unlock];
}

- (PINCacheBlock)didEnterBackgroundBlock
{
    [self lock];
        PINCacheBlock block = _didEnterBackgroundBlock;
    [self unlock];

    return block;
}

- (void)setDidEnterBackgroundBlock:(PINCacheBlock)block
{
    [self lock];
        _didEnterBackgroundBlock = [block copy];
    [self unlock];
}

- (NSTimeInterval)ageLimit
{
    [self lock];
        NSTimeInterval ageLimit = _ageLimit;
    [self unlock];
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit
{
    [self lock];
        _ageLimit = ageLimit;
    [self unlock];
    
    [self trimToAgeLimitRecursively];
}

- (NSUInteger)costLimit
{
    [self lock];
        NSUInteger costLimit = _costLimit;
    [self unlock];

    return costLimit;
}

- (void)setCostLimit:(NSUInteger)costLimit
{
    [self lock];
        _costLimit = costLimit;
    [self unlock];

    if (costLimit > 0)
        [self trimToCostLimitByDate:costLimit];
}

- (NSUInteger)totalCost
{
    [self lock];
        NSUInteger cost = _totalCost;
    [self unlock];
    
    return cost;
}

- (BOOL)isTTLCache {
    BOOL isTTLCache;
    
    [self lock];
        isTTLCache = _ttlCache;
    [self unlock];
    
    return isTTLCache;
}

- (void)lock
{
    __unused int result = pthread_mutex_lock(&_mutex);
    NSAssert(result == 0, @"Failed to lock PINMemoryCache %@. Code: %d", self, result);
}

- (void)unlock
{
    __unused int result = pthread_mutex_unlock(&_mutex);
    NSAssert(result == 0, @"Failed to unlock PINMemoryCache %@. Code: %d", self, result);
}

@end


#pragma mark - Deprecated

@implementation PINMemoryCache (Deprecated)

- (void)containsObjectForKey:(NSString *)key block:(PINMemoryCacheContainmentBlock)block
{
    [self containsObjectForKeyAsync:key completion:block];
}

- (void)objectForKey:(NSString *)key block:(nullable PINMemoryCacheObjectBlock)block
{
    [self objectForKeyAsync:key completion:block];
}

- (void)setObject:(id)object forKey:(NSString *)key block:(nullable PINMemoryCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key completion:block];
}

- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost block:(nullable PINMemoryCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key withCost:cost completion:block];
}

- (void)removeObjectForKey:(NSString *)key block:(nullable PINMemoryCacheObjectBlock)block
{
    [self removeObjectForKeyAsync:key completion:block];
}

- (void)trimToDate:(NSDate *)date block:(nullable PINMemoryCacheBlock)block
{
    [self trimToDateAsync:date completion:block];
}

- (void)trimToCost:(NSUInteger)cost block:(nullable PINMemoryCacheBlock)block
{
    [self trimToCostAsync:cost completion:block];
}

- (void)trimToCostByDate:(NSUInteger)cost block:(nullable PINMemoryCacheBlock)block
{
    [self trimToCostByDateAsync:cost completion:block];
}

- (void)removeAllObjects:(nullable PINMemoryCacheBlock)block
{
    [self removeAllObjectsAsync:block];
}

- (void)enumerateObjectsWithBlock:(PINMemoryCacheObjectBlock)block completionBlock:(nullable PINMemoryCacheBlock)completionBlock
{
    [self enumerateObjectsWithBlockAsync:^(id<PINCaching> _Nonnull cache, NSString * _Nonnull key, id _Nullable object, BOOL * _Nonnull stop) {
        if ([cache isKindOfClass:[PINMemoryCache class]]) {
            PINMemoryCache *memoryCache = (PINMemoryCache *)cache;
            block(memoryCache, key, object);
        }
    } completionBlock:completionBlock];
}

- (void)setTtlCache:(BOOL)ttlCache
{
    [self lock];
        _ttlCache = ttlCache;
    [self unlock];
}

@end
