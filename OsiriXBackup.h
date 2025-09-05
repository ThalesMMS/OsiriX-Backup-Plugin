#import <Foundation/Foundation.h>
#import <OsiriXAPI/PluginFilter.h>
#import <OsiriXAPI/BrowserController.h>
#import <OsiriXAPI/DicomStudy.h>
#import <OsiriXAPI/DicomSeries.h>
#import <OsiriXAPI/DicomDatabase.h>
#import <OsiriXAPI/DCMTKStoreSCU.h>

@interface OsiriXBackup : PluginFilter
{
    IBOutlet NSWindow *configWindow;
    IBOutlet NSTextField *hostField;
    IBOutlet NSTextField *portField;
    IBOutlet NSTextField *aeDestinationField;
    IBOutlet NSTextField *aeTitleField;
    IBOutlet NSProgressIndicator *progressIndicator;
    IBOutlet NSTextField *statusLabel;
    IBOutlet NSButton *startBackupButton;
    IBOutlet NSButton *pauseBackupButton;
    IBOutlet NSButton *stopBackupButton;
    IBOutlet NSButton *closeWindowButton;
    IBOutlet NSButton *skipVerificationCheckbox;
    IBOutlet NSButton *simpleVerificationCheckbox; // Nova variável

    NSString *hostAddress;
    NSInteger portNumber;
    NSString *aeDestination;
    NSString *aeTitle;
    NSString *findscuPath;
    BOOL skipVerification;
    BOOL useSimpleVerification; // Nova variável

    NSMutableArray *pendingStudies;
    NSTimer *backupTimer;
    BOOL isBackupRunning;
    BOOL isBackupPaused;
    BOOL forceResend;

    NSMutableSet *activeTransfers;
    NSLock *transferLock;
    NSMutableDictionary *retryCounts;
}

- (long)filterImage:(NSString*)menuName;
- (IBAction)startBackup:(id)sender;
- (IBAction)pauseBackup:(id)sender;
- (IBAction)stopBackup:(id)sender;
- (IBAction)saveSettings:(id)sender;
- (IBAction)cancelSettings:(id)sender;
- (IBAction)closeBackupWindow:(id)sender;
- (IBAction)toggleBackup:(id)sender;

- (void)loadSettings;
- (void)saveSettingsToDefaults;
- (void)processNextStudy;
- (void)updateBackupProgress;
- (void)monitorTransferCompletion:(NSDictionary *)userInfo;
- (NSString *)detectFindscuPath;
- (void)startBackupProcess;
- (void)actuallyStopBackup;
- (void)checkActiveTransfersAndClose;
- (void)finalizeBackup;
- (void)updateStatusForPausedBackup;
- (BOOL)studyExistsWithCountCheck:(NSString *)studyUID; // Método para verificação simplificada
- (NSArray<NSDictionary *> *)fetchImageLevelInstancesForStudy:(NSString *)studyUID;
@end
