//
//  OsiriXBackupAdvanced.h
//  Advanced Backup Features and Intelligent Algorithms
//

#import <Foundation/Foundation.h>
#import "OsiriXBackupCore.h"

@class DicomStudy;
@class DicomSeries;

#pragma mark - Incremental Backup Manager

@interface OsiriXIncrementalBackupManager : NSObject

@property (nonatomic, strong, readonly) NSMutableDictionary *backupHistory;
@property (nonatomic, strong, readonly) NSMutableDictionary *studySnapshots;
@property (nonatomic, assign) OsiriXBackupType currentBackupType;

- (NSArray<DicomStudy *> *)studiesForIncrementalBackup:(NSArray<DicomStudy *> *)allStudies 
                                              sinceDate:(NSDate *)lastBackupDate;
- (NSArray<DicomStudy *> *)studiesForDifferentialBackup:(NSArray<DicomStudy *> *)allStudies 
                                      sinceFullBackupDate:(NSDate *)fullBackupDate;
- (void)recordBackupSnapshot:(NSArray<DicomStudy *> *)studies 
                         type:(OsiriXBackupType)type
                         date:(NSDate *)date;
- (NSDate *)lastFullBackupDate;
- (NSDate *)lastIncrementalBackupDate;
- (BOOL)studyNeedsBackup:(DicomStudy *)study;
- (void)createBackupManifest:(NSString *)filePath forStudies:(NSArray<DicomStudy *> *)studies;
- (NSArray<DicomStudy *> *)deltaStudies:(NSArray<DicomStudy *> *)currentStudies 
                            fromSnapshot:(NSDictionary *)snapshot;

@end

#pragma mark - Multi-Destination Manager

@interface OsiriXMultiDestinationManager : NSObject

@property (nonatomic, strong, readonly) NSMutableArray<OsiriXBackupDestination *> *destinations;
@property (nonatomic, assign) BOOL enableLoadBalancing;
@property (nonatomic, assign) BOOL enableFailover;
@property (nonatomic, assign) BOOL enableMirroring;

- (void)configureDestination:(OsiriXBackupDestination *)destination 
                    forStudy:(DicomStudy *)study;
- (NSArray<OsiriXBackupDestination *> *)selectDestinationsForStudy:(DicomStudy *)study;
- (OsiriXBackupDestination *)primaryDestinationForModality:(NSString *)modality;
- (void)balanceLoadAcrossDestinations;
- (BOOL)failoverToBackupDestination:(OsiriXBackupDestination *)failed;
- (void)mirrorStudyToAllDestinations:(DicomStudy *)study;
- (NSDictionary *)destinationLoadStatistics;

@end

#pragma mark - Real-Time Monitor

@interface OsiriXRealtimeMonitor : NSObject

@property (nonatomic, strong, readonly) NSMutableDictionary *activeTransfers;
@property (nonatomic, strong, readonly) NSMutableArray *performanceMetrics;
@property (nonatomic, assign) NSTimeInterval updateInterval;
@property (nonatomic, copy) void(^statusUpdateHandler)(NSDictionary *status);
@property (nonatomic, copy) void(^alertHandler)(NSString *alert);

- (void)startMonitoring;
- (void)stopMonitoring;
- (void)trackTransfer:(OsiriXTransferQueueItem *)item;
- (void)updateTransferProgress:(NSString *)studyUID 
                       progress:(double)progress 
                         speed:(double)speed;
- (NSDictionary *)currentSystemStatus;
- (NSArray *)recentAlerts;
- (void)generatePerformanceReport;
- (void)exportMetricsToFile:(NSString *)path;

@end

#pragma mark - Smart Scheduler

@interface OsiriXSmartScheduler : NSObject

@property (nonatomic, strong, readonly) NSMutableArray<OsiriXBackupSchedule *> *schedules;
@property (nonatomic, assign) BOOL enableSmartScheduling;
@property (nonatomic, assign) BOOL enablePredictiveScheduling;

- (void)analyzeBackupPatterns;
- (NSDate *)optimalBackupTimeForStudy:(DicomStudy *)study;
- (void)createSmartScheduleBasedOnUsagePatterns;
- (void)adjustScheduleForNetworkConditions;
- (void)predictNextBackupWindow;
- (void)pauseSchedulesDuringPeakHours;
- (NSArray<NSDate *> *)suggestedBackupTimesForNext:(NSInteger)days;

@end

#pragma mark - AI-Powered Study Classifier

@interface OsiriXStudyClassifier : NSObject

@property (nonatomic, assign) BOOL enableMachineLearning;
@property (nonatomic, strong, readonly) NSMutableDictionary *classificationRules;

- (OsiriXTransferPriority)classifyStudyPriority:(DicomStudy *)study;
- (BOOL)isStudyCritical:(DicomStudy *)study;
- (NSString *)predictStudyImportance:(DicomStudy *)study;
- (void)trainClassifierWithHistoricalData:(NSArray<DicomStudy *> *)studies;
- (void)updateClassificationRules;
- (NSDictionary *)classificationStatistics;

@end

#pragma mark - Bandwidth Manager

@interface OsiriXBandwidthManager : NSObject

@property (nonatomic, assign) double maxBandwidthMBps;
@property (nonatomic, assign) double currentUtilization;
@property (nonatomic, assign) BOOL enableQoS;
@property (nonatomic, assign) BOOL enableThrottling;

- (void)allocateBandwidthForTransfer:(OsiriXTransferQueueItem *)item;
- (void)throttleTransfer:(NSString *)studyUID toSpeed:(double)speedMBps;
- (void)prioritizeUrgentTransfers;
- (double)availableBandwidth;
- (void)enforceQoSPolicy;
- (NSDictionary *)bandwidthStatistics;

@end

#pragma mark - Compression Engine

@interface OsiriXCompressionEngine : NSObject

@property (nonatomic, assign) OsiriXCompressionType preferredCompression;
@property (nonatomic, assign) BOOL enableAdaptiveCompression;
@property (nonatomic, assign) double compressionQuality; // 0.0 - 1.0

- (NSData *)compressData:(NSData *)data withType:(OsiriXCompressionType)type;
- (NSData *)decompressData:(NSData *)data fromType:(OsiriXCompressionType)type;
- (OsiriXCompressionType)optimalCompressionForModality:(NSString *)modality;
- (double)estimateCompressionRatio:(NSData *)data forType:(OsiriXCompressionType)type;
- (BOOL)shouldCompressFile:(NSString *)filePath;
- (NSDictionary *)compressionStatistics;

@end

#pragma mark - Deduplication Engine

@interface OsiriXDeduplicationEngine : NSObject

@property (nonatomic, strong, readonly) NSMutableDictionary *fingerprintDatabase;
@property (nonatomic, assign) BOOL enableBlockLevelDedup;
@property (nonatomic, assign) NSUInteger blockSize;

- (NSString *)generateFingerprint:(NSData *)data;
- (BOOL)isDuplicate:(NSString *)filePath;
- (NSArray<NSString *> *)findDuplicates:(NSArray<NSString *> *)filePaths;
- (NSUInteger)deduplicateStudy:(DicomStudy *)study;
- (double)calculateDeduplicationRatio;
- (void)rebuildFingerprintDatabase;
- (NSDictionary *)deduplicationStatistics;

@end

#pragma mark - Disaster Recovery

@interface OsiriXDisasterRecovery : NSObject

@property (nonatomic, strong, readonly) NSMutableArray *recoveryPoints;
@property (nonatomic, assign) NSUInteger maxRecoveryPoints;
@property (nonatomic, assign) BOOL enableContinuousDataProtection;

- (void)createRecoveryPoint:(NSString *)name;
- (void)restoreFromRecoveryPoint:(NSString *)pointID;
- (NSArray *)listRecoveryPoints;
- (void)validateRecoveryPoint:(NSString *)pointID;
- (void)scheduleAutomaticRecoveryPoints;
- (NSDictionary *)disasterRecoveryStatus;

@end

#pragma mark - Audit Logger

@interface OsiriXAuditLogger : NSObject

@property (nonatomic, strong, readonly) NSMutableArray *auditLog;
@property (nonatomic, assign) BOOL enableDetailedLogging;
@property (nonatomic, strong) NSString *logFilePath;

- (void)logBackupEvent:(NSString *)event 
               forStudy:(NSString *)studyUID 
               withInfo:(NSDictionary *)info;
- (void)logSecurityEvent:(NSString *)event 
                    user:(NSString *)user;
- (void)logError:(NSError *)error 
         context:(NSString *)context;
- (NSArray *)searchLogsWithPredicate:(NSPredicate *)predicate;
- (void)exportAuditLog:(NSString *)format toPath:(NSString *)path;
- (void)rotateLogFiles;

@end

#pragma mark - Cloud Integration

@interface OsiriXCloudIntegration : NSObject

@property (nonatomic, strong) NSString *cloudProvider; // AWS, Azure, Google Cloud
@property (nonatomic, strong) NSDictionary *credentials;
@property (nonatomic, assign) BOOL enableCloudBackup;
@property (nonatomic, assign) BOOL enableHybridCloud;

- (void)configureCloudStorage:(NSDictionary *)config;
- (void)uploadStudyToCloud:(DicomStudy *)study 
                completion:(void(^)(BOOL success, NSError *error))completion;
- (void)downloadStudyFromCloud:(NSString *)studyUID 
                    completion:(void(^)(DicomStudy *study, NSError *error))completion;
- (void)syncWithCloud;
- (NSArray *)listCloudStudies;
- (NSDictionary *)cloudStorageStatistics;

@end

#pragma mark - Performance Analyzer

@interface OsiriXPerformanceAnalyzer : NSObject

@property (nonatomic, strong, readonly) NSMutableArray *performanceData;
@property (nonatomic, assign) BOOL enableProfiling;

- (void)startProfiling;
- (void)stopProfiling;
- (void)measureOperationTime:(NSString *)operation block:(void(^)(void))block;
- (NSDictionary *)analyzeBottlenecks;
- (NSArray *)performanceRecommendations;
- (void)optimizeBasedOnAnalysis;
- (NSDictionary *)generatePerformanceReport;

@end

#pragma mark - Notification Manager

@interface OsiriXNotificationManager : NSObject

@property (nonatomic, assign) BOOL enableEmailNotifications;
@property (nonatomic, assign) BOOL enablePushNotifications;
@property (nonatomic, assign) BOOL enableSMSNotifications;
@property (nonatomic, strong) NSArray<NSString *> *emailRecipients;

- (void)sendNotification:(NSString *)message 
                    type:(NSString *)type 
                priority:(NSInteger)priority;
- (void)sendBackupCompleteNotification:(NSDictionary *)summary;
- (void)sendFailureAlert:(NSError *)error forStudy:(NSString *)studyName;
- (void)configureNotificationPreferences:(NSDictionary *)preferences;
- (void)testNotificationChannels;

@end

#pragma mark - Data Encryption

@interface OsiriXDataEncryption : NSObject

@property (nonatomic, assign) BOOL enableEncryption;
@property (nonatomic, strong) NSString *encryptionAlgorithm; // AES256, RSA
@property (nonatomic, strong) NSData *encryptionKey;

- (NSData *)encryptData:(NSData *)data;
- (NSData *)decryptData:(NSData *)encryptedData;
- (void)generateEncryptionKey;
- (void)rotateEncryptionKeys;
- (BOOL)validateEncryptedData:(NSData *)data;
- (NSDictionary *)encryptionStatus;

@end