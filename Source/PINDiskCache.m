//  PINCache is a modified version of TMCache
//  Modifications by Garrett Moon
//  Copyright (c) 2015 Pinterest. All rights reserved.

#import "PINDiskCache.h"

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
#import <UIKit/UIKit.h>
#endif

#import <pthread.h>
#import <sys/xattr.h>

#import <PINOperation/PINOperation.h>

#define PINDiskCacheError(error) if (error) { NSLog(@"%@ (%d) ERROR: %@", \
[[NSString stringWithUTF8String:__FILE__] lastPathComponent], \
__LINE__, [error localizedDescription]); }

#define PINDiskCacheException(exception) if (exception) { NSAssert(NO, [exception reason]); }

const char * PINDiskCacheAgeLimitAttributeName = "com.pinterest.PINDiskCache.ageLimit";
NSString * const PINDiskCacheErrorDomain = @"com.pinterest.PINDiskCache";
NSErrorUserInfoKey const PINDiskCacheErrorReadFailureCodeKey = @"PINDiskCacheErrorReadFailureCodeKey";
NSErrorUserInfoKey const PINDiskCacheErrorWriteFailureCodeKey = @"PINDiskCacheErrorWriteFailureCodeKey";
NSString * const PINDiskCachePrefix = @"com.pinterest.PINDiskCache";
static NSString * const PINDiskCacheSharedName = @"PINDiskCacheShared";

static NSString * const PINDiskCacheOperationIdentifierTrimToDate = @"PINDiskCacheOperationIdentifierTrimToDate";
static NSString * const PINDiskCacheOperationIdentifierTrimToSize = @"PINDiskCacheOperationIdentifierTrimToSize";
static NSString * const PINDiskCacheOperationIdentifierTrimToSizeByDate = @"PINDiskCacheOperationIdentifierTrimToSizeByDate";

typedef NS_ENUM(NSUInteger, PINDiskCacheCondition) {
    PINDiskCacheConditionNotReady = 0,
    PINDiskCacheConditionReady = 1,
};

static PINOperationDataCoalescingBlock PINDiskTrimmingSizeCoalescingBlock = ^id(NSNumber *existingSize, NSNumber *newSize) {
    NSComparisonResult result = [existingSize compare:newSize];
    return (result == NSOrderedDescending) ? newSize : existingSize;
};

static PINOperationDataCoalescingBlock PINDiskTrimmingDateCoalescingBlock = ^id(NSDate *existingDate, NSDate *newDate) {
    NSComparisonResult result = [existingDate compare:newDate];
    return (result == NSOrderedDescending) ? newDate : existingDate;
};

const char * PINDiskCacheFileSystemRepresentation(NSURL *url)
{
#ifdef __MAC_10_13 // Xcode >= 9
    // -fileSystemRepresentation is available on macOS >= 10.9
    if (@available(macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, *)) {
      return url.fileSystemRepresentation;
    }
#endif
    return [url.path cStringUsingEncoding:NSUTF8StringEncoding];
}


/**
 元数据对象，用于保存文件创建时间，最后一次访问时间，时间限制，还有大小
 */
@interface PINDiskCacheMetadata : NSObject
// When the object was added to the disk cache
@property (nonatomic, strong) NSDate *createdDate;
// Last time the object was accessed
@property (nonatomic, strong) NSDate *lastModifiedDate;
@property (nonatomic, strong) NSNumber *size;
// Age limit is used in conjuction with ttl
@property (nonatomic) NSTimeInterval ageLimit;
@end

@interface PINDiskCache () {
    PINDiskCacheSerializerBlock _serializer;
    PINDiskCacheDeserializerBlock _deserializer;
    
    PINDiskCacheKeyEncoderBlock _keyEncoder;
    PINDiskCacheKeyDecoderBlock _keyDecoder;
}

@property (assign, nonatomic) pthread_mutex_t mutex;
@property (copy, nonatomic) NSString *name;
@property (assign) NSUInteger byteCount;
@property (strong, nonatomic) NSURL *cacheURL;
@property (strong, nonatomic) PINOperationQueue *operationQueue;
@property (strong, nonatomic) NSMutableDictionary <NSString *, PINDiskCacheMetadata *> *metadata;
@property (assign, nonatomic) pthread_cond_t diskWritableCondition;
@property (assign, nonatomic) BOOL diskWritable;
@property (assign, nonatomic) pthread_cond_t diskStateKnownCondition;
@property (assign, nonatomic) BOOL diskStateKnown;
@property (assign, nonatomic) BOOL writingProtectionOptionSet;
@end

@implementation PINDiskCache

static NSURL *_sharedTrashURL;

@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize byteLimit = _byteLimit;
@synthesize ageLimit = _ageLimit;
@synthesize ttlCache = _ttlCache;

#if TARGET_OS_IPHONE
@synthesize writingProtectionOption = _writingProtectionOption;
@synthesize writingProtectionOptionSet = _writingProtectionOptionSet;
#endif

#pragma mark - Initialization -

- (void)dealloc
{
    __unused int result = pthread_mutex_destroy(&_mutex);
    NSCAssert(result == 0, @"Failed to destroy lock in PINMemoryCache %p. Code: %d", (void *)self, result);
    pthread_cond_destroy(&_diskWritableCondition);
    pthread_cond_destroy(&_diskStateKnownCondition);
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:@"Must initialize with a name" reason:@"PINDiskCache must be initialized with a name. Call initWithName: instead." userInfo:nil];
    return [self initWithName:@""];
}

- (instancetype)initWithName:(NSString *)name
{
    return [self initWithName:name rootPath:[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath
{
    return [self initWithName:name rootPath:rootPath serializer:nil deserializer:nil];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath serializer:(PINDiskCacheSerializerBlock)serializer deserializer:(PINDiskCacheDeserializerBlock)deserializer
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [self initWithName:name rootPath:rootPath serializer:serializer deserializer:deserializer operationQueue:[PINOperationQueue sharedOperationQueue]];
#pragma clang diagnostic pop
}

- (instancetype)initWithName:(NSString *)name
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
              operationQueue:(PINOperationQueue *)operationQueue
{
  return [self initWithName:name
                     prefix:PINDiskCachePrefix
                   rootPath:rootPath
                 serializer:serializer
               deserializer:deserializer
                 keyEncoder:nil
                 keyDecoder:nil
             operationQueue:operationQueue];
}

- (instancetype)initWithName:(NSString *)name
                      prefix:(NSString *)prefix
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
                  keyEncoder:(PINDiskCacheKeyEncoderBlock)keyEncoder
                  keyDecoder:(PINDiskCacheKeyDecoderBlock)keyDecoder
              operationQueue:(PINOperationQueue *)operationQueue
{
    return [self initWithName:name prefix:prefix
                     rootPath:rootPath
                   serializer:serializer
                 deserializer:deserializer
                   keyEncoder:keyEncoder
                   keyDecoder:keyDecoder
               operationQueue:operationQueue
                     ttlCache:NO];
}

- (instancetype)initWithName:(NSString *)name
                      prefix:(NSString *)prefix
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
                  keyEncoder:(PINDiskCacheKeyEncoderBlock)keyEncoder
                  keyDecoder:(PINDiskCacheKeyDecoderBlock)keyDecoder
              operationQueue:(PINOperationQueue *)operationQueue
                    ttlCache:(BOOL)ttlCache
{
    if (!name)
        return nil;
    

    NSAssert(((!serializer && !deserializer) || (serializer && deserializer)),
             @"PINDiskCache must be initialized with a serializer AND deserializer.");
    
    NSAssert(((!keyEncoder && !keyDecoder) || (keyEncoder && keyDecoder)),
              @"PINDiskCache must be initialized with a encoder AND decoder.");
    
    if (self = [super init]) {
        __unused int result = pthread_mutex_init(&_mutex, NULL);
        NSAssert(result == 0, @"Failed to init lock in PINMemoryCache %@. Code: %d", self, result);
        
        // 当前这个对象的名字，用于多对象区分
        _name = [name copy];
        // 前缀，默认使用库自行提供的
        _prefix = [prefix copy];
        // 创建现成
        _operationQueue = operationQueue;
        // 是否需要有 Time To Live
        _ttlCache = ttlCache;
        // 新增前置
        _willAddObjectBlock = nil;
        // 删除前置
        _willRemoveObjectBlock = nil;
        // 删除全部前置
        _willRemoveAllObjectsBlock = nil;
        // 新增后置
        _didAddObjectBlock = nil;
        // 删除后置
        _didRemoveObjectBlock = nil;
        // 删除全部后置
        _didRemoveAllObjectsBlock = nil;
        
        // 总个数
        _byteCount = 0;
        
        // 50 MB by default
        // 空间大小限制
        _byteLimit = 50 * 1024 * 1024;
        // 30 days by default
        // 时间限制
        _ageLimit = 60 * 60 * 24 * 30;
        
#if TARGET_OS_IPHONE
        // 是否有写入限制的设置
        _writingProtectionOptionSet = NO;
        // This is currently the default for files, but we'd rather not write it if it's unspecified.
        // 数据写入文件保护完成直到第一次用户验证
        _writingProtectionOption = NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
#endif
        // 元数据
        _metadata = [[NSMutableDictionary alloc] init];
        // 硬盘转台是否已知
        _diskStateKnown = NO;
      
        // 缓存地址
        _cacheURL = [[self class] cacheURLWithRootPath:rootPath prefix:_prefix name:_name];
        
        //setup serializers
        // 序列化
        if(serializer) {
            _serializer = [serializer copy];
        } else {
            _serializer = self.defaultSerializer;
        }

        // 反序列化
        if(deserializer) {
            _deserializer = [deserializer copy];
        } else {
            _deserializer = self.defaultDeserializer;
        }
        
        //setup key encoder/decoder
        // 键加密
        if(keyEncoder) {
            _keyEncoder = [keyEncoder copy];
        } else {
            _keyEncoder = self.defaultKeyEncoder;
        }
        
        // 键解密
        if(keyDecoder) {
            _keyDecoder = [keyDecoder copy];
        } else {
            _keyDecoder = self.defaultKeyDecoder;
        }
        
        // 线程锁初始化
        pthread_cond_init(&_diskWritableCondition, NULL);
        pthread_cond_init(&_diskStateKnownCondition, NULL);

        //we don't want to do anything without setting up the disk cache, but we also don't want to block init, it can take a while to initialize. This must *not* be done on _operationQueue because other operations added may hold the lock and fill up the queue.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self lock];
            // 异步初始化对应的存储空间
                [self _locked_createCacheDirectory];
            [self unlock];
            [self initializeDiskProperties];
        });
    }
    return self;
}

// 描述
- (NSString *)description
{
    return [[NSString alloc] initWithFormat:@"%@.%@.%p", PINDiskCachePrefix, _name, (__bridge void *)self];
}

// 单例
+ (PINDiskCache *)sharedCache
{
    static PINDiskCache *cache;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        cache = [[PINDiskCache alloc] initWithName:PINDiskCacheSharedName];
    });
    
    return cache;
}

// 生成换成路径
+ (NSURL *)cacheURLWithRootPath:(NSString *)rootPath prefix:(NSString *)prefix name:(NSString *)name
{
    NSString *pathComponent = [[NSString alloc] initWithFormat:@"%@.%@", prefix, name];
    return [NSURL fileURLWithPathComponents:@[ rootPath, pathComponent ]];
}

#pragma mark - Private Methods -
// 编码文件名
- (NSURL *)encodedFileURLForKey:(NSString *)key
{
    if (![key length])
        return nil;
    
    //Significantly improve performance by indicating that the URL will *not* result in a directory.
    //Also note that accessing _cacheURL is safe without the lock because it is only set on init.
    return [_cacheURL URLByAppendingPathComponent:[self encodedString:key] isDirectory:NO];
}

// 解码文件名
- (NSString *)keyForEncodedFileURL:(NSURL *)url
{
    NSString *fileName = [url lastPathComponent];
    if (!fileName)
        return nil;
    
    return [self decodedString:fileName];
}

// 编码字符串
- (NSString *)encodedString:(NSString *)string
{
    return _keyEncoder(string);
}

// 解档字符串
- (NSString *)decodedString:(NSString *)string
{
    return _keyDecoder(string);
}

// 默认序列化
- (PINDiskCacheSerializerBlock)defaultSerializer
{
    return ^NSData*(id<NSCoding> object, NSString *key){
        return [NSKeyedArchiver archivedDataWithRootObject:object];
    };
}

// 默认反序列化
- (PINDiskCacheDeserializerBlock)defaultDeserializer
{
    return ^id(NSData * data, NSString *key){
        return [NSKeyedUnarchiver unarchiveObjectWithData:data];
    };
}

// 默认编码工具
- (PINDiskCacheKeyEncoderBlock)defaultKeyEncoder
{
    return ^NSString *(NSString *decodedKey) {
        if (![decodedKey length]) {
            return @"";
        }
        
        if (@available(macOS 10.9, iOS 7.0, tvOS 9.0, watchOS 2.0, *)) {
            // 根据 .:% 分割字符串，并将剩下的内容拼接出来
            NSString *encodedString = [decodedKey stringByAddingPercentEncodingWithAllowedCharacters:[[NSCharacterSet characterSetWithCharactersInString:@".:/%"] invertedSet]];
            return encodedString;
        } else {
            CFStringRef static const charsToEscape = CFSTR(".:/%");
            // 去除 warning
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CFStringRef escapedString = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                                (__bridge CFStringRef)decodedKey,
                                                                                NULL,
                                                                                charsToEscape,
                                                                                kCFStringEncodingUTF8);
#pragma clang diagnostic pop
            
            return (__bridge_transfer NSString *)escapedString;
        }
    };
}

// 默认解码器
- (PINDiskCacheKeyEncoderBlock)defaultKeyDecoder
{
    return ^NSString *(NSString *encodedKey) {
        if (![encodedKey length]) {
            return @"";
        }
        
        if (@available(macOS 10.9, iOS 7.0, tvOS 9.0, watchOS 2.0, *)) {
            return [encodedKey stringByRemovingPercentEncoding];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CFStringRef unescapedString = CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault,
                                                                                                  (__bridge CFStringRef)encodedKey,
                                                                                                  CFSTR(""),
                                                                                                  kCFStringEncodingUTF8);
#pragma clang diagnostic pop
            return (__bridge_transfer NSString *)unescapedString;
        }
    };
}


#pragma mark - Private Trash Methods -

// 公共垃圾线程
+ (dispatch_queue_t)sharedTrashQueue
{
    static dispatch_queue_t trashQueue;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        NSString *queueName = [[NSString alloc] initWithFormat:@"%@.trash", PINDiskCachePrefix];
        trashQueue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(trashQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    });
    
    return trashQueue;
}

// 公共锁。 为什么用 NSLock 而不和 memoryDisk 一致？
+ (NSLock *)sharedLock
{
    static NSLock *sharedLock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLock = [NSLock new];
    });
    return sharedLock;
}

// 公共垃圾 URL，随机生成不相同的文件路径
+ (NSURL *)sharedTrashURL
{
    NSURL *trashURL = nil;
    
    [[PINDiskCache sharedLock] lock];
        if (_sharedTrashURL == nil) {
            NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
            _sharedTrashURL = [[[NSURL alloc] initFileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:uniqueString isDirectory:YES];
            
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtURL:_sharedTrashURL
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&error];
            PINDiskCacheError(error);
        }
        trashURL = _sharedTrashURL;
    [[PINDiskCache sharedLock] unlock];
    
    return trashURL;
}

// 将文件移动到垃圾文件夹中
+ (BOOL)moveItemAtURLToTrash:(NSURL *)itemURL
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:[itemURL path]])
        return NO;
    
    NSError *error = nil;
    // 生成一个随机字符串
    NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
    NSURL *uniqueTrashURL = [[PINDiskCache sharedTrashURL] URLByAppendingPathComponent:uniqueString isDirectory:NO];
    BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:itemURL toURL:uniqueTrashURL error:&error];
    PINDiskCacheError(error);
    return moved;
}

// 清空垃圾文件夹
+ (void)emptyTrash
{
    // 用垃圾现成来清理垃圾文件夹
    dispatch_async([PINDiskCache sharedTrashQueue], ^{
        NSURL *trashURL = nil;
      
        // If _sharedTrashURL is unset, there's nothing left to do because it hasn't been accessed and therefore items haven't been added to it.
        // If it is set, we can just remove it.
        // We also need to nil out _sharedTrashURL so that a new one will be created if there's an attempt to move a new file to the trash.
        [[PINDiskCache sharedLock] lock];
            if (_sharedTrashURL != nil) {
                trashURL = _sharedTrashURL;
                _sharedTrashURL = nil;
            }
        [[PINDiskCache sharedLock] unlock];
        
        if (trashURL != nil) {
            NSError *removeTrashedItemError = nil;
            [[NSFileManager defaultManager] removeItemAtURL:trashURL error:&removeTrashedItemError];
            PINDiskCacheError(removeTrashedItemError);
        }
    });
}

#pragma mark - Private Queue Methods -

- (BOOL)_locked_createCacheDirectory
{
    BOOL created = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[_cacheURL path]] == NO) {
        NSError *error = nil;
        created = [[NSFileManager defaultManager] createDirectoryAtURL:_cacheURL
                                                withIntermediateDirectories:YES
                                                                 attributes:nil
                                                                      error:&error];
        PINDiskCacheError(error);
    }
    

    
    // while this may not be true if success is false, it's better than deadlocking later.
    _diskWritable = YES;
    // 路径初始化完全，线程可用
    pthread_cond_broadcast(&_diskWritableCondition);
    
    return created;
}

// 获得创建时间，修改时间和文件空间
+ (NSArray *)resourceKeys
{
    static NSArray *resourceKeys = nil;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        resourceKeys = @[ NSURLCreationDateKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ];
    });

    return resourceKeys;
}

/**
 * @return File size in bytes.
 * 获得文件总大小
 */
- (NSUInteger)_locked_initializeDiskPropertiesForFile:(NSURL *)fileURL fileKey:(NSString *)fileKey
{
    NSError *error = nil;

    NSDictionary *dictionary = [fileURL resourceValuesForKeys:[PINDiskCache resourceKeys] error:&error];
    PINDiskCacheError(error);

    // 如果内容不存在，那么就创建一个空的元数据对象
    if (_metadata[fileKey] == nil) {
        _metadata[fileKey] = [[PINDiskCacheMetadata alloc] init];
    }

    // 解析并存储创建时间
    NSDate *createdDate = dictionary[NSURLCreationDateKey];
    if (createdDate && fileKey)
        _metadata[fileKey].createdDate = createdDate;

    // 解析并存储最后一次修改时间
    NSDate *lastModifiedDate = dictionary[NSURLContentModificationDateKey];
    if (lastModifiedDate && fileKey)
        _metadata[fileKey].lastModifiedDate = lastModifiedDate;

    // 解析并存储文件大小
    NSNumber *fileSize = dictionary[NSURLTotalFileAllocatedSizeKey];
    if (fileSize) {
        _metadata[fileKey].size = fileSize;
    }

    // 如果需要被定时删除的对象
    if (_ttlCache) {
        NSTimeInterval ageLimit;
        // 检索当前路径的扩展属性值，获得定时器的值
        ssize_t res = getxattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAgeLimitAttributeName, &ageLimit, sizeof(NSTimeInterval), 0, 0);
        if(res > 0) {
            // 设置定时器值
            _metadata[fileKey].ageLimit = ageLimit;
        } else if (res == -1) {
            // Ignore if the extended attribute was never recorded for this file.
            // 没有被记录这个值，需要报错
            if (errno != ENOATTR) {
                NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorReadFailureCodeKey : @(errno)};
                error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorReadFailure userInfo:userInfo];
                PINDiskCacheError(error);
            }
        }
    }

    // 返回内容大小
    return [fileSize unsignedIntegerValue];
}

// 初始化文件相关的内容
- (void)initializeDiskProperties
{
    NSUInteger byteCount = 0;

    NSError *error = nil;
    
    [self lock];
    // 获得当前文件夹一层目录下的文件夹相关的信息
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:_cacheURL
                                                       includingPropertiesForKeys:[PINDiskCache resourceKeys]
                                                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                            error:&error];
    [self unlock];
    
    // 硬盘是否正常读取信息
    PINDiskCacheError(error);
    
    for (NSURL *fileURL in files) {
        NSString *fileKey = [self keyForEncodedFileURL:fileURL];
        // Continually grab and release lock while processing files to avoid contention
        [self lock];
        // 如果内容没有被夹在，那么就解析文件和文件名
        if (_metadata[fileKey] == nil) {
            // 统计总占空间量
            byteCount += [self _locked_initializeDiskPropertiesForFile:fileURL fileKey:fileKey];
        }
        [self unlock];
    }
    
    [self lock];
    // 总容量进行赋值
        if (byteCount > 0)
            _byteCount = byteCount;
    // 空间限制超过，根据大小移除对应的文件（异步）
        if (self->_byteLimit > 0 && self->_byteCount > self->_byteLimit)
            [self trimToSizeByDateAsync:self->_byteLimit completion:nil];
    // 根据是否设置 ttl 移除对应的对象（异步）
        if (self->_ttlCache)
            [self removeExpiredObjectsAsync:nil];
    
        _diskStateKnown = YES;
    // 硬盘内容读取完成，现成可用
        pthread_cond_broadcast(&_diskStateKnownCondition);
    [self unlock];
}

// 异步设置文件上一次更新时间
- (void)asynchronouslySetFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL
{
    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            [self _locked_setFileModificationDate:date forURL:fileURL];
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

// 同步设置上一次修改时间
- (BOOL)_locked_setFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL
{
    if (!date || !fileURL) {
        return NO;
    }
    
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: date }
                                                    ofItemAtPath:[fileURL path]
                                                           error:&error];
    PINDiskCacheError(error);
    
    return success;
}

// 异步设置文件最大时间
- (void)asynchronouslySetAgeLimit:(NSTimeInterval)ageLimit forURL:(NSURL *)fileURL
{
    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            [self _locked_setAgeLimit:ageLimit forURL:fileURL];
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

// 同步设置最大生命周期限制
- (BOOL)_locked_setAgeLimit:(NSTimeInterval)ageLimit forURL:(NSURL *)fileURL
{
    if (!fileURL) {
        return NO;
    }

    NSError *error = nil;
    if (ageLimit <= 0.0) {
        // 如果时间无效那么直接移除
        if (removexattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAgeLimitAttributeName, 0) != 0) {
          // Ignore if the extended attribute was never recorded for this file.
          if (errno != ENOATTR) {
            NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorWriteFailureCodeKey : @(errno)};
            error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorWriteFailure userInfo:userInfo];
            PINDiskCacheError(error);
          }
        }
    } else {
        // 否则进行设置最长生命时间
        if (setxattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAgeLimitAttributeName, &ageLimit, sizeof(NSTimeInterval), 0, 0) != 0) {
            NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorWriteFailureCodeKey : @(errno)};
            error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorWriteFailure userInfo:userInfo];
            PINDiskCacheError(error);
        }
    }

    if (!error) {
        NSString *key = [self keyForEncodedFileURL:fileURL];
        if (key) {
            _metadata[key].ageLimit = ageLimit;
        }
    }

    return !error;
}

// 根据文件名来删除文件并执行对应的 block
- (BOOL)removeFileAndExecuteBlocksForKey:(NSString *)key
{
    // 根据名字获得 key
    NSURL *fileURL = [self encodedFileURLForKey:key];
    
    // 加锁，等到可写。
    // We only need to lock until writable at the top because once writable, always writable
    [self lockForWriting];
    // 文件路径无效，则直接返回删除失败。
        if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            [self unlock];
            return NO;
        }
    
    // 执行将要移除的 block
        PINCacheObjectBlock willRemoveObjectBlock = _willRemoveObjectBlock;
        if (willRemoveObjectBlock) {
            [self unlock];
            willRemoveObjectBlock(self, key, nil);
            [self lock];
        }
    
    // 把当前文件移动到辣鸡文件夹中
        BOOL trashed = [PINDiskCache moveItemAtURLToTrash:fileURL];
        if (!trashed) {
            // 移动失败，返回删除失败
            [self unlock];
            return NO;
        }
    
    // 清空回收站
        [PINDiskCache emptyTrash];
    
    // 总空间从内存的文件对象中删除
        NSNumber *byteSize = _metadata[key].size;
        if (byteSize)
            self.byteCount = _byteCount - [byteSize unsignedIntegerValue]; // atomic
    
    // 对象删除
        [_metadata removeObjectForKey:key];
    
    // 删除完成，调用 block
        PINCacheObjectBlock didRemoveObjectBlock = _didRemoveObjectBlock;
        if (didRemoveObjectBlock) {
            [self unlock];
            _didRemoveObjectBlock(self, key, nil);
            [self lock];
        }
    
    [self unlock];
    
    return YES;
}

// 根据文件体积从上到下排列删除文件，直到达到想要的值
- (void)trimDiskToSize:(NSUInteger)trimByteCount
{
    NSMutableArray *keysToRemove = nil;
    
    [self lockForWriting];
        if (_byteCount > trimByteCount) {
            keysToRemove = [[NSMutableArray alloc] init];
            
            NSArray *keysSortedBySize = [_metadata keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
                return [obj1.size compare:obj2.size];
            }];
            
            NSUInteger bytesSaved = 0;
            // 从大到小进行删除，添加到数组当中
            for (NSString *key in [keysSortedBySize reverseObjectEnumerator]) { // largest objects first
                [keysToRemove addObject:key];
                NSNumber *byteSize = _metadata[key].size;
                if (byteSize) {
                    bytesSaved += [byteSize unsignedIntegerValue];
                }
                if (_byteCount - bytesSaved <= trimByteCount) {
                    break;
                }
            }
        }
    [self unlock];
    
    // 顺序移除已经删除的文件
    for (NSString *key in keysToRemove) {
        [self removeFileAndExecuteBlocksForKey:key];
    }
}

// This is the default trimming method which happens automatically
// 自动，根据日期自动删除内容，直到空间到想要的标准
- (void)trimDiskToSizeByDate:(NSUInteger)trimByteCount
{
    // 先尝试删除所有有生命时长的
    if (self.isTTLCache) {
        [self removeExpiredObjects];
    }

    NSMutableArray *keysToRemove = nil;
  
    [self lockForWriting];
        if (_byteCount > trimByteCount) {
            keysToRemove = [[NSMutableArray alloc] init];
            
            // 根据上一次修改时间进行删除
            // last modified represents last access.
            NSArray *keysSortedByLastModifiedDate = [_metadata keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
                return [obj1.lastModifiedDate compare:obj2.lastModifiedDate];
            }];
            
            NSUInteger bytesSaved = 0;
            // objects accessed last first.
            for (NSString *key in keysSortedByLastModifiedDate) {
                [keysToRemove addObject:key];
                NSNumber *byteSize = _metadata[key].size;
                if (byteSize) {
                    bytesSaved += [byteSize unsignedIntegerValue];
                }
                if (_byteCount - bytesSaved <= trimByteCount) {
                    break;
                }
            }
        }
    [self unlock];
    
    for (NSString *key in keysToRemove) {
        [self removeFileAndExecuteBlocksForKey:key];
    }
}

// 删除文件直到某个时间点，即删除更早的文件
- (void)trimDiskToDate:(NSDate *)trimDate
{
    [self lockForWriting];
        NSArray *keysSortedByCreatedDate = [_metadata keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
            return [obj1.createdDate compare:obj2.createdDate];
        }];
    
        NSMutableArray *keysToRemove = [[NSMutableArray alloc] init];
        
        for (NSString *key in keysSortedByCreatedDate) { // oldest files first
            NSDate *createdDate = _metadata[key].createdDate;
            if (!createdDate || _metadata[key].ageLimit > 0.0)
                continue;
            
            if ([createdDate compare:trimDate] == NSOrderedAscending) { // older than trim date
                [keysToRemove addObject:key];
            } else {
                break;
            }
        }
    [self unlock];
    
    for (NSString *key in keysToRemove) {
        [self removeFileAndExecuteBlocksForKey:key];
    }
}

// 递归删除生命周期到的文件，定时器
- (void)trimToAgeLimitRecursively
{
    [self lock];
        NSTimeInterval ageLimit = _ageLimit;
    [self unlock];
    if (ageLimit == 0.0)
        return;
    
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-ageLimit];
    [self trimToDateAsync:date completion:nil];
    
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ageLimit * NSEC_PER_SEC));
    dispatch_after(time, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        // Ensure that ageLimit is the same as when we were scheduled, otherwise, we've been
        // rescheduled (another dispatch_after was issued) and should cancel.
        BOOL shouldReschedule = YES;
        [self lock];
            if (ageLimit != self->_ageLimit) {
                shouldReschedule = NO;
            }
        [self unlock];
        
        if (shouldReschedule) {
            [self.operationQueue scheduleOperation:^{
                [self trimToAgeLimitRecursively];
            } withPriority:PINOperationQueuePriorityLow];
        }
    });
}

#pragma mark - Public Asynchronous Methods -

// 锁住文件，直到文件可写，这时候说明文件可被操作
- (void)lockFileAccessWhileExecutingBlockAsync:(PINCacheBlock)block
{
    if (block == nil) {
      return;
    }

    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            block(self);
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

// 异步获得是否有某个文件
- (void)containsObjectForKeyAsync:(NSString *)key completion:(PINDiskCacheContainsBlock)block
{
    if (!key || !block)
        return;
    
    [self.operationQueue scheduleOperation:^{
        block([self containsObjectForKey:key]);
    } withPriority:PINOperationQueuePriorityLow];
}

// 异步获得某个文件，只是获取文件，不能保证肯定可以使用
- (void)objectForKeyAsync:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        id <NSCoding> object = [self objectForKey:key fileURL:&fileURL];
        
        block(self, key, object);
    } withPriority:PINOperationQueuePriorityLow];
}

// 异步获得文件路径，保证可写
- (void)fileURLForKeyAsync:(NSString *)key completion:(PINDiskCacheFileURLBlock)block
{
    if (block == nil) {
      return;
    }

    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = [self fileURLForKey:key];
      
        [self lockForWriting];
            block(key, fileURL);
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

// 异步设置对象，递进
- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key withAgeLimit:0.0 completion:(PINDiskCacheObjectBlock)block];
}

// 异步设置对象
- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key withAgeLimit:(NSTimeInterval)ageLimit completion:(nullable PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        [self setObject:object forKey:key withAgeLimit:ageLimit fileURL:&fileURL];
        
        if (block) {
            block(self, key, object);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

// 异步设置对象，递进
- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost completion:(nullable PINCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key completion:(PINDiskCacheObjectBlock)block];
}

// 异步设置对象，递进
- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost ageLimit:(NSTimeInterval)ageLimit completion:(nullable PINCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key withAgeLimit:ageLimit completion:(PINDiskCacheObjectBlock)block];
}

// 异步删除对象
- (void)removeObjectForKeyAsync:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        [self removeObjectForKey:key fileURL:&fileURL];
        
        if (block) {
            block(self, key, nil);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

// 异步删除文件，根据尺寸
- (void)trimToSizeAsync:(NSUInteger)trimByteCount completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data) {
        [self trimToSize:((NSNumber *)data).unsignedIntegerValue];
    };
  
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToSize
                            coalescingData:[NSNumber numberWithUnsignedInteger:trimByteCount]
                       dataCoalescingBlock:PINDiskTrimmingSizeCoalescingBlock
                                completion:completion];
}

// 异步根据文件修改时间进行删除到指定时间
- (void)trimToDateAsync:(NSDate *)trimDate completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data){
        [self trimToDate:(NSDate *)data];
    };
    
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToDate
                            coalescingData:trimDate
                       dataCoalescingBlock:PINDiskTrimmingDateCoalescingBlock
                                completion:completion];
}

// 异步根据文件修改时间进行删除到指定大小
- (void)trimToSizeByDateAsync:(NSUInteger)trimByteCount completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data){
        [self trimToSizeByDate:((NSNumber *)data).unsignedIntegerValue];
    };
    
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToSizeByDate
                            coalescingData:[NSNumber numberWithUnsignedInteger:trimByteCount]
                       dataCoalescingBlock:PINDiskTrimmingSizeCoalescingBlock
                                completion:completion];
}

// 异步删除过期文件
- (void)removeExpiredObjectsAsync:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self removeExpiredObjects];

        if (block) {
            block(self);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

// 异步删除所有文件
- (void)removeAllObjectsAsync:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self removeAllObjects];
        
        if (block) {
            block(self);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

// 异步遍历有效文件
- (void)enumerateObjectsWithBlockAsync:(PINDiskCacheFileURLEnumerationBlock)block completionBlock:(PINCacheBlock)completionBlock
{
    [self.operationQueue scheduleOperation:^{
        [self enumerateObjectsWithBlock:block];
        
        if (completionBlock) {
            completionBlock(self);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

#pragma mark - Public Synchronous Methods -
// 同步获得文件，并保证可读
- (void)synchronouslyLockFileAccessWhileExecutingBlock:(PIN_NOESCAPE PINCacheBlock)block
{
    if (block) {
        [self lockForWriting];
            block(self);
        [self unlock];
    }
}

// 同步检查是否包含文件
- (BOOL)containsObjectForKey:(NSString *)key
{
    [self lock];
        if (_metadata[key] != nil || _diskStateKnown == NO) {
            BOOL objectExpired = NO;
            if (self->_ttlCache && _metadata[key].createdDate != nil) {
                NSTimeInterval ageLimit = _metadata[key].ageLimit > 0.0 ? _metadata[key].ageLimit : self->_ageLimit;
                objectExpired = ageLimit > 0 && fabs([_metadata[key].createdDate timeIntervalSinceDate:[NSDate date]]) > ageLimit;
            }
            [self unlock];
            return (!objectExpired && [self fileURLForKey:key updateFileModificationDate:NO] != nil);
        }
    [self unlock];
    return NO;
}

// 同步获得已经编码过的文件内容，递进
- (nullable id<NSCoding>)objectForKey:(NSString *)key
{
    return [self objectForKey:key fileURL:nil];
}

// 同步获得已经编码过的文件内容，递进
- (id)objectForKeyedSubscript:(NSString *)key
{
    return [self objectForKey:key];
}

// 同步获得已经编码过的文件递进
- (nullable id <NSCoding>)objectForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    [self lock];
        BOOL containsKey = _metadata[key] != nil || _diskStateKnown == NO;
    [self unlock];

    if (!key || !containsKey)
        return nil;
    
    id <NSCoding> object = nil;
    // 解码获得文件路径
    NSURL *fileURL = [self encodedFileURLForKey:key];
    
    NSDate *now = [NSDate date];
    [self lock];
    // 检查是否过期
        if (self->_ttlCache) {
            // 文件结构是否已经被解析，如果没有解析，那么就进行解析单个文件
            if (!_diskStateKnown) {
                if (_metadata[key] == nil) {
                    NSString *fileKey = [self keyForEncodedFileURL:fileURL];
                    [self _locked_initializeDiskPropertiesForFile:fileURL fileKey:fileKey];
                }
            }
        }

        NSTimeInterval ageLimit = _metadata[key].ageLimit > 0.0 ? _metadata[key].ageLimit : self->_ageLimit;
    // 保证文件有效
        if (!self->_ttlCache || ageLimit <= 0 || fabs([_metadata[key].createdDate timeIntervalSinceDate:now]) < ageLimit) {
            // If the cache should behave like a TTL cache, then only fetch the object if there's a valid ageLimit and  the object is still alive
            
            NSData *objectData = [[NSData alloc] initWithContentsOfFile:[fileURL path]];
          
            if (objectData) {
              //Be careful with locking below. We unlock here so that we're not locked while deserializing, we re-lock after.
              [self unlock];
              @try {
                  // 尝试反序列化内容
                  object = _deserializer(objectData, key);
              }
              @catch (NSException *exception) {
                  NSError *error = nil;
                  [self lock];
                      [[NSFileManager defaultManager] removeItemAtPath:[fileURL path] error:&error];
                  [self unlock];
                  PINDiskCacheError(error)
                  PINDiskCacheException(exception);
              }
              [self lock];
            }
            // 如果有值就进行记录，并写入最后修改时间
            if (object) {
                _metadata[key].lastModifiedDate = now;
                [self asynchronouslySetFileModificationDate:now forURL:fileURL];
            }
        }
    [self unlock];
    
    // 引用调用返回路径
    if (outFileURL) {
        *outFileURL = fileURL;
    }
    
    // 返回对象
    return object;
}

/// Helper function to call fileURLForKey:updateFileModificationDate:
// 同步获得文件路径
- (NSURL *)fileURLForKey:(NSString *)key
{
    // Don't update the file modification time, if self is a ttlCache
    return [self fileURLForKey:key updateFileModificationDate:!self->_ttlCache];
}

// 获得路径并进行解析是否要更新对应的修改时间
- (NSURL *)fileURLForKey:(NSString *)key updateFileModificationDate:(BOOL)updateFileModificationDate
{
    if (!key) {
        return nil;
    }
    
    NSDate *now = [NSDate date];
    NSURL *fileURL = [self encodedFileURLForKey:key];
    
    [self lockForWriting];
        if (fileURL.path && [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            if (updateFileModificationDate) {
                _metadata[key].lastModifiedDate = now;
                [self asynchronouslySetFileModificationDate:now forURL:fileURL];
            }
        } else {
            fileURL = nil;
        }
    [self unlock];
    return fileURL;
}

// 同步文件写入文件，递进
- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key
{
    [self setObject:object forKey:key withAgeLimit:0.0];
}

// 同步文件写入文件，递进
- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withAgeLimit:(NSTimeInterval)ageLimit
{
    [self setObject:object forKey:key withAgeLimit:ageLimit fileURL:nil];
}

// 同步文件写入文件，递进
- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost ageLimit:(NSTimeInterval)ageLimit
{
    [self setObject:object forKey:key withAgeLimit:ageLimit];
}

// 同步文件写入文件，递进
- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost
{
    [self setObject:object forKey:key];
}

// 写入或者删除对应已经编码的文件名
- (void)setObject:(id)object forKeyedSubscript:(NSString *)key
{
    if (object == nil) {
        [self removeObjectForKey:key];
    } else {
        [self setObject:object forKey:key];
    }
}

// 写入文件
- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withAgeLimit:(NSTimeInterval)ageLimit fileURL:(NSURL **)outFileURL
{
    // 保证文件生命周期
    NSAssert(ageLimit <= 0.0 || (ageLimit > 0.0 && _ttlCache), @"ttlCache must be set to YES if setting an object-level age limit.");

    if (!key || !object)
        return;
    
    // 读写性，保证原子性
    NSDataWritingOptions writeOptions = NSDataWritingAtomic;
    #if TARGET_OS_IPHONE
    // 设定写入的方案
    if (self.writingProtectionOptionSet) {
        writeOptions |= self.writingProtectionOption;
    }
    #endif
  
    // Remain unlocked here so that we're not locked while serializing.
    // 序列化数据和件
    NSData *data = _serializer(object, key);
    NSURL *fileURL = nil;

    NSUInteger byteLimit = self.byteLimit;
    // 判断空间是否足够，如果够，才创建地址
    if (data.length <= byteLimit || byteLimit == 0) {
        // The cache is large enough to fit this object (although we may need to evict others).
        fileURL = [self encodedFileURLForKey:key];
    } else {
        // The cache isn't large enough to fit this object (even if all others were evicted).
        // We should not write it to disk because it will be deleted immediately after.
        if (outFileURL) {
            *outFileURL = nil;
        }
        return;
    }

    [self lockForWriting];
    // 准备写入
        PINCacheObjectBlock willAddObjectBlock = self->_willAddObjectBlock;
        if (willAddObjectBlock) {
            [self unlock];
                willAddObjectBlock(self, key, object);
            [self lock];
        }
    // 文件写入
        NSError *writeError = nil;
        BOOL written = [data writeToURL:fileURL options:writeOptions error:&writeError];
        PINDiskCacheError(writeError);
    
    // 写入完成，在内存中创建引用对象
        if (written) {
            if (_metadata[key] == nil) {
                _metadata[key] = [[PINDiskCacheMetadata alloc] init];
            }
            
            NSError *error = nil;
            // 重新读取文件，用于元数据创建
            NSDictionary *values = [fileURL resourceValuesForKeys:@[ NSURLCreationDateKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ] error:&error];
            PINDiskCacheError(error);
            
            NSNumber *diskFileSize = [values objectForKey:NSURLTotalFileAllocatedSizeKey];
            if (diskFileSize) {
                NSNumber *prevDiskFileSize = self->_metadata[key].size;
                if (prevDiskFileSize) {
                    self.byteCount = self->_byteCount - [prevDiskFileSize unsignedIntegerValue];
                }
                // 计算总空间
                self->_metadata[key].size = diskFileSize;
                self.byteCount = self->_byteCount + [diskFileSize unsignedIntegerValue]; // atomic
            }
            // 设置时间
            NSDate *createdDate = [values objectForKey:NSURLCreationDateKey];
            if (createdDate) {
                self->_metadata[key].createdDate = createdDate;
            }
            // 设置上一次修改时间为当前时间
            NSDate *lastModifiedDate = [values objectForKey:NSURLContentModificationDateKey];
            if (lastModifiedDate) {
                self->_metadata[key].lastModifiedDate = lastModifiedDate;
            }
            [self asynchronouslySetAgeLimit:ageLimit forURL:fileURL];
            if (self->_byteLimit > 0 && self->_byteCount > self->_byteLimit)
                [self trimToSizeByDateAsync:self->_byteLimit completion:nil];
        } else {
            fileURL = nil;
        }
    
    // 写入完成
        PINCacheObjectBlock didAddObjectBlock = self->_didAddObjectBlock;
        if (didAddObjectBlock) {
            [self unlock];
                didAddObjectBlock(self, key, object);
            [self lock];
        }
    [self unlock];
    
    // 通过引用进行传入，返回地址。为什么要用引用，而不是直接返回？
    if (outFileURL) {
        *outFileURL = fileURL;
    }
}

// 删除对象，递进
- (void)removeObjectForKey:(NSString *)key
{
    [self removeObjectForKey:key fileURL:nil];
}

// 删除对象，并通过引用返回对应的 url 地址
- (void)removeObjectForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    if (!key)
        return;
    
    NSURL *fileURL = nil;
    
    fileURL = [self encodedFileURLForKey:key];
    
    [self removeFileAndExecuteBlocksForKey:key];
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
}

// 删除文件到指定大小
- (void)trimToSize:(NSUInteger)trimByteCount
{
    if (trimByteCount == 0) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToSize:trimByteCount];
}

// 删除老文件到指定时间
- (void)trimToDate:(NSDate *)trimDate
{
    if (!trimDate)
        return;
    
    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToDate:trimDate];
}

// 根据时间来删除老文件到指定大小
- (void)trimToSizeByDate:(NSUInteger)trimByteCount
{
    if (trimByteCount == 0) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToSizeByDate:trimByteCount];
}

// 删除过期文件
- (void)removeExpiredObjects
{
    [self lockForWriting];
        NSDate *now = [NSDate date];
        NSMutableArray<NSString *> *expiredObjectKeys = [NSMutableArray array];
        [_metadata enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, PINDiskCacheMetadata * _Nonnull obj, BOOL * _Nonnull stop) {
            NSTimeInterval ageLimit = obj.ageLimit > 0.0 ? obj.ageLimit : self->_ageLimit;
            NSDate *expirationDate = [obj.createdDate dateByAddingTimeInterval:ageLimit];
            if ([expirationDate compare:now] == NSOrderedAscending) { // Expiration date has passed
                [expiredObjectKeys addObject:key];
            }
        }];
    [self unlock];

    for (NSString *key in expiredObjectKeys) {
        //unlock, removeFileAndExecuteBlocksForKey handles locking itself
        [self removeFileAndExecuteBlocksForKey:key];
    }
}

// 删除所有文件
- (void)removeAllObjects
{
    // We don't need to know the disk state since we're just going to remove everything.
    [self lockForWriting];
    // 准备开始删除，调用引用
        PINCacheBlock willRemoveAllObjectsBlock = self->_willRemoveAllObjectsBlock;
        if (willRemoveAllObjectsBlock) {
            [self unlock];
                willRemoveAllObjectsBlock(self);
            [self lock];
        }
    // 移动到垃圾文件夹中
        [PINDiskCache moveItemAtURLToTrash:self->_cacheURL];
    // 清空
        [PINDiskCache emptyTrash];
    
    // 重新创建一个新的缓存路径
        [self _locked_createCacheDirectory];
    // 清空元数据
        [self->_metadata removeAllObjects];
        self.byteCount = 0; // atomic
    
    // 删除完成
        PINCacheBlock didRemoveAllObjectsBlock = self->_didRemoveAllObjectsBlock;
        if (didRemoveAllObjectsBlock) {
            [self unlock];
                didRemoveAllObjectsBlock(self);
            [self lock];
        }
    
    [self unlock];
}

// 同步便利所有文件
- (void)enumerateObjectsWithBlock:(PIN_NOESCAPE PINDiskCacheFileURLEnumerationBlock)block
{
    if (!block)
        return;
    
    // 需要等待文件结构获取完全才能进行遍历
    [self lockAndWaitForKnownState];
        NSDate *now = [NSDate date];
    
        for (NSString *key in _metadata) {
            NSURL *fileURL = [self encodedFileURLForKey:key];
            // If the cache should behave like a TTL cache, then only fetch the object if there's a valid ageLimit and the object is still alive
            NSDate *createdDate = _metadata[key].createdDate;
            NSTimeInterval ageLimit = _metadata[key].ageLimit > 0.0 ? _metadata[key].ageLimit : self->_ageLimit;
            // 判断文件是否有效
            if (!self->_ttlCache || ageLimit <= 0 || (createdDate && fabs([createdDate timeIntervalSinceDate:now]) < ageLimit)) {
                BOOL stop = NO;
                block(key, fileURL, &stop);
                if (stop)
                    break;
            }
        }
    [self unlock];
}

#pragma mark - Public Thread Safe Accessors -
// SETTER / GETTER
- (PINDiskCacheObjectBlock)willAddObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _willAddObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setWillAddObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willAddObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)willRemoveObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _willRemoveObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setWillRemoveObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willRemoveObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINCacheBlock)willRemoveAllObjectsBlock
{
    PINCacheBlock block = nil;
    
    [self lock];
        block = _willRemoveAllObjectsBlock;
    [self unlock];
    
    return block;
}

- (void)setWillRemoveAllObjectsBlock:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willRemoveAllObjectsBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)didAddObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _didAddObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setDidAddObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didAddObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)didRemoveObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _didRemoveObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setDidRemoveObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didRemoveObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINCacheBlock)didRemoveAllObjectsBlock
{
    PINCacheBlock block = nil;
    
    [self lock];
        block = _didRemoveAllObjectsBlock;
    [self unlock];
    
    return block;
}

- (void)setDidRemoveAllObjectsBlock:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didRemoveAllObjectsBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (NSUInteger)byteLimit
{
    NSUInteger byteLimit;
    
    [self lock];
        byteLimit = _byteLimit;
    [self unlock];
    
    return byteLimit;
}

- (void)setByteLimit:(NSUInteger)byteLimit
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_byteLimit = byteLimit;
        [self unlock];
        
        if (byteLimit > 0)
            [self trimDiskToSizeByDate:byteLimit];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (NSTimeInterval)ageLimit
{
    NSTimeInterval ageLimit;
    
    [self lock];
        ageLimit = _ageLimit;
    [self unlock];
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_ageLimit = ageLimit;
        [self unlock];
        
        [self.operationQueue scheduleOperation:^{
            [self trimToAgeLimitRecursively];
        } withPriority:PINOperationQueuePriorityLow];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (BOOL)isTTLCache
{
    BOOL isTTLCache;
    
    [self lock];
        isTTLCache = _ttlCache;
    [self unlock];
  
    return isTTLCache;
}

#if TARGET_OS_IPHONE
- (NSDataWritingOptions)writingProtectionOption
{
    NSDataWritingOptions option;
  
    [self lock];
        option = _writingProtectionOption;
    [self unlock];
  
    return option;
}

- (void)setWritingProtectionOption:(NSDataWritingOptions)writingProtectionOption
{
  [self.operationQueue scheduleOperation:^{
      NSDataWritingOptions option = NSDataWritingFileProtectionMask & writingProtectionOption;
    
      [self lock];
          self->_writingProtectionOptionSet = YES;
          self->_writingProtectionOption = option;
      [self unlock];
  } withPriority:PINOperationQueuePriorityHigh];
}
#endif

// 直到文件当前文件可再被写入，说明可以进行修改了。
- (void)lockForWriting
{
    [self lock];
    
    // Lock if the disk isn't writable.
    if (_diskWritable == NO) {
        // 如果文件路径还没初始化，那么就等待
        pthread_cond_wait(&_diskWritableCondition, &_mutex);
    }
}

- (void)lockAndWaitForKnownState
{
    [self lock];
    
    // Lock if the disk state isn't known.
    if (_diskStateKnown == NO) {
        // 如果文件属性还没初始化，那么就等待
        pthread_cond_wait(&_diskStateKnownCondition, &_mutex);
    }
}

- (void)lock
{
    __unused int result = pthread_mutex_lock(&_mutex);
    NSAssert(result == 0, @"Failed to lock PINDiskCache %@. Code: %d", self, result);
}

- (void)unlock
{
    __unused int result = pthread_mutex_unlock(&_mutex);
    NSAssert(result == 0, @"Failed to unlock PINDiskCache %@. Code: %d", self, result);
}

@end

@implementation PINDiskCache (Deprecated)

- (void)lockFileAccessWhileExecutingBlock:(nullable PINCacheBlock)block
{
    [self lockFileAccessWhileExecutingBlockAsync:block];
}

- (void)containsObjectForKey:(NSString *)key block:(PINDiskCacheContainsBlock)block
{
    [self containsObjectForKeyAsync:key completion:block];
}

- (void)objectForKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self objectForKeyAsync:key completion:block];
}

- (void)fileURLForKey:(NSString *)key block:(nullable PINDiskCacheFileURLBlock)block
{
    [self fileURLForKeyAsync:key completion:block];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key completion:block];
}

- (void)removeObjectForKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self removeObjectForKeyAsync:key completion:block];
}

- (void)trimToDate:(NSDate *)date block:(nullable PINDiskCacheBlock)block
{
    [self trimToDateAsync:date completion:block];
}

- (void)trimToSize:(NSUInteger)byteCount block:(nullable PINDiskCacheBlock)block
{
    [self trimToSizeAsync:byteCount completion:block];
}

- (void)trimToSizeByDate:(NSUInteger)byteCount block:(nullable PINDiskCacheBlock)block
{
    [self trimToSizeAsync:byteCount completion:block];
}

- (void)removeAllObjects:(nullable PINDiskCacheBlock)block
{
    [self removeAllObjectsAsync:block];
}

- (void)enumerateObjectsWithBlock:(PINDiskCacheFileURLBlock)block completionBlock:(nullable PINDiskCacheBlock)completionBlock
{
    [self enumerateObjectsWithBlockAsync:^(NSString * _Nonnull key, NSURL * _Nullable fileURL, BOOL * _Nonnull stop) {
      block(key, fileURL);
    } completionBlock:completionBlock];
}

- (void)setTtlCache:(BOOL)ttlCache
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_ttlCache = ttlCache;
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

@end

@implementation PINDiskCacheMetadata
@end
