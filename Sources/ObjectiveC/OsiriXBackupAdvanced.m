//
//  OsiriXBackupAdvanced.m
//  Advanced Backup Features Implementation
//

#import "OsiriXBackupAdvanced.h"
#import "OsiriXBackupCore.h"
#import "OsiriXTestPlugin-Swift.h"
#import <OsiriXAPI/DicomStudy.h>
#import <OsiriXAPI/DicomSeries.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonCryptor.h>
#import <zlib.h>

#pragma mark - Incremental Backup Manager

@implementation OsiriXIncrementalBackupManager

- (instancetype)init {
    if (self = [super init]) {
        _backupHistory = [[NSMutableDictionary alloc] init];
        _studySnapshots = [[NSMutableDictionary alloc] init];
        _currentBackupType = OsiriXBackupTypeFull;
        [self loadBackupHistory];
    }
    return self;
}

- (NSArray<DicomStudy *> *)studiesForIncrementalBackup:(NSArray<DicomStudy *> *)allStudies 
                                              sinceDate:(NSDate *)lastBackupDate {
    if (!lastBackupDate) {
        return allStudies; // First backup, return all
    }
    
    NSMutableArray *incrementalStudies = [NSMutableArray array];
    
    for (DicomStudy *study in allStudies) {
        NSDate *studyDate = [study valueForKey:@"dateAdded"];
        if (!studyDate) studyDate = [study valueForKey:@"date"];
        
        if ([studyDate compare:lastBackupDate] == NSOrderedDescending) {
            [incrementalStudies addObject:study];
        } else {
            // Check if study was modified
            NSString *studyUID = [study valueForKey:@"studyInstanceUID"];
            NSString *lastHash = _studySnapshots[studyUID][@"hash"];
            NSString *currentHash = [OsiriXIntegrityValidator sha256HashForStudy:study];
            
            if (!lastHash || ![lastHash isEqualToString:currentHash]) {
                [incrementalStudies addObject:study];
            }
        }
    }
    
    NSLog(@"[IncrementalBackup] Found %lu studies for incremental backup", 
          (unsigned long)incrementalStudies.count);
    return incrementalStudies;
}

- (NSArray<DicomStudy *> *)studiesForDifferentialBackup:(NSArray<DicomStudy *> *)allStudies 
                                      sinceFullBackupDate:(NSDate *)fullBackupDate {
    if (!fullBackupDate) {
        return allStudies;
    }
    
    NSMutableArray *differentialStudies = [NSMutableArray array];
    NSDictionary *fullBackupSnapshot = _backupHistory[@"lastFullBackup"];
    
    for (DicomStudy *study in allStudies) {
        NSString *studyUID = [study valueForKey:@"studyInstanceUID"];
        NSDate *studyDate = [study valueForKey:@"dateAdded"];
        
        if ([studyDate compare:fullBackupDate] == NSOrderedDescending) {
            [differentialStudies addObject:study];
        } else if (!fullBackupSnapshot[studyUID]) {
            [differentialStudies addObject:study];
        }
    }
    
    return differentialStudies;
}

- (void)recordBackupSnapshot:(NSArray<DicomStudy *> *)studies 
                         type:(OsiriXBackupType)type
                         date:(NSDate *)date {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    
    for (DicomStudy *study in studies) {
        NSString *studyUID = [study valueForKey:@"studyInstanceUID"];
        NSString *hash = [OsiriXIntegrityValidator sha256HashForStudy:study];
        
        snapshot[studyUID] = @{
            @"hash": hash,
            @"date": date,
            @"name": [study valueForKey:@"name"] ?: @"",
            @"imageCount": @([self imageCountForStudy:study])
        };
        
        _studySnapshots[studyUID] = snapshot[studyUID];
    }
    
    NSString *backupKey = (type == OsiriXBackupTypeFull) ? @"lastFullBackup" : @"lastIncrementalBackup";
    _backupHistory[backupKey] = @{
        @"date": date,
        @"snapshot": snapshot,
        @"studyCount": @(studies.count)
    };
    
    [self saveBackupHistory];
}

- (NSUInteger)imageCountForStudy:(DicomStudy *)study {
    NSUInteger count = 0;
    for (DicomSeries *series in [study valueForKey:@"series"]) {
        count += [[series valueForKey:@"images"] count];
    }
    return count;
}

- (NSDate *)lastFullBackupDate {
    return _backupHistory[@"lastFullBackup"][@"date"];
}

- (NSDate *)lastIncrementalBackupDate {
    return _backupHistory[@"lastIncrementalBackup"][@"date"];
}

- (BOOL)studyNeedsBackup:(DicomStudy *)study {
    NSString *studyUID = [study valueForKey:@"studyInstanceUID"];
    NSDictionary *snapshot = _studySnapshots[studyUID];
    
    if (!snapshot) return YES;
    
    NSString *lastHash = snapshot[@"hash"];
    NSString *currentHash = [OsiriXIntegrityValidator sha256HashForStudy:study];
    
    return ![lastHash isEqualToString:currentHash];
}

- (void)createBackupManifest:(NSString *)filePath forStudies:(NSArray<DicomStudy *> *)studies {
    NSMutableDictionary *manifest = [NSMutableDictionary dictionary];
    
    manifest[@"backupDate"] = [NSDate date];
    manifest[@"backupType"] = @(_currentBackupType);
    manifest[@"studyCount"] = @(studies.count);
    
    NSMutableArray *studyManifests = [NSMutableArray array];
    for (DicomStudy *study in studies) {
        NSDictionary *studyManifest = [OsiriXIntegrityValidator generateStudyManifest:study];
        [studyManifests addObject:studyManifest];
    }
    manifest[@"studies"] = studyManifests;
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:manifest 
                                                       options:NSJSONWritingPrettyPrinted 
                                                         error:nil];
    [jsonData writeToFile:filePath atomically:YES];
}

- (NSArray<DicomStudy *> *)deltaStudies:(NSArray<DicomStudy *> *)currentStudies 
                            fromSnapshot:(NSDictionary *)snapshot {
    NSMutableArray *deltaStudies = [NSMutableArray array];
    
    for (DicomStudy *study in currentStudies) {
        NSString *studyUID = [study valueForKey:@"studyInstanceUID"];
        NSDictionary *snapshotEntry = snapshot[studyUID];
        
        if (!snapshotEntry || [self studyNeedsBackup:study]) {
            [deltaStudies addObject:study];
        }
    }
    
    return deltaStudies;
}

- (void)saveBackupHistory {
    NSString *path = [self backupHistoryPath];
    [NSKeyedArchiver archiveRootObject:_backupHistory toFile:path];
}

- (void)loadBackupHistory {
    NSString *path = [self backupHistoryPath];
    NSDictionary *history = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    if (history) {
        _backupHistory = [history mutableCopy];
    }
}

- (NSString *)backupHistoryPath {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, 
                                                                NSUserDomainMask, YES) firstObject];
    NSString *dir = [appSupport stringByAppendingPathComponent:@"OsiriXBackup"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:nil];
    return [dir stringByAppendingPathComponent:@"backup_history.plist"];
}

@end

#pragma mark - Multi-Destination Manager

@implementation OsiriXMultiDestinationManager {
    OsiriXBackupDestination *_primaryDestination;
}

- (instancetype)init {
    if (self = [super init]) {
        _destinations = [[NSMutableArray alloc] init];
        _enableLoadBalancing = YES;
        _enableFailover = YES;
        _enableMirroring = NO;
        _primaryDestination = nil;
    }
    return self;
}

- (OsiriXBackupDestination *)primaryDestination {
    return _primaryDestination;
}

- (void)setPrimaryDestination:(OsiriXBackupDestination *)primaryDestination {
    _primaryDestination = primaryDestination;
}

- (void)configureDestination:(OsiriXBackupDestination *)destination 
                    forStudy:(DicomStudy *)study {
    NSString *modality = [[study valueForKey:@"series"] firstObject] ? 
                         [[[study valueForKey:@"series"] firstObject] valueForKey:@"modality"] : @"";
    
    // Configure compression based on modality
    if ([modality isEqualToString:@"CT"] || [modality isEqualToString:@"MR"]) {
        destination.compression = OsiriXCompressionJPEG2000Lossless;
        destination.maxConcurrentTransfers = 2;
    } else if ([modality isEqualToString:@"US"] || [modality isEqualToString:@"XA"]) {
        destination.compression = OsiriXCompressionNone;
        destination.maxConcurrentTransfers = 4;
    } else {
        destination.compression = OsiriXCompressionGZIP;
        destination.maxConcurrentTransfers = 3;
    }
}

- (NSArray<OsiriXBackupDestination *> *)selectDestinationsForStudy:(DicomStudy *)study {
    if (_enableMirroring) {
        return [self activeDestinations];
    }
    
    if (_enableLoadBalancing) {
        return @[[self selectOptimalDestination]];
    }
    
    // Default to primary
    return _primaryDestination ? @[_primaryDestination] : @[];
}

- (OsiriXBackupDestination *)selectOptimalDestination {
    OsiriXBackupDestination *optimal = nil;
    double minLoad = DBL_MAX;
    
    for (OsiriXBackupDestination *dest in [self activeDestinations]) {
        if (!dest.isReachable) continue;
        
        // Simple load metric: latency * active transfers
        double load = dest.latency * dest.maxConcurrentTransfers;
        if (load < minLoad) {
            minLoad = load;
            optimal = dest;
        }
    }
    
    return optimal ?: _primaryDestination;
}

- (NSArray<OsiriXBackupDestination *> *)activeDestinations {
    NSMutableArray *active = [NSMutableArray array];
    for (OsiriXBackupDestination *dest in _destinations) {
        if (dest.enabled && dest.isReachable) {
            [active addObject:dest];
        }
    }
    return active;
}

- (OsiriXBackupDestination *)primaryDestinationForModality:(NSString *)modality {
    // Could have modality-specific routing rules
    for (OsiriXBackupDestination *dest in _destinations) {
        NSDictionary *rules = dest.authenticationCredentials[@"modalityRules"];
        if (rules && rules[modality]) {
            return dest;
        }
    }
    return _primaryDestination;
}

- (void)balanceLoadAcrossDestinations {
    if (!_enableLoadBalancing) return;
    
    NSArray *active = [self activeDestinations];
    if (active.count < 2) return;
    
    // Sort by current load
    NSArray *sorted = [active sortedArrayUsingComparator:^NSComparisonResult(OsiriXBackupDestination *d1, 
                                                                             OsiriXBackupDestination *d2) {
        double load1 = d1.latency * d1.maxConcurrentTransfers;
        double load2 = d2.latency * d2.maxConcurrentTransfers;
        return [@(load1) compare:@(load2)];
    }];
    
    // Update primary to least loaded
    _primaryDestination = sorted.firstObject;
}

- (BOOL)failoverToBackupDestination:(OsiriXBackupDestination *)failed {
    if (!_enableFailover) return NO;
    
    failed.enabled = NO;
    NSLog(@"[MultiDestination] Failing over from %@", failed.name);
    
    for (OsiriXBackupDestination *dest in _destinations) {
        if (dest != failed && dest.enabled && dest.isReachable) {
            _primaryDestination = dest;
            NSLog(@"[MultiDestination] Failed over to %@", dest.name);
            return YES;
        }
    }
    
    NSLog(@"[MultiDestination] No backup destination available");
    return NO;
}

- (void)mirrorStudyToAllDestinations:(DicomStudy *)study {
    if (!_enableMirroring) return;
    
    NSArray *destinations = [self activeDestinations];
    NSLog(@"[MultiDestination] Mirroring study to %lu destinations", (unsigned long)destinations.count);
    
    for (OsiriXBackupDestination *dest in destinations) {
        // Queue transfer to each destination
        // Implementation would use transfer queue
    }
}

- (NSDictionary *)destinationLoadStatistics {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    for (OsiriXBackupDestination *dest in _destinations) {
        stats[dest.name] = @{
            @"enabled": @(dest.enabled),
            @"reachable": @(dest.isReachable),
            @"latency": @(dest.latency),
            @"compression": @(dest.compression),
            @"maxTransfers": @(dest.maxConcurrentTransfers)
        };
    }
    
    return stats;
}

@end

#pragma mark - Realtime Monitor

@implementation OsiriXRealtimeMonitor {
    NSTimer *_monitorTimer;
    NSMutableArray *_recentAlerts;
}

- (instancetype)init {
    if (self = [super init]) {
        _activeTransfers = [[NSMutableDictionary alloc] init];
        _performanceMetrics = [[NSMutableArray alloc] init];
        _recentAlerts = [[NSMutableArray alloc] init];
        _updateInterval = 1.0;
    }
    return self;
}

- (void)dealloc {
    [self stopMonitoring];
}

- (void)startMonitoring {
    [self stopMonitoring]; // Stop any existing timer
    
    _monitorTimer = [NSTimer scheduledTimerWithTimeInterval:_updateInterval
                                                      target:self
                                                    selector:@selector(updateMonitoringStatus)
                                                    userInfo:nil
                                                     repeats:YES];
    
    NSLog(@"[RealtimeMonitor] Started monitoring with %.1fs interval", _updateInterval);
}

- (void)stopMonitoring {
    [_monitorTimer invalidate];
    _monitorTimer = nil;
    NSLog(@"[RealtimeMonitor] Stopped monitoring");
}

- (void)updateMonitoringStatus {
    NSDictionary *status = [self currentSystemStatus];
    
    if (_statusUpdateHandler) {
        _statusUpdateHandler(status);
    }
    
    // Record metrics
    [_performanceMetrics addObject:@{
        @"timestamp": [NSDate date],
        @"status": status
    }];
    
    // Keep only last 1000 metrics
    if (_performanceMetrics.count > 1000) {
        [_performanceMetrics removeObjectsInRange:NSMakeRange(0, _performanceMetrics.count - 1000)];
    }
    
    // Check for alerts
    [self checkForAlerts:status];
}

- (void)trackTransfer:(OsiriXTransferQueueItem *)item {
    @synchronized (_activeTransfers) {
        _activeTransfers[item.studyUID] = item;
    }
}

- (void)updateTransferProgress:(NSString *)studyUID 
                       progress:(double)progress 
                         speed:(double)speed {
    @synchronized (_activeTransfers) {
        OsiriXTransferQueueItem *item = _activeTransfers[studyUID];
        if (item) {
            item.transferSpeed = speed;
            // Update progress
            NSUInteger transferred = (NSUInteger)(item.totalImages * progress / 100.0);
            item.transferredImages = transferred;
        }
    }
}

- (NSDictionary *)currentSystemStatus {
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    
    @synchronized (_activeTransfers) {
        NSUInteger activeCount = 0;
        double totalSpeed = 0;
        double totalProgress = 0;
        
        for (OsiriXTransferQueueItem *item in _activeTransfers.allValues) {
            if (item.status == OsiriXTransferStatusInProgress) {
                activeCount++;
                totalSpeed += item.transferSpeed;
                totalProgress += item.progressPercentage;
            }
        }
        
        status[@"activeTransfers"] = @(activeCount);
        status[@"totalSpeed"] = @(totalSpeed);
        status[@"averageProgress"] = @(activeCount > 0 ? totalProgress/activeCount : 0);
        status[@"currentSpeed"] = @(totalSpeed);
    }
    
    // System metrics
    status[@"cpuUsage"] = @([self getCPUUsage]);
    status[@"memoryUsage"] = @([self getMemoryUsage]);
    status[@"diskSpace"] = @([self getAvailableDiskSpace]);
    
    return status;
}

- (double)getCPUUsage {
    // Simplified - would use host_processor_info
    return 25.0; // Mock value
}

- (double)getMemoryUsage {
    // Simplified - would use host_statistics64
    return 45.0; // Mock value
}

- (NSUInteger)getAvailableDiskSpace {
    NSError *error = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] 
                                attributesOfFileSystemForPath:NSHomeDirectory() 
                                                        error:&error];
    return [attributes[NSFileSystemFreeSize] unsignedIntegerValue];
}

- (void)checkForAlerts:(NSDictionary *)status {
    // Check for high CPU
    if ([status[@"cpuUsage"] doubleValue] > 80.0) {
        [self triggerAlert:@"High CPU usage detected"];
    }
    
    // Check for low disk space
    NSUInteger diskSpace = [status[@"diskSpace"] unsignedIntegerValue];
    if (diskSpace < 1024 * 1024 * 1024) { // Less than 1GB
        [self triggerAlert:@"Low disk space warning"];
    }
    
    // Check for stalled transfers
    double avgProgress = [status[@"averageProgress"] doubleValue];
    static double lastProgress = 0;
    if (avgProgress > 0 && avgProgress == lastProgress) {
        [self triggerAlert:@"Transfer may be stalled"];
    }
    lastProgress = avgProgress;
}

- (void)triggerAlert:(NSString *)alert {
    NSLog(@"[RealtimeMonitor] ALERT: %@", alert);
    
    if (_alertHandler) {
        _alertHandler(alert);
    }
    
    // Store alert
    if (!_recentAlerts) {
        _recentAlerts = [[NSMutableArray alloc] init];
    }
    [_recentAlerts addObject:@{
        @"timestamp": [NSDate date],
        @"message": alert
    }];
}

- (NSArray *)recentAlerts {
    return _recentAlerts ?: @[];
}

- (void)generatePerformanceReport {
    NSMutableString *report = [NSMutableString string];
    
    [report appendString:@"=== PERFORMANCE REPORT ===\n"];
    [report appendFormat:@"Monitoring Duration: %.1f minutes\n", 
            _performanceMetrics.count * _updateInterval / 60.0];
    
    // Calculate averages
    double avgSpeed = 0;
    double maxSpeed = 0;
    NSUInteger totalTransfers = 0;
    
    for (NSDictionary *metric in _performanceMetrics) {
        double speed = [metric[@"status"][@"totalSpeed"] doubleValue];
        avgSpeed += speed;
        if (speed > maxSpeed) maxSpeed = speed;
        totalTransfers += [metric[@"status"][@"activeTransfers"] unsignedIntegerValue];
    }
    
    if (_performanceMetrics.count > 0) {
        avgSpeed /= _performanceMetrics.count;
    }
    
    [report appendFormat:@"Average Speed: %.2f MB/s\n", avgSpeed];
    [report appendFormat:@"Peak Speed: %.2f MB/s\n", maxSpeed];
    [report appendFormat:@"Total Transfers: %lu\n", (unsigned long)totalTransfers];
    
    NSLog(@"%@", report);
}

- (void)exportMetricsToFile:(NSString *)path {
    NSMutableString *csv = [NSMutableString string];
    [csv appendString:@"Timestamp,Active Transfers,Speed (MB/s),CPU (%),Memory (%),Disk (GB)\n"];
    
    for (NSDictionary *metric in _performanceMetrics) {
        NSDictionary *status = metric[@"status"];
        [csv appendFormat:@"%@,%@,%@,%@,%@,%.2f\n",
                metric[@"timestamp"],
                status[@"activeTransfers"],
                status[@"totalSpeed"],
                status[@"cpuUsage"],
                status[@"memoryUsage"],
                [status[@"diskSpace"] doubleValue] / 1024.0 / 1024.0 / 1024.0];
    }
    
    [csv writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@end

#pragma mark - Smart Scheduler

@implementation OsiriXSmartScheduler

- (instancetype)init {
    if (self = [super init]) {
        _schedules = [[NSMutableArray alloc] init];
        _enableSmartScheduling = YES;
        _enablePredictiveScheduling = YES;
    }
    return self;
}

- (void)analyzeBackupPatterns {
    // Analyze historical backup data to find patterns
    NSLog(@"[SmartScheduler] Analyzing backup patterns...");
    
    // This would analyze:
    // - Peak usage times
    // - Network availability windows
    // - Study creation patterns
    // - Success/failure rates by time
}

- (NSDate *)optimalBackupTimeForStudy:(DicomStudy *)study {
    if (!_enableSmartScheduling) {
        // Default to 2 AM
        NSDateComponents *components = [[NSDateComponents alloc] init];
        components.hour = 2;
        components.minute = 0;
        return [[NSCalendar currentCalendar] nextDateAfterDate:[NSDate date] 
                                                   matchingComponents:components 
                                                              options:NSCalendarMatchNextTime];
    }
    
    // Smart scheduling based on:
    // - Study size
    // - Network conditions
    // - Historical success rates
    
    NSString *modality = [[study valueForKey:@"series"] firstObject] ? 
                         [[[study valueForKey:@"series"] firstObject] valueForKey:@"modality"] : @"";
    
    NSInteger optimalHour = 2; // Default
    
    if ([modality isEqualToString:@"CT"] || [modality isEqualToString:@"MR"]) {
        // Large studies - schedule during low usage
        optimalHour = 3;
    } else if ([modality isEqualToString:@"CR"] || [modality isEqualToString:@"DX"]) {
        // Small studies - can schedule anytime
        optimalHour = 23;
    }
    
    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.hour = optimalHour;
    components.minute = 0;
    
    return [[NSCalendar currentCalendar] nextDateAfterDate:[NSDate date] 
                                               matchingComponents:components 
                                                          options:NSCalendarMatchNextTime];
}

- (void)createSmartScheduleBasedOnUsagePatterns {
    if (!_enablePredictiveScheduling) return;
    
    NSLog(@"[SmartScheduler] Creating smart schedule...");
    
    // Create incremental backups during low usage
    OsiriXBackupSchedule *incrementalSchedule = [[OsiriXBackupSchedule alloc] init];
    incrementalSchedule.name = @"Smart Incremental";
    incrementalSchedule.backupType = OsiriXBackupTypeIncremental;
    incrementalSchedule.cronExpression = @"0 3 * * *"; // 3 AM daily
    incrementalSchedule.enabled = YES;
    incrementalSchedule.maxStudiesPerRun = 50;
    [_schedules addObject:incrementalSchedule];
    
    // Create full backup on weekends
    OsiriXBackupSchedule *fullSchedule = [[OsiriXBackupSchedule alloc] init];
    fullSchedule.name = @"Smart Full";
    fullSchedule.backupType = OsiriXBackupTypeFull;
    fullSchedule.cronExpression = @"0 2 * * 0"; // 2 AM Sunday
    fullSchedule.enabled = YES;
    [_schedules addObject:fullSchedule];
}

- (void)adjustScheduleForNetworkConditions {
    // Monitor network and adjust schedules
    // Could pause during high network usage
    // Resume during low usage periods
}

- (void)predictNextBackupWindow {
    if (!_enablePredictiveScheduling) return;
    
    // Use ML/statistics to predict best backup window
    // Based on:
    // - Historical network availability
    // - Study creation patterns
    // - System usage patterns
}

- (void)pauseSchedulesDuringPeakHours {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:NSCalendarUnitHour fromDate:[NSDate date]];
    NSInteger hour = components.hour;
    
    // Peak hours: 8 AM - 6 PM
    BOOL isPeakHour = (hour >= 8 && hour <= 18);
    
    for (OsiriXBackupSchedule *schedule in _schedules) {
        if (isPeakHour && schedule.enabled) {
            NSLog(@"[SmartScheduler] Pausing schedule during peak hours: %@", schedule.name);
            schedule.enabled = NO;
        } else if (!isPeakHour && !schedule.enabled) {
            NSLog(@"[SmartScheduler] Resuming schedule after peak hours: %@", schedule.name);
            schedule.enabled = YES;
        }
    }
}

- (NSArray<NSDate *> *)suggestedBackupTimesForNext:(NSInteger)days {
    NSMutableArray *suggestions = [NSMutableArray array];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    
    for (NSInteger i = 0; i < days; i++) {
        NSDate *date = [[NSDate date] dateByAddingTimeInterval:i * 86400];
        
        // Suggest 2-4 AM for each day
        for (NSInteger hour = 2; hour <= 4; hour++) {
            NSDateComponents *components = [calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay 
                                                        fromDate:date];
            components.hour = hour;
            components.minute = 0;
            
            NSDate *suggestedTime = [calendar dateFromComponents:components];
            if ([suggestedTime compare:[NSDate date]] == NSOrderedDescending) {
                [suggestions addObject:suggestedTime];
            }
        }
    }
    
    return suggestions;
}

@end

#pragma mark - Study Classifier

@implementation OsiriXStudyClassifier

- (instancetype)init {
    if (self = [super init]) {
        _enableMachineLearning = YES;
        _classificationRules = [[NSMutableDictionary alloc] init];
        [self initializeDefaultRules];
    }
    return self;
}

- (void)initializeDefaultRules {
    // Emergency modalities
    _classificationRules[@"CT"] = @(OsiriXTransferPriorityHigh);
    _classificationRules[@"MR"] = @(OsiriXTransferPriorityHigh);
    
    // Urgent modalities
    _classificationRules[@"CR"] = @(OsiriXTransferPriorityNormal);
    _classificationRules[@"DX"] = @(OsiriXTransferPriorityNormal);
    _classificationRules[@"XA"] = @(OsiriXTransferPriorityUrgent);
    
    // Normal modalities
    _classificationRules[@"US"] = @(OsiriXTransferPriorityNormal);
    _classificationRules[@"MG"] = @(OsiriXTransferPriorityNormal);
    
    // Low priority
    _classificationRules[@"OT"] = @(OsiriXTransferPriorityLow);
    _classificationRules[@"SC"] = @(OsiriXTransferPriorityLow);
}

- (OsiriXTransferPriority)classifyStudyPriority:(DicomStudy *)study {
    NSString *modality = [[study valueForKey:@"series"] firstObject] ? 
                         [[[study valueForKey:@"series"] firstObject] valueForKey:@"modality"] : @"";
    
    // Check rules first
    NSNumber *rulePriority = _classificationRules[modality];
    if (rulePriority) {
        return [rulePriority integerValue];
    }
    
    if (!_enableMachineLearning) {
        return OsiriXTransferPriorityNormal;
    }
    
    // ML-based classification
    // Factors to consider:
    // - Study age
    // - Patient age
    // - Study description keywords
    // - Referring physician
    // - Institution priority
    
    NSDate *studyDate = [study valueForKey:@"date"];
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:studyDate];
    
    if (age < 3600) { // Less than 1 hour old
        return OsiriXTransferPriorityUrgent;
    } else if (age < 86400) { // Less than 1 day old
        return OsiriXTransferPriorityHigh;
    } else if (age < 604800) { // Less than 1 week old
        return OsiriXTransferPriorityNormal;
    }
    
    return OsiriXTransferPriorityLow;
}

- (BOOL)isStudyCritical:(DicomStudy *)study {
    NSString *description = [[study valueForKey:@"studyDescription"] lowercaseString];
    
    // Keywords indicating critical studies
    NSArray *criticalKeywords = @[@"emergency", @"urgent", @"stat", @"trauma", 
                                  @"stroke", @"hemorrhage", @"acute"];
    
    for (NSString *keyword in criticalKeywords) {
        if ([description containsString:keyword]) {
            return YES;
        }
    }
    
    return NO;
}

- (NSString *)predictStudyImportance:(DicomStudy *)study {
    if ([self isStudyCritical:study]) {
        return @"CRITICAL";
    }
    
    OsiriXTransferPriority priority = [self classifyStudyPriority:study];
    switch (priority) {
        case OsiriXTransferPriorityEmergency:
            return @"EMERGENCY";
        case OsiriXTransferPriorityUrgent:
            return @"URGENT";
        case OsiriXTransferPriorityHigh:
            return @"HIGH";
        case OsiriXTransferPriorityNormal:
            return @"NORMAL";
        case OsiriXTransferPriorityLow:
            return @"LOW";
    }
}

- (void)trainClassifierWithHistoricalData:(NSArray<DicomStudy *> *)studies {
    if (!_enableMachineLearning) return;
    
    NSLog(@"[StudyClassifier] Training with %lu studies", (unsigned long)studies.count);
    
    // Simplified training
    // Would use CoreML or CreateML for real implementation
    
    for (DicomStudy *study in studies) {
        // Extract features
        // Train model
        // Update rules
    }
}

- (void)updateClassificationRules {
    // Update rules based on training
}

- (NSDictionary *)classificationStatistics {
    return @{
        @"rulesCount": @(_classificationRules.count),
        @"mlEnabled": @(_enableMachineLearning)
    };
}

@end

#pragma mark - Compression Engine

@implementation OsiriXCompressionEngine

- (instancetype)init {
    if (self = [super init]) {
        _preferredCompression = OsiriXCompressionGZIP;
        _enableAdaptiveCompression = YES;
        _compressionQuality = 0.8;
    }
    return self;
}

- (NSData *)compressData:(NSData *)data withType:(OsiriXCompressionType)type {
    if (!data || type == OsiriXCompressionNone) return data;
    
    switch (type) {
        case OsiriXCompressionGZIP:
            return [self gzipCompress:data];
        case OsiriXCompressionZLIB:
            return [self zlibCompress:data];
        case OsiriXCompressionLZMA:
            return [self lzmaCompress:data];
        default:
            return data;
    }
}

- (NSData *)gzipCompress:(NSData *)data {
    if (!data.length) return nil;
    
    z_stream stream;
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;
    stream.avail_in = (uint)data.length;
    stream.next_in = (Bytef *)data.bytes;
    stream.total_out = 0;
    stream.avail_out = 0;
    
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return nil;
    }
    
    NSMutableData *compressed = [NSMutableData dataWithLength:16384];
    
    do {
        if (stream.total_out >= compressed.length) {
            [compressed increaseLengthBy:16384];
        }
        
        stream.next_out = compressed.mutableBytes + stream.total_out;
        stream.avail_out = (uint)(compressed.length - stream.total_out);
        deflate(&stream, Z_FINISH);
        
    } while (stream.avail_out == 0);
    
    deflateEnd(&stream);
    [compressed setLength:stream.total_out];
    
    return compressed;
}

- (NSData *)zlibCompress:(NSData *)data {
    // Similar to gzip but with different header
    return [self gzipCompress:data]; // Simplified
}

- (NSData *)lzmaCompress:(NSData *)data {
    // Would use lzma library
    return [self gzipCompress:data]; // Fallback to gzip
}

- (NSData *)decompressData:(NSData *)data fromType:(OsiriXCompressionType)type {
    // Implement decompression
    return data;
}

- (OsiriXCompressionType)optimalCompressionForModality:(NSString *)modality {
    if (!_enableAdaptiveCompression) {
        return _preferredCompression;
    }
    
    // Modality-specific optimization
    if ([modality isEqualToString:@"CT"] || [modality isEqualToString:@"MR"]) {
        return OsiriXCompressionJPEG2000Lossless;
    } else if ([modality isEqualToString:@"US"] || [modality isEqualToString:@"XA"]) {
        return OsiriXCompressionNone; // Already compressed
    } else {
        return OsiriXCompressionGZIP;
    }
}

- (double)estimateCompressionRatio:(NSData *)data forType:(OsiriXCompressionType)type {
    if (type == OsiriXCompressionNone) return 1.0;
    
    // Sample compression on small portion
    NSUInteger sampleSize = MIN(data.length, 10240);
    NSData *sample = [data subdataWithRange:NSMakeRange(0, sampleSize)];
    NSData *compressed = [self compressData:sample withType:type];
    
    return (double)compressed.length / (double)sample.length;
}

- (BOOL)shouldCompressFile:(NSString *)filePath {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    NSUInteger fileSize = [attributes[NSFileSize] unsignedIntegerValue];
    
    // Don't compress small files
    if (fileSize < 1024) return NO;
    
    // Check file extension
    NSString *extension = [filePath pathExtension].lowercaseString;
    NSSet *compressedFormats = [NSSet setWithObjects:@"jpg", @"jpeg", @"jp2", @"zip", @"gz", nil];
    
    return ![compressedFormats containsObject:extension];
}

- (NSDictionary *)compressionStatistics {
    return @{
        @"preferredType": @(_preferredCompression),
        @"adaptiveEnabled": @(_enableAdaptiveCompression),
        @"quality": @(_compressionQuality)
    };
}

@end

#pragma mark - Deduplication Engine

@implementation OsiriXDeduplicationEngine

- (instancetype)init {
    if (self = [super init]) {
        _fingerprintDatabase = [[NSMutableDictionary alloc] init];
        _enableBlockLevelDedup = YES;
        _blockSize = 4096;
        [self loadFingerprintDatabase];
    }
    return self;
}

- (void)dealloc {
    [self saveFingerprintDatabase];
}

- (NSString *)generateFingerprint:(NSData *)data {
    if (!data) return nil;
    
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    
    NSMutableString *fingerprint = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [fingerprint appendFormat:@"%02x", digest[i]];
    }
    
    return fingerprint;
}

- (BOOL)isDuplicate:(NSString *)filePath {
    NSData *fileData = [NSData dataWithContentsOfFile:filePath];
    if (!fileData) return NO;
    
    NSString *fingerprint = [self generateFingerprint:fileData];
    return _fingerprintDatabase[fingerprint] != nil;
}

- (NSArray<NSString *> *)findDuplicates:(NSArray<NSString *> *)filePaths {
    NSMutableArray *duplicates = [NSMutableArray array];
    
    for (NSString *path in filePaths) {
        if ([self isDuplicate:path]) {
            [duplicates addObject:path];
        }
    }
    
    return duplicates;
}

- (NSUInteger)deduplicateStudy:(DicomStudy *)study {
    NSUInteger deduplicatedCount = 0;
    
    for (DicomSeries *series in [study valueForKey:@"series"]) {
        for (id image in [series valueForKey:@"images"]) {
            NSString *path = [image valueForKey:@"completePath"];
            if (path && [self isDuplicate:path]) {
                deduplicatedCount++;
            } else if (path) {
                // Add to database
                NSData *data = [NSData dataWithContentsOfFile:path];
                NSString *fingerprint = [self generateFingerprint:data];
                _fingerprintDatabase[fingerprint] = path;
            }
        }
    }
    
    return deduplicatedCount;
}

- (double)calculateDeduplicationRatio {
    // Would need to track original vs deduplicated sizes
    return 1.0;
}

- (void)rebuildFingerprintDatabase {
    [_fingerprintDatabase removeAllObjects];
    
    // Rebuild from existing backups
    NSLog(@"[Deduplication] Rebuilding fingerprint database...");
}

- (NSDictionary *)deduplicationStatistics {
    return @{
        @"fingerprintCount": @(_fingerprintDatabase.count),
        @"blockLevelEnabled": @(_enableBlockLevelDedup),
        @"blockSize": @(_blockSize)
    };
}

- (void)saveFingerprintDatabase {
    NSString *path = [self fingerprintDatabasePath];
    [NSKeyedArchiver archiveRootObject:_fingerprintDatabase toFile:path];
}

- (void)loadFingerprintDatabase {
    NSString *path = [self fingerprintDatabasePath];
    NSDictionary *db = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    if (db) {
        _fingerprintDatabase = [db mutableCopy];
    }
}

- (NSString *)fingerprintDatabasePath {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, 
                                                                NSUserDomainMask, YES) firstObject];
    NSString *dir = [appSupport stringByAppendingPathComponent:@"OsiriXBackup"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:nil];
    return [dir stringByAppendingPathComponent:@"fingerprint_db.plist"];
}

@end

#pragma mark - Backup Schedule Implementation

@implementation OsiriXBackupSchedule

- (instancetype)init {
    if (self = [super init]) {
        _scheduleID = [[NSUUID UUID] UUIDString];
        _enabled = YES;
        _backupType = OsiriXBackupTypeFull;
        _maxStudiesPerRun = NSUIntegerMax;
    }
    return self;
}

- (BOOL)shouldRunNow {
    if (!_enabled) return NO;
    
    NSDate *now = [NSDate date];
    
    if (_nextRunDate && [now compare:_nextRunDate] == NSOrderedAscending) {
        return NO;
    }
    
    return YES;
}

- (NSDate *)calculateNextRunDate {
    // Parse cron expression and calculate next run
    // Simplified implementation
    
    if (!_cronExpression) return nil;
    
    // For now, just parse simple daily/weekly patterns
    if ([_cronExpression isEqualToString:@"0 2 * * *"]) {
        // Daily at 2 AM
        NSDateComponents *components = [[NSDateComponents alloc] init];
        components.hour = 2;
        components.minute = 0;
        
        return [[NSCalendar currentCalendar] nextDateAfterDate:[NSDate date] 
                                                   matchingComponents:components 
                                                              options:NSCalendarMatchNextTime];
    }
    
    return nil;
}

- (BOOL)matchesStudy:(DicomStudy *)study {
    if (!_studyFilter) return YES;
    
    return [_studyFilter evaluateWithObject:study];
}

@end

#pragma mark - Backup Scheduler Implementation

@implementation OsiriXBackupScheduler {
    NSTimer *_schedulerTimer;
}

+ (instancetype)sharedScheduler {
    static OsiriXBackupScheduler *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)dealloc {
    [self stopScheduler];
}

- (instancetype)init {
    if (self = [super init]) {
        _schedules = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)addSchedule:(OsiriXBackupSchedule *)schedule {
    [_schedules addObject:schedule];
    schedule.nextRunDate = [schedule calculateNextRunDate];
}

- (void)removeSchedule:(OsiriXBackupSchedule *)schedule {
    [_schedules removeObject:schedule];
}

- (void)enableSchedule:(NSString *)scheduleID {
    for (OsiriXBackupSchedule *schedule in _schedules) {
        if ([schedule.scheduleID isEqualToString:scheduleID]) {
            schedule.enabled = YES;
            break;
        }
    }
}

- (void)disableSchedule:(NSString *)scheduleID {
    for (OsiriXBackupSchedule *schedule in _schedules) {
        if ([schedule.scheduleID isEqualToString:scheduleID]) {
            schedule.enabled = NO;
            break;
        }
    }
}

- (void)startScheduler {
    [self stopScheduler];
    
    _schedulerTimer = [NSTimer scheduledTimerWithTimeInterval:60.0 // Check every minute
                                                        target:self
                                                      selector:@selector(checkSchedules)
                                                      userInfo:nil
                                                       repeats:YES];
    
    NSLog(@"[BackupScheduler] Started");
}

- (void)stopScheduler {
    [_schedulerTimer invalidate];
    _schedulerTimer = nil;
    NSLog(@"[BackupScheduler] Stopped");
}

- (void)checkSchedules {
    for (OsiriXBackupSchedule *schedule in [self activeSchedules]) {
        if ([schedule shouldRunNow]) {
            NSLog(@"[BackupScheduler] Running schedule: %@", schedule.name);
            [self executeSchedule:schedule];
            schedule.nextRunDate = [schedule calculateNextRunDate];
        }
    }
}

- (void)executeSchedule:(OsiriXBackupSchedule *)schedule {
    // Trigger backup based on schedule type
    [[NSNotificationCenter defaultCenter] postNotificationName:@"OsiriXBackupScheduleTriggered" 
                                                        object:schedule];
}

- (NSArray<OsiriXBackupSchedule *> *)activeSchedules {
    NSMutableArray *active = [NSMutableArray array];
    for (OsiriXBackupSchedule *schedule in _schedules) {
        if (schedule.enabled) {
            [active addObject:schedule];
        }
    }
    return active;
}

@end

#pragma mark - Backup Destination Implementation

@implementation OsiriXBackupDestination

- (instancetype)init {
    if (self = [super init]) {
        _destinationID = [[NSUUID UUID] UUIDString];
        _enabled = YES;
        _compression = OsiriXCompressionGZIP;
        _maxConcurrentTransfers = 3;
        _port = 104; // Default DICOM port
    }
    return self;
}

- (void)testConnection:(void(^)(BOOL success, NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Perform connection test
        // Would use C-ECHO or similar
        
        BOOL success = YES; // Mock
        NSError *error = nil;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, error);
        });
    });
}

- (void)measureLatency:(void(^)(double latency))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDate *start = [NSDate date];
        
        // Perform ping or C-ECHO
        [NSThread sleepForTimeInterval:0.05]; // Mock latency
        
        double latency = [[NSDate date] timeIntervalSinceDate:start] * 1000; // ms
        self->_latency = latency;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(latency);
        });
    });
}

- (BOOL)isReachable {
    // Would check network reachability
    return YES; // Mock
}

@end

#pragma mark - Destination Manager Implementation

@implementation OsiriXDestinationManager

+ (instancetype)sharedManager {
    static OsiriXDestinationManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        _destinations = [[NSMutableArray alloc] init];
        [self loadDestinationsFromConfig];
    }
    return self;
}

- (void)addDestination:(OsiriXBackupDestination *)destination {
    [_destinations addObject:destination];
    [self saveDestinationsToConfig];
}

- (void)removeDestination:(OsiriXBackupDestination *)destination {
    [_destinations removeObject:destination];
    [self saveDestinationsToConfig];
}

- (OsiriXBackupDestination *)destinationWithID:(NSString *)destinationID {
    for (OsiriXBackupDestination *dest in _destinations) {
        if ([dest.destinationID isEqualToString:destinationID]) {
            return dest;
        }
    }
    return nil;
}

- (NSArray<OsiriXBackupDestination *> *)activeDestinations {
    NSMutableArray *active = [NSMutableArray array];
    for (OsiriXBackupDestination *dest in _destinations) {
        if (dest.enabled && dest.isReachable) {
            [active addObject:dest];
        }
    }
    return active;
}

- (OsiriXBackupDestination *)selectOptimalDestination {
    OsiriXBackupDestination *optimal = nil;
    double minLatency = DBL_MAX;
    
    for (OsiriXBackupDestination *dest in [self activeDestinations]) {
        if (dest.latency < minLatency) {
            minLatency = dest.latency;
            optimal = dest;
        }
    }
    
    return optimal ?: _primaryDestination;
}

- (void)loadDestinationsFromConfig {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSData *data = [defaults objectForKey:@"OsiriXBackupDestinations"];
    if (data) {
        NSArray *destinations = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        if (destinations) {
            _destinations = [destinations mutableCopy];
        }
    }
}

- (void)saveDestinationsToConfig {
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:_destinations 
                                        requiringSecureCoding:NO 
                                                        error:nil];
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"OsiriXBackupDestinations"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end

#pragma mark - Report Generator Implementation

@implementation OsiriXBackupReportGenerator

+ (NSString *)generateHTMLReport:(OsiriXBackupStatistics *)statistics {
    NSDictionary *report = [statistics generateReport];
    
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html><html><head>"];
    [html appendString:@"<title>OsiriX Backup Report</title>"];
    [html appendString:@"<style>"];
    [html appendString:@"body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 20px; }"];
    [html appendString:@"h1 { color: #333; }"];
    [html appendString:@"table { border-collapse: collapse; width: 100%; margin: 20px 0; }"];
    [html appendString:@"th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }"];
    [html appendString:@"th { background-color: #f2f2f2; }"];
    [html appendString:@".success { color: green; }"];
    [html appendString:@".failure { color: red; }"];
    [html appendString:@"</style></head><body>"];
    
    [html appendString:@"<h1>OsiriX Backup Report</h1>"];
    
    // Summary section
    [html appendString:@"<h2>Summary</h2>"];
    [html appendString:@"<table>"];
    NSDictionary *summary = report[@"summary"];
    for (NSString *key in summary) {
        [html appendFormat:@"<tr><th>%@</th><td>%@</td></tr>", key, summary[key]];
    }
    [html appendString:@"</table>"];
    
    // Performance section
    [html appendString:@"<h2>Performance</h2>"];
    [html appendString:@"<table>"];
    NSDictionary *performance = report[@"performance"];
    for (NSString *key in performance) {
        [html appendFormat:@"<tr><th>%@</th><td>%@</td></tr>", key, performance[key]];
    }
    [html appendString:@"</table>"];
    
    [html appendString:@"</body></html>"];
    
    return html;
}

+ (NSString *)generateTextReport:(OsiriXBackupStatistics *)statistics {
    NSDictionary *report = [statistics generateReport];
    return [report description];
}

+ (NSData *)generatePDFReport:(OsiriXBackupStatistics *)statistics {
    // Would use PDFKit to generate PDF
    NSString *text = [self generateTextReport:statistics];
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

+ (void)emailReport:(NSString *)report toRecipients:(NSArray<NSString *> *)recipients {
    // Would use mail framework
    NSLog(@"[ReportGenerator] Emailing report to %@", recipients);
}

+ (void)saveReportToFile:(NSString *)report path:(NSString *)path {
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@end