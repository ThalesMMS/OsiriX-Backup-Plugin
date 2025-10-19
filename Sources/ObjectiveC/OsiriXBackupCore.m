//
//  OsiriXBackupCore.m
//  Advanced DICOM Backup System Core Implementation
//

#import "OsiriXBackupCore.h"
#import "OsiriXTestPlugin-Swift.h"
#import <OsiriXAPI/DicomStudy.h>
#import <OsiriXAPI/DicomSeries.h>
#import <AppKit/AppKit.h>

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