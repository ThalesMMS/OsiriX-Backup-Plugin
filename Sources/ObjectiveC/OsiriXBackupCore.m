//
//  OsiriXBackupCore.m
//  Advanced DICOM Backup System Core Implementation
//

#import "OsiriXBackupCore.h"
#import <OsiriXAPI/DicomStudy.h>
#import <OsiriXAPI/DicomSeries.h>
#import <CommonCrypto/CommonDigest.h>
#import <zlib.h>
#import <AppKit/AppKit.h>

#pragma mark - Cache Manager Implementation

@implementation OsiriXBackupCacheManager

+ (instancetype)sharedManager {
    static OsiriXBackupCacheManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        _studyCache = [[NSCache alloc] init];
        _studyCache.countLimit = 1000;
        _studyCache.totalCostLimit = 100 * 1024 * 1024; // 100MB
        
        _hashCache = [[NSMutableDictionary alloc] init];
        _maxCacheSize = 500 * 1024 * 1024; // 500MB default
        
        [self loadCacheFromDisk];
    }
    return self;
}

- (void)cacheStudy:(DicomStudy *)study withHash:(NSString *)hash {
    if (!study || !hash) return;
    
    NSString *studyUID = [study valueForKey:@"studyInstanceUID"];
    [_studyCache setObject:study forKey:studyUID cost:1];
    _hashCache[studyUID] = @{
        @"hash": hash,
        @"date": [NSDate date],
        @"name": [study valueForKey:@"name"] ?: @"",
        @"modality": [study valueForKey:@"modality"] ?: @""
    };
    
    // Persist to disk periodically
    static NSInteger cacheWrites = 0;
    if (++cacheWrites % 10 == 0) {
        [self persistCacheToDisk];
    }
}

- (NSString *)cachedHashForStudy:(NSString *)studyUID {
    NSDictionary *cacheEntry = _hashCache[studyUID];
    return cacheEntry[@"hash"];
}

- (BOOL)isStudyCached:(NSString *)studyUID {
    return _hashCache[studyUID] != nil;
}

- (void)invalidateCache {
    [_studyCache removeAllObjects];
    [_hashCache removeAllObjects];
    
    // Remove persisted cache
    NSString *cachePath = [self cacheFilePath];
    [[NSFileManager defaultManager] removeItemAtPath:cachePath error:nil];
}

- (void)persistCacheToDisk {
    @try {
        NSString *cachePath = [self cacheFilePath];
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:_hashCache 
                                            requiringSecureCoding:NO 
                                                            error:nil];
        [data writeToFile:cachePath atomically:YES];
        NSLog(@"[OsiriXBackupCache] Cache persisted: %lu entries", (unsigned long)_hashCache.count);
    } @catch (NSException *exception) {
        NSLog(@"[OsiriXBackupCache] Failed to persist cache: %@", exception);
    }
}

- (void)loadCacheFromDisk {
    @try {
        NSString *cachePath = [self cacheFilePath];
        NSData *data = [NSData dataWithContentsOfFile:cachePath];
        if (data) {
            _hashCache = [NSKeyedUnarchiver unarchiveObjectWithData:data];
            NSLog(@"[OsiriXBackupCache] Cache loaded: %lu entries", (unsigned long)_hashCache.count);
        }
    } @catch (NSException *exception) {
        NSLog(@"[OsiriXBackupCache] Failed to load cache: %@", exception);
        _hashCache = [[NSMutableDictionary alloc] init];
    }
}

- (NSString *)cacheFilePath {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, 
                                                                NSUserDomainMask, YES) firstObject];
    NSString *cacheDir = [appSupport stringByAppendingPathComponent:@"OsiriXBackup"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:nil];
    return [cacheDir stringByAppendingPathComponent:@"study_cache.plist"];
}

- (NSDictionary *)cacheStatistics {
    NSUInteger totalSize = 0;
    NSDate *oldestEntry = nil;
    NSDate *newestEntry = nil;
    
    for (NSDictionary *entry in _hashCache.allValues) {
        NSDate *date = entry[@"date"];
        if (!oldestEntry || [date compare:oldestEntry] == NSOrderedAscending) {
            oldestEntry = date;
        }
        if (!newestEntry || [date compare:newestEntry] == NSOrderedDescending) {
            newestEntry = date;
        }
    }
    
    return @{
        @"totalEntries": @(_hashCache.count),
        @"cacheSize": @(totalSize),
        @"oldestEntry": oldestEntry ?: [NSNull null],
        @"newestEntry": newestEntry ?: [NSNull null],
        @"hitRate": @(0.0) // Would need to track hits/misses
    };
}

@end

#pragma mark - Transfer Queue Item Implementation

@implementation OsiriXTransferQueueItem

- (instancetype)init {
    if (self = [super init]) {
        _status = OsiriXTransferStatusPending;
        _priority = OsiriXTransferPriorityNormal;
        _queuedDate = [NSDate date];
        _retryCount = 0;
        _nextRetryInterval = 5.0;
    }
    return self;
}

- (NSTimeInterval)elapsedTime {
    if (!_startDate) return 0;
    NSDate *endDate = _completionDate ?: [NSDate date];
    return [endDate timeIntervalSinceDate:_startDate];
}

- (NSTimeInterval)estimatedTimeRemaining {
    if (_transferredImages == 0 || _transferSpeed == 0) return -1;
    
    NSUInteger remainingImages = _totalImages - _transferredImages;
    double avgImageSize = 0.5; // MB estimate
    double remainingMB = remainingImages * avgImageSize;
    
    return remainingMB / _transferSpeed;
}

- (double)progressPercentage {
    if (_totalImages == 0) return 0;
    return (100.0 * _transferredImages) / _totalImages;
}

@end

#pragma mark - Transfer Queue Implementation

@implementation OsiriXTransferQueue

- (instancetype)init {
    if (self = [super init]) {
        _queue = [[NSMutableArray alloc] init];
        _maxConcurrentTransfers = 3;
        _maxRetries = 3;
        _enablePriorityQueue = YES;
    }
    return self;
}

- (void)addItem:(OsiriXTransferQueueItem *)item {
    @synchronized (_queue) {
        [_queue addObject:item];
        if (_enablePriorityQueue) {
            [self sortQueueByPriority];
        }
    }
}

- (void)removeItem:(OsiriXTransferQueueItem *)item {
    @synchronized (_queue) {
        [_queue removeObject:item];
    }
}

- (OsiriXTransferQueueItem *)nextItemToProcess {
    @synchronized (_queue) {
        // Count active transfers
        NSUInteger activeCount = 0;
        for (OsiriXTransferQueueItem *item in _queue) {
            if (item.status == OsiriXTransferStatusInProgress) {
                activeCount++;
            }
        }
        
        if (activeCount >= _maxConcurrentTransfers) {
            return nil;
        }
        
        // Find next pending item
        for (OsiriXTransferQueueItem *item in _queue) {
            if (item.status == OsiriXTransferStatusPending || 
                item.status == OsiriXTransferStatusQueued) {
                return item;
            }
        }
        
        // Check for items that need retry
        NSDate *now = [NSDate date];
        for (OsiriXTransferQueueItem *item in _queue) {
            if (item.status == OsiriXTransferStatusRetrying) {
                NSDate *nextRetryDate = [item.queuedDate dateByAddingTimeInterval:item.nextRetryInterval];
                if ([now compare:nextRetryDate] == NSOrderedDescending) {
                    return item;
                }
            }
        }
        
        return nil;
    }
}

- (NSArray<OsiriXTransferQueueItem *> *)itemsWithStatus:(OsiriXTransferStatus)status {
    @synchronized (_queue) {
        NSMutableArray *items = [NSMutableArray array];
        for (OsiriXTransferQueueItem *item in _queue) {
            if (item.status == status) {
                [items addObject:item];
            }
        }
        return [items copy];
    }
}

- (void)prioritizeItem:(OsiriXTransferQueueItem *)item {
    @synchronized (_queue) {
        item.priority = OsiriXTransferPriorityUrgent;
        [self sortQueueByPriority];
    }
}

- (void)cancelAllTransfers {
    @synchronized (_queue) {
        for (OsiriXTransferQueueItem *item in _queue) {
            if (item.status == OsiriXTransferStatusInProgress ||
                item.status == OsiriXTransferStatusPending ||
                item.status == OsiriXTransferStatusQueued) {
                item.status = OsiriXTransferStatusCancelled;
            }
        }
    }
}

- (void)sortQueueByPriority {
    [_queue sortUsingComparator:^NSComparisonResult(OsiriXTransferQueueItem *obj1, 
                                                     OsiriXTransferQueueItem *obj2) {
        // First sort by priority
        if (obj1.priority > obj2.priority) return NSOrderedAscending;
        if (obj1.priority < obj2.priority) return NSOrderedDescending;
        
        // Then by queued date
        return [obj1.queuedDate compare:obj2.queuedDate];
    }];
}

- (NSDictionary *)queueStatistics {
    @synchronized (_queue) {
        NSUInteger pending = 0, inProgress = 0, completed = 0, failed = 0;
        double totalProgress = 0;
        
        for (OsiriXTransferQueueItem *item in _queue) {
            switch (item.status) {
                case OsiriXTransferStatusPending:
                case OsiriXTransferStatusQueued:
                    pending++;
                    break;
                case OsiriXTransferStatusInProgress:
                    inProgress++;
                    totalProgress += item.progressPercentage;
                    break;
                case OsiriXTransferStatusCompleted:
                    completed++;
                    break;
                case OsiriXTransferStatusFailed:
                    failed++;
                    break;
                default:
                    break;
            }
        }
        
        return @{
            @"totalItems": @(_queue.count),
            @"pending": @(pending),
            @"inProgress": @(inProgress),
            @"completed": @(completed),
            @"failed": @(failed),
            @"averageProgress": @(inProgress > 0 ? totalProgress/inProgress : 0)
        };
    }
}

@end

#pragma mark - Integrity Validator Implementation

@implementation OsiriXIntegrityValidator

+ (NSString *)sha256HashForFile:(NSString *)filePath {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!file) return nil;
    
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    
    NSData *data;
    while ((data = [file readDataOfLength:4096]).length > 0) {
        CC_SHA256_Update(&ctx, data.bytes, (CC_LONG)data.length);
    }
    
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    
    NSMutableString *hash = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hash appendFormat:@"%02x", digest[i]];
    }
    
    [file closeFile];
    return hash;
}

+ (NSString *)sha256HashForData:(NSData *)data {
    if (!data) return nil;
    
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    
    NSMutableString *hash = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hash appendFormat:@"%02x", digest[i]];
    }
    
    return hash;
}

+ (NSString *)sha256HashForStudy:(DicomStudy *)study {
    if (!study) return nil;
    
    NSMutableString *combinedData = [NSMutableString string];
    
    // Include study metadata
    [combinedData appendString:[study valueForKey:@"studyInstanceUID"] ?: @""];
    [combinedData appendString:[study valueForKey:@"name"] ?: @""];
    [combinedData appendString:[[study valueForKey:@"date"] description] ?: @""];
    
    // Include series and image UIDs
    NSArray *series = [study valueForKey:@"series"];
    for (DicomSeries *s in series) {
        [combinedData appendString:[s valueForKey:@"seriesInstanceUID"] ?: @""];
        NSArray *images = [s valueForKey:@"images"];
        [combinedData appendFormat:@"%lu", (unsigned long)images.count];
    }
    
    NSData *data = [combinedData dataUsingEncoding:NSUTF8StringEncoding];
    return [self sha256HashForData:data];
}

+ (BOOL)validateStudyIntegrity:(DicomStudy *)study expectedHash:(NSString *)hash {
    NSString *currentHash = [self sha256HashForStudy:study];
    return [currentHash isEqualToString:hash];
}

+ (NSDictionary *)generateStudyManifest:(DicomStudy *)study {
    NSMutableDictionary *manifest = [NSMutableDictionary dictionary];
    
    manifest[@"studyInstanceUID"] = [study valueForKey:@"studyInstanceUID"];
    manifest[@"studyHash"] = [self sha256HashForStudy:study];
    manifest[@"createdDate"] = [NSDate date];
    manifest[@"studyDate"] = [study valueForKey:@"date"];
    manifest[@"patientName"] = [study valueForKey:@"name"];
    
    NSMutableArray *seriesManifest = [NSMutableArray array];
    NSArray *series = [study valueForKey:@"series"];
    
    for (DicomSeries *s in series) {
        NSMutableDictionary *seriesInfo = [NSMutableDictionary dictionary];
        seriesInfo[@"seriesInstanceUID"] = [s valueForKey:@"seriesInstanceUID"];
        seriesInfo[@"modality"] = [s valueForKey:@"modality"];
        seriesInfo[@"imageCount"] = @([[s valueForKey:@"images"] count]);
        
        // Generate hash for each series
        NSMutableString *seriesData = [NSMutableString string];
        [seriesData appendString:[s valueForKey:@"seriesInstanceUID"] ?: @""];
        for (id image in [s valueForKey:@"images"]) {
            [seriesData appendString:[image valueForKey:@"sopInstanceUID"] ?: @""];
        }
        seriesInfo[@"seriesHash"] = [self sha256HashForData:[seriesData dataUsingEncoding:NSUTF8StringEncoding]];
        
        [seriesManifest addObject:seriesInfo];
    }
    
    manifest[@"series"] = seriesManifest;
    manifest[@"totalImages"] = @([self totalImagesInStudy:study]);
    
    return manifest;
}

+ (NSUInteger)totalImagesInStudy:(DicomStudy *)study {
    NSUInteger total = 0;
    for (DicomSeries *series in [study valueForKey:@"series"]) {
        total += [[series valueForKey:@"images"] count];
    }
    return total;
}

+ (BOOL)validateManifest:(NSDictionary *)manifest forStudy:(DicomStudy *)study {
    if (!manifest || !study) return NO;
    
    // Validate study UID
    if (![[manifest[@"studyInstanceUID"] lowercaseString] isEqualToString:
          [[study valueForKey:@"studyInstanceUID"] lowercaseString]]) {
        return NO;
    }
    
    // Validate study hash
    NSString *currentHash = [self sha256HashForStudy:study];
    if (![currentHash isEqualToString:manifest[@"studyHash"]]) {
        NSLog(@"[IntegrityValidator] Study hash mismatch");
        return NO;
    }
    
    // Validate image count
    NSUInteger currentImages = [self totalImagesInStudy:study];
    if (currentImages != [manifest[@"totalImages"] unsignedIntegerValue]) {
        NSLog(@"[IntegrityValidator] Image count mismatch: %lu vs %@", 
              (unsigned long)currentImages, manifest[@"totalImages"]);
        return NO;
    }
    
    return YES;
}

@end

#pragma mark - Network Optimizer Implementation

@implementation OsiriXNetworkOptimizer

- (instancetype)init {
    if (self = [super init]) {
        _chunkSize = 65536; // 64KB default
        _windowSize = 4;
        _enableAdaptiveBandwidth = YES;
        _targetUtilization = 0.7; // 70% network utilization
        _currentBandwidth = 10.0; // 10 MB/s initial estimate
    }
    return self;
}

- (void)optimizeForNetwork:(NSString *)networkType {
    if ([networkType isEqualToString:@"WiFi"]) {
        _chunkSize = 32768; // 32KB for WiFi
        _windowSize = 3;
        _targetUtilization = 0.6;
    } else if ([networkType isEqualToString:@"Ethernet"]) {
        _chunkSize = 131072; // 128KB for Ethernet
        _windowSize = 6;
        _targetUtilization = 0.8;
    } else if ([networkType isEqualToString:@"Cellular"]) {
        _chunkSize = 16384; // 16KB for cellular
        _windowSize = 2;
        _targetUtilization = 0.5;
    }
    
    NSLog(@"[NetworkOptimizer] Optimized for %@: chunk=%lu, window=%lu", 
          networkType, (unsigned long)_chunkSize, (unsigned long)_windowSize);
}

- (void)measureBandwidthToHost:(NSString *)host port:(NSInteger)port completion:(void(^)(double bandwidth))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Create test data
        NSUInteger testSize = 1024 * 1024; // 1MB test
        NSMutableData *testData = [NSMutableData dataWithLength:testSize];
        arc4random_buf(testData.mutableBytes, testSize);
        
        NSDate *startTime = [NSDate date];
        
        // Simulate network transfer (would actually send to host:port)
        // In real implementation, use NSURLSession or socket
        [NSThread sleepForTimeInterval:0.1]; // Simulated transfer
        
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startTime];
        double bandwidth = (testSize / 1024.0 / 1024.0) / elapsed; // MB/s
        
        self->_currentBandwidth = bandwidth;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(bandwidth);
        });
    });
}

- (NSUInteger)optimalChunkSizeForBandwidth:(double)bandwidth {
    // Calculate optimal chunk size based on bandwidth
    // Goal: chunks should take ~100ms to transfer
    NSUInteger optimalSize = (NSUInteger)(bandwidth * 1024 * 1024 * 0.1);
    
    // Clamp to reasonable values
    if (optimalSize < 8192) optimalSize = 8192; // Min 8KB
    if (optimalSize > 1048576) optimalSize = 1048576; // Max 1MB
    
    // Round to nearest power of 2
    NSUInteger powerOf2 = 1;
    while (powerOf2 < optimalSize) powerOf2 <<= 1;
    if (powerOf2 - optimalSize > optimalSize - (powerOf2 >> 1)) {
        powerOf2 >>= 1;
    }
    
    return powerOf2;
}

- (void)adjustTransferParameters {
    if (!_enableAdaptiveBandwidth) return;
    
    NSUInteger newChunkSize = [self optimalChunkSizeForBandwidth:_currentBandwidth];
    if (newChunkSize != _chunkSize) {
        NSLog(@"[NetworkOptimizer] Adjusting chunk size: %lu -> %lu", 
              (unsigned long)_chunkSize, (unsigned long)newChunkSize);
        _chunkSize = newChunkSize;
    }
    
    // Adjust window size based on bandwidth
    if (_currentBandwidth > 50) {
        _windowSize = 8;
    } else if (_currentBandwidth > 20) {
        _windowSize = 6;
    } else if (_currentBandwidth > 10) {
        _windowSize = 4;
    } else {
        _windowSize = 2;
    }
}

- (NSDictionary *)networkStatistics {
    return @{
        @"currentBandwidth": @(_currentBandwidth),
        @"chunkSize": @(_chunkSize),
        @"windowSize": @(_windowSize),
        @"targetUtilization": @(_targetUtilization),
        @"adaptiveEnabled": @(_enableAdaptiveBandwidth)
    };
}

@end

#pragma mark - Backup Statistics Implementation

@implementation OsiriXBackupStatistics

- (instancetype)init {
    if (self = [super init]) {
        [self reset];
    }
    return self;
}

- (void)recordTransfer:(OsiriXTransferQueueItem *)item {
    _totalStudiesProcessed++;
    _totalImagesTransferred += item.totalImages;
    _successfulTransfers++;
    
    // Estimate bytes (0.5MB per image average)
    _totalBytesTransferred += item.totalImages * 512 * 1024;
    
    NSTimeInterval transferTime = [item elapsedTime];
    _totalTransferTime += transferTime;
    
    _lastBackupDate = [NSDate date];
    if (!_firstBackupDate) {
        _firstBackupDate = _lastBackupDate;
    }
    
    // Update average speed
    if (_totalTransferTime > 0) {
        _averageTransferSpeed = (_totalBytesTransferred / 1024.0 / 1024.0) / _totalTransferTime;
    }
}

- (void)recordFailure:(OsiriXTransferQueueItem *)item error:(NSError *)error {
    _failedTransfers++;
    NSLog(@"[BackupStatistics] Failed transfer: %@ - Error: %@", item.studyName, error);
}

- (NSDictionary *)generateReport {
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    
    report[@"summary"] = @{
        @"totalStudies": @(_totalStudiesProcessed),
        @"totalImages": @(_totalImagesTransferred),
        @"totalSize": [self formatBytes:_totalBytesTransferred],
        @"successRate": @(_totalStudiesProcessed > 0 ? 
                         (100.0 * _successfulTransfers / (_successfulTransfers + _failedTransfers)) : 0),
        @"averageSpeed": [NSString stringWithFormat:@"%.2f MB/s", _averageTransferSpeed]
    };
    
    report[@"timing"] = @{
        @"firstBackup": _firstBackupDate ?: [NSNull null],
        @"lastBackup": _lastBackupDate ?: [NSNull null],
        @"totalTime": [self formatDuration:_totalTransferTime]
    };
    
    report[@"performance"] = @{
        @"successful": @(_successfulTransfers),
        @"failed": @(_failedTransfers),
        @"averageStudyTime": @(_totalStudiesProcessed > 0 ? 
                              _totalTransferTime / _totalStudiesProcessed : 0)
    };
    
    return report;
}

- (NSString *)formatBytes:(NSUInteger)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lu B", (unsigned long)bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.2f KB", bytes / 1024.0];
    if (bytes < 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.2f MB", bytes / 1024.0 / 1024.0];
    return [NSString stringWithFormat:@"%.2f GB", bytes / 1024.0 / 1024.0 / 1024.0];
}

- (NSString *)formatDuration:(NSTimeInterval)seconds {
    NSInteger hours = seconds / 3600;
    NSInteger minutes = (seconds - hours * 3600) / 60;
    NSInteger secs = seconds - hours * 3600 - minutes * 60;
    return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
}

- (void)exportToCSV:(NSString *)filePath {
    NSDictionary *report = [self generateReport];
    NSMutableString *csv = [NSMutableString string];
    
    [csv appendString:@"Metric,Value\n"];
    [csv appendFormat:@"Total Studies,%@\n", report[@"summary"][@"totalStudies"]];
    [csv appendFormat:@"Total Images,%@\n", report[@"summary"][@"totalImages"]];
    [csv appendFormat:@"Total Size,%@\n", report[@"summary"][@"totalSize"]];
    [csv appendFormat:@"Success Rate,%@%%\n", report[@"summary"][@"successRate"]];
    [csv appendFormat:@"Average Speed,%@\n", report[@"summary"][@"averageSpeed"]];
    
    [csv writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)exportToJSON:(NSString *)filePath {
    NSDictionary *report = [self generateReport];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:report 
                                                       options:NSJSONWritingPrettyPrinted 
                                                         error:nil];
    [jsonData writeToFile:filePath atomically:YES];
}

- (void)reset {
    _totalStudiesProcessed = 0;
    _totalImagesTransferred = 0;
    _totalBytesTransferred = 0;
    _failedTransfers = 0;
    _successfulTransfers = 0;
    _totalTransferTime = 0;
    _averageTransferSpeed = 0;
    _lastBackupDate = nil;
    _firstBackupDate = nil;
}

@end

#pragma mark - Error Recovery Manager Implementation

@implementation OsiriXErrorRecoveryManager

+ (instancetype)sharedManager {
    static OsiriXErrorRecoveryManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        _maxRetries = 3;
        _baseRetryInterval = 5.0;
        _backoffMultiplier = 2.0;
        _enableAutoRecovery = YES;
    }
    return self;
}

- (NSTimeInterval)nextRetryIntervalForAttempt:(NSUInteger)attempt {
    // Exponential backoff with jitter
    NSTimeInterval interval = _baseRetryInterval * pow(_backoffMultiplier, attempt - 1);
    
    // Add random jitter (±20%)
    double jitter = (arc4random_uniform(40) - 20) / 100.0;
    interval *= (1.0 + jitter);
    
    // Cap at 5 minutes
    if (interval > 300) interval = 300;
    
    return interval;
}

- (BOOL)shouldRetryError:(NSError *)error {
    if (!_enableAutoRecovery) return NO;
    
    // Network errors - always retry
    if (error.domain == NSURLErrorDomain) {
        switch (error.code) {
            case NSURLErrorTimedOut:
            case NSURLErrorCannotFindHost:
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorDNSLookupFailed:
            case NSURLErrorNotConnectedToInternet:
                return YES;
            default:
                break;
        }
    }
    
    // DICOM specific errors
    if ([error.domain isEqualToString:@"DICOMError"]) {
        switch (error.code) {
            case 0x0110: // Processing failure
            case 0x0211: // Unrecognized operation
            case 0x0212: // Mistyped argument
                return NO;
            default:
                return YES;
        }
    }
    
    return NO;
}

- (void)handleError:(NSError *)error forItem:(OsiriXTransferQueueItem *)item {
    NSLog(@"[ErrorRecovery] Handling error for %@: %@", item.studyName, error);
    
    if ([self shouldRetryError:error] && item.retryCount < _maxRetries) {
        item.retryCount++;
        item.status = OsiriXTransferStatusRetrying;
        item.nextRetryInterval = [self nextRetryIntervalForAttempt:item.retryCount];
        item.lastError = error.localizedDescription;
        
        NSLog(@"[ErrorRecovery] Scheduling retry #%lu in %.1f seconds", 
              (unsigned long)item.retryCount, item.nextRetryInterval);
    } else {
        item.status = OsiriXTransferStatusFailed;
        item.lastError = error.localizedDescription;
        
        NSLog(@"[ErrorRecovery] Transfer failed permanently: %@", item.studyName);
    }
}

- (NSArray<NSString *> *)recoverableErrorCodes {
    return @[
        @"NSURLErrorTimedOut",
        @"NSURLErrorCannotFindHost",
        @"NSURLErrorCannotConnectToHost",
        @"NSURLErrorNetworkConnectionLost",
        @"DICOMAssociationRefused",
        @"DICOMTransferSyntaxNotSupported"
    ];
}

- (void)registerRecoveryStrategy:(void(^)(NSError *error))strategy forErrorCode:(NSInteger)code {
    // Would store strategies in a dictionary for custom recovery
    // Implementation depends on specific requirements
}

@end