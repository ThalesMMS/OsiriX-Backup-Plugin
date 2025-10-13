//
//  OsiriXBackupCore.h
//  Advanced DICOM Backup System Core Components
//

#ifndef OSIRIXBACKUPCORE_H
#define OSIRIXBACKUPCORE_H

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

// Forward declarations
@class DicomStudy;
@class DicomSeries;

// Backup Types
typedef NS_ENUM(NSInteger, OsiriXBackupType) {
    OsiriXBackupTypeFull,
    OsiriXBackupTypeIncremental,
    OsiriXBackupTypeDifferential,
    OsiriXBackupTypeSmart  // AI-based selection
};

// Transfer Priority
typedef NS_ENUM(NSInteger, OsiriXTransferPriority) {
    OsiriXTransferPriorityLow = 0,
    OsiriXTransferPriorityNormal = 1,
    OsiriXTransferPriorityHigh = 2,
    OsiriXTransferPriorityUrgent = 3,
    OsiriXTransferPriorityEmergency = 4
};

// Transfer Status
typedef NS_ENUM(NSInteger, OsiriXTransferStatus) {
    OsiriXTransferStatusPending,
    OsiriXTransferStatusQueued,
    OsiriXTransferStatusInProgress,
    OsiriXTransferStatusCompleted,
    OsiriXTransferStatusFailed,
    OsiriXTransferStatusRetrying,
    OsiriXTransferStatusCancelled,
    OsiriXTransferStatusVerifying
};

// Compression Algorithms
typedef NS_ENUM(NSInteger, OsiriXCompressionType) {
    OsiriXCompressionNone,
    OsiriXCompressionGZIP,
    OsiriXCompressionZLIB,
    OsiriXCompressionLZMA,
    OsiriXCompressionJPEG2000Lossless,
    OsiriXCompressionJPEG2000Lossy
};

#pragma mark - Cache Manager

@interface OsiriXBackupCacheManager : NSObject

@property (nonatomic, strong, readonly) NSCache *studyCache;
@property (nonatomic, strong, readonly) NSMutableDictionary *hashCache;
@property (nonatomic, assign) NSUInteger maxCacheSize;

+ (instancetype)sharedManager;
- (void)cacheStudy:(DicomStudy *)study withHash:(NSString *)hash;
- (NSString *)cachedHashForStudy:(NSString *)studyUID;
- (BOOL)isStudyCached:(NSString *)studyUID;
- (void)invalidateCache;
- (void)persistCacheToDisk;
- (void)loadCacheFromDisk;
- (NSDictionary *)cacheStatistics;

@end

#pragma mark - Transfer Queue

@interface OsiriXTransferQueueItem : NSObject

@property (nonatomic, strong) NSString *studyUID;
@property (nonatomic, strong) NSString *studyName;
@property (nonatomic, strong) DicomStudy *study;
@property (nonatomic, assign) OsiriXTransferPriority priority;
@property (nonatomic, assign) OsiriXTransferStatus status;
@property (nonatomic, strong) NSDate *queuedDate;
@property (nonatomic, strong) NSDate *startDate;
@property (nonatomic, strong) NSDate *completionDate;
@property (nonatomic, assign) NSUInteger retryCount;
@property (nonatomic, assign) NSTimeInterval nextRetryInterval;
@property (nonatomic, strong) NSString *destinationAET;
@property (nonatomic, strong) NSString *lastError;
@property (nonatomic, assign) NSUInteger totalImages;
@property (nonatomic, assign) NSUInteger transferredImages;
@property (nonatomic, assign) double transferSpeed; // MB/s
@property (nonatomic, strong) NSString *sha256Hash;

- (NSTimeInterval)elapsedTime;
- (NSTimeInterval)estimatedTimeRemaining;
- (double)progressPercentage;

@end

@interface OsiriXTransferQueue : NSObject

@property (nonatomic, strong, readonly) NSMutableArray<OsiriXTransferQueueItem *> *queue;
@property (nonatomic, assign) NSUInteger maxConcurrentTransfers;
@property (nonatomic, assign) NSUInteger maxRetries;
@property (nonatomic, assign) BOOL enablePriorityQueue;

- (void)addItem:(OsiriXTransferQueueItem *)item;
- (void)removeItem:(OsiriXTransferQueueItem *)item;
- (OsiriXTransferQueueItem *)nextItemToProcess;
- (NSArray<OsiriXTransferQueueItem *> *)itemsWithStatus:(OsiriXTransferStatus)status;
- (void)prioritizeItem:(OsiriXTransferQueueItem *)item;
- (void)cancelAllTransfers;
- (NSDictionary *)queueStatistics;

@end

#pragma mark - Backup Scheduler

@interface OsiriXBackupSchedule : NSObject

@property (nonatomic, strong) NSString *scheduleID;
@property (nonatomic, strong) NSString *name;
@property (nonatomic, assign) OsiriXBackupType backupType;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) NSDate *nextRunDate;
@property (nonatomic, strong) NSString *cronExpression; // Unix cron format
@property (nonatomic, strong) NSPredicate *studyFilter;
@property (nonatomic, strong) NSArray<NSString *> *destinationAETs;
@property (nonatomic, assign) NSUInteger maxStudiesPerRun;
@property (nonatomic, strong) NSDictionary *notificationSettings;

- (BOOL)shouldRunNow;
- (NSDate *)calculateNextRunDate;
- (BOOL)matchesStudy:(DicomStudy *)study;

@end

@interface OsiriXBackupScheduler : NSObject

@property (nonatomic, strong, readonly) NSMutableArray<OsiriXBackupSchedule *> *schedules;
@property (nonatomic, strong, readonly) NSTimer *schedulerTimer;

+ (instancetype)sharedScheduler;
- (void)addSchedule:(OsiriXBackupSchedule *)schedule;
- (void)removeSchedule:(OsiriXBackupSchedule *)schedule;
- (void)enableSchedule:(NSString *)scheduleID;
- (void)disableSchedule:(NSString *)scheduleID;
- (void)startScheduler;
- (void)stopScheduler;
- (NSArray<OsiriXBackupSchedule *> *)activeSchedules;

@end

#pragma mark - Integrity Validator

@interface OsiriXIntegrityValidator : NSObject

+ (NSString *)sha256HashForFile:(NSString *)filePath;
+ (NSString *)sha256HashForData:(NSData *)data;
+ (NSString *)sha256HashForStudy:(DicomStudy *)study;
+ (BOOL)validateStudyIntegrity:(DicomStudy *)study expectedHash:(NSString *)hash;
+ (NSDictionary *)generateStudyManifest:(DicomStudy *)study;
+ (BOOL)validateManifest:(NSDictionary *)manifest forStudy:(DicomStudy *)study;

@end

#pragma mark - Network Optimizer

@interface OsiriXNetworkOptimizer : NSObject

@property (nonatomic, assign) NSUInteger chunkSize;
@property (nonatomic, assign) NSUInteger windowSize;
@property (nonatomic, assign) BOOL enableAdaptiveBandwidth;
@property (nonatomic, assign) double currentBandwidth; // MB/s
@property (nonatomic, assign) double targetUtilization; // 0.0 - 1.0

- (void)optimizeForNetwork:(NSString *)networkType; // WiFi, Ethernet, etc
- (void)measureBandwidthToHost:(NSString *)host port:(NSInteger)port completion:(void(^)(double bandwidth))completion;
- (NSUInteger)optimalChunkSizeForBandwidth:(double)bandwidth;
- (void)adjustTransferParameters;
- (NSDictionary *)networkStatistics;

@end

#pragma mark - Backup Statistics

@interface OsiriXBackupStatistics : NSObject

@property (nonatomic, readonly) NSUInteger totalStudiesProcessed;
@property (nonatomic, readonly) NSUInteger totalImagesTransferred;
@property (nonatomic, readonly) NSUInteger totalBytesTransferred;
@property (nonatomic, readonly) NSUInteger failedTransfers;
@property (nonatomic, readonly) NSUInteger successfulTransfers;
@property (nonatomic, readonly) NSTimeInterval totalTransferTime;
@property (nonatomic, readonly) double averageTransferSpeed;
@property (nonatomic, readonly) NSDate *lastBackupDate;
@property (nonatomic, readonly) NSDate *firstBackupDate;

- (void)recordTransfer:(OsiriXTransferQueueItem *)item;
- (void)recordFailure:(OsiriXTransferQueueItem *)item error:(NSError *)error;
- (NSDictionary *)generateReport;
- (void)exportToCSV:(NSString *)filePath;
- (void)exportToJSON:(NSString *)filePath;
- (void)reset;

@end

#pragma mark - Destination Manager

@interface OsiriXBackupDestination : NSObject

@property (nonatomic, strong) NSString *destinationID;
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *hostAddress;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, strong) NSString *aeTitle;
@property (nonatomic, strong) NSString *destinationAET;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) OsiriXCompressionType compression;
@property (nonatomic, assign) NSUInteger maxConcurrentTransfers;
@property (nonatomic, strong) NSString *tlsCertificate;
@property (nonatomic, assign) BOOL requiresAuthentication;
@property (nonatomic, strong) NSDictionary *authenticationCredentials;
@property (nonatomic, readonly) BOOL isReachable;
@property (nonatomic, readonly) double latency; // ms

- (void)testConnection:(void(^)(BOOL success, NSError *error))completion;
- (void)measureLatency:(void(^)(double latency))completion;

@end

@interface OsiriXDestinationManager : NSObject

@property (nonatomic, strong, readonly) NSMutableArray<OsiriXBackupDestination *> *destinations;
@property (nonatomic, strong) OsiriXBackupDestination *primaryDestination;

+ (instancetype)sharedManager;
- (void)addDestination:(OsiriXBackupDestination *)destination;
- (void)removeDestination:(OsiriXBackupDestination *)destination;
- (OsiriXBackupDestination *)destinationWithID:(NSString *)destinationID;
- (NSArray<OsiriXBackupDestination *> *)activeDestinations;
- (OsiriXBackupDestination *)selectOptimalDestination;
- (void)loadDestinationsFromConfig;
- (void)saveDestinationsToConfig;

@end

#pragma mark - Report Generator

@interface OsiriXBackupReportGenerator : NSObject

+ (NSString *)generateHTMLReport:(OsiriXBackupStatistics *)statistics;
+ (NSString *)generateTextReport:(OsiriXBackupStatistics *)statistics;
+ (NSData *)generatePDFReport:(OsiriXBackupStatistics *)statistics;
+ (void)emailReport:(NSString *)report toRecipients:(NSArray<NSString *> *)recipients;
+ (void)saveReportToFile:(NSString *)report path:(NSString *)path;

@end

#pragma mark - Error Recovery

@interface OsiriXErrorRecoveryManager : NSObject

@property (nonatomic, assign) NSUInteger maxRetries;
@property (nonatomic, assign) NSTimeInterval baseRetryInterval;
@property (nonatomic, assign) double backoffMultiplier;
@property (nonatomic, assign) BOOL enableAutoRecovery;

+ (instancetype)sharedManager;
- (NSTimeInterval)nextRetryIntervalForAttempt:(NSUInteger)attempt;
- (BOOL)shouldRetryError:(NSError *)error;
- (void)handleError:(NSError *)error forItem:(OsiriXTransferQueueItem *)item;
- (NSArray<NSString *> *)recoverableErrorCodes;
- (void)registerRecoveryStrategy:(void(^)(NSError *error))strategy forErrorCode:(NSInteger)code;

@end

#endif