// OsiriXBackup.m - Versão com novas correções (continuação)

#import "OsiriXBackup.h"
// Tentar importar NSFileManager+N2.h, mesmo que o método específico não funcione,
// pode haver outras utilidades nele. Se causar erro de "arquivo não encontrado", remova.
// #import <OsiriXAPI/NSFileManager+N2.h> // Comentado - pode não existir em todas as versões
#import <OsiriXAPI/N2Shell.h>
#import <AppKit/AppKit.h> // Para NSRunningApplication

static const NSUInteger MAX_SIMULTANEOUS_TRANSFERS = 2;

@implementation OsiriXBackup

// Método auxiliar para obter o caminho do executável do OsiriX de forma mais robusta
- (NSString *)getOsiriXExecutablePath {
    // Tentar obter para OsiriX MD primeiro
    NSString *bundleIDMD = @"com.rossetantoine.osirixmd";
    NSArray<NSRunningApplication *> *runningAppsMD = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIDMD];
    if (runningAppsMD.count > 0) {
        return runningAppsMD[0].executableURL.path;
    }

    // Tentar para OsiriX (versão não-MD)
    NSString *bundleIDOsiriX = @"com.rossetantoine.osirix";
    NSArray<NSRunningApplication *> *runningAppsOsiriX = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIDOsiriX];
    if (runningAppsOsiriX.count > 0) {
        return runningAppsOsiriX[0].executableURL.path;
    }
    
    // Fallback para caminhos comuns se não estiver rodando ou não for encontrado pelo bundleID
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *commonAppNames = @[@"OsiriX MD.app", @"OsiriX.app", @"OsiriX Lite.app"];
    for (NSString *appName in commonAppNames) {
        NSString *appPath = [@"/Applications" stringByAppendingPathComponent:appName];
        NSBundle *appBundle = [NSBundle bundleWithPath:appPath];
        if (appBundle.executablePath && [fm fileExistsAtPath:appBundle.executablePath]) {
            return appBundle.executablePath;
        }
    }
    
    // Último recurso, se o plugin estiver dentro do bundle do OsiriX.
    // Isso pode não ser o caso se for um plugin externo.
    NSString* mainBundlePath = [[NSBundle mainBundle] executablePath];
    if ([mainBundlePath.lastPathComponent.lowercaseString containsString:@"osirix"]) {
        return mainBundlePath;
    }

    return nil; // Não foi possível encontrar
}

- (void)initPlugin
{
    pendingStudies = [[NSMutableArray alloc] init];
    retryCounts = [[NSMutableDictionary alloc] init];
    isBackupRunning = NO;
    isBackupPaused = NO;
    activeTransfers = [[NSMutableSet alloc] init];
    transferLock = [[NSLock alloc] init];

    NSRect windowRect = NSMakeRect(0, 0, 400, 410); // Aumentei a altura para acomodar o novo checkbox
    configWindow = [[NSWindow alloc] initWithContentRect:windowRect
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    [configWindow setTitle:@"OsiriX Backup"];
    
    NSTextField *hostLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 330, 150, 20)];
    [hostLabel setStringValue:@"Endereço do Host:"]; [hostLabel setBezeled:NO]; [hostLabel setDrawsBackground:NO]; [hostLabel setEditable:NO]; [hostLabel setSelectable:NO];
    NSTextField *portLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 290, 150, 20)];
    [portLabel setStringValue:@"Porta:"]; [portLabel setBezeled:NO]; [portLabel setDrawsBackground:NO]; [portLabel setEditable:NO]; [portLabel setSelectable:NO];
    NSTextField *aeDestLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 250, 150, 20)];
    [aeDestLabel setStringValue:@"AE Destination:"]; [aeDestLabel setBezeled:NO]; [aeDestLabel setDrawsBackground:NO]; [aeDestLabel setEditable:NO]; [aeDestLabel setSelectable:NO];
    NSTextField *aeTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 210, 150, 20)];
    [aeTitleLabel setStringValue:@"AE Title Local:"]; [aeTitleLabel setBezeled:NO]; [aeTitleLabel setDrawsBackground:NO]; [aeTitleLabel setEditable:NO]; [aeTitleLabel setSelectable:NO];
    hostField = [[NSTextField alloc] initWithFrame:NSMakeRect(170, 330, 200, 20)];
    portField = [[NSTextField alloc] initWithFrame:NSMakeRect(170, 290, 200, 20)];
    aeDestinationField = [[NSTextField alloc] initWithFrame:NSMakeRect(170, 250, 200, 20)];
    aeTitleField = [[NSTextField alloc] initWithFrame:NSMakeRect(170, 210, 200, 20)];
    
    progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 130, 350, 20)];
    [progressIndicator setMinValue:0.0]; [progressIndicator setMaxValue:100.0]; [progressIndicator setIndeterminate:NO];
    statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 110, 350, 20)];
    [statusLabel setStringValue:@""]; [statusLabel setBezeled:NO]; [statusLabel setDrawsBackground:NO]; [statusLabel setEditable:NO]; [statusLabel setSelectable:NO];
    
    skipVerificationCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 80, 350, 20)];
    [skipVerificationCheckbox setButtonType:NSButtonTypeSwitch];
    [skipVerificationCheckbox setTitle:@"Pular verificação de existência (mais rápido, mas pode duplicar)"];
    [skipVerificationCheckbox setState:NSControlStateValueOff];
    
    // Novo checkbox para verificação simplificada
    simpleVerificationCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 60, 350, 20)];
    [simpleVerificationCheckbox setButtonType:NSButtonTypeSwitch];
    [simpleVerificationCheckbox setTitle:@"Usar verificação simplificada (recomendado)"];
    [simpleVerificationCheckbox setState:NSControlStateValueOn]; // Ativar por padrão
    
    startBackupButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 20, 120, 30)];
    [startBackupButton setTitle:@"Iniciar Backup"]; [startBackupButton setBezelStyle:NSBezelStyleRounded]; [startBackupButton setTarget:self]; [startBackupButton setAction:@selector(toggleBackup:)];
    pauseBackupButton = [[NSButton alloc] initWithFrame:NSMakeRect(150, 20, 100, 30)];
    [pauseBackupButton setTitle:@"Pausar"]; [pauseBackupButton setBezelStyle:NSBezelStyleRounded]; [pauseBackupButton setTarget:self]; [pauseBackupButton setAction:@selector(pauseBackup:)];
    stopBackupButton = [[NSButton alloc] initWithFrame:NSMakeRect(260, 20, 100, 30)];
    [stopBackupButton setTitle:@"Parar"]; [stopBackupButton setBezelStyle:NSBezelStyleRounded]; [stopBackupButton setTarget:self]; [stopBackupButton setAction:@selector(stopBackup:)];
    closeWindowButton = [[NSButton alloc] initWithFrame:NSMakeRect(150, 20, 100, 30)]; // Ajustar posição se necessário para não sobrepor
    [closeWindowButton setTitle:@"Fechar"]; [closeWindowButton setBezelStyle:NSBezelStyleRounded]; [closeWindowButton setTarget:self]; [closeWindowButton setAction:@selector(closeBackupWindow:)];
    [closeWindowButton setHidden:YES];
    
    [pauseBackupButton setEnabled:NO];
    [stopBackupButton setEnabled:NO];
    
    NSView *contentView = [configWindow contentView];
    [contentView addSubview:hostLabel]; [contentView addSubview:portLabel]; [contentView addSubview:aeDestLabel]; [contentView addSubview:aeTitleLabel];
    [contentView addSubview:hostField]; [contentView addSubview:portField];
    [contentView addSubview:aeDestinationField]; [contentView addSubview:aeTitleField];
    [contentView addSubview:progressIndicator]; [contentView addSubview:statusLabel];
    [contentView addSubview:skipVerificationCheckbox];
    [contentView addSubview:simpleVerificationCheckbox]; // Adicionando o novo checkbox à UI
    [contentView addSubview:startBackupButton]; [contentView addSubview:pauseBackupButton]; [contentView addSubview:stopBackupButton];
    [contentView addSubview:closeWindowButton];
    
//    self->findscuPath = [self detectFindscuPath];
    [self loadSettings];
    NSLog(@"OsiriXBackup inicializado com sucesso!");
}

- (NSString*)detectFindscuPath {
    NSArray *paths = @[
        @"/opt/homebrew/bin/findscu", // Apple Silicon (Homebrew)
        @"/usr/local/bin/findscu",    // Intel Homebrew
        @"/opt/dcmtk/bin/findscu",    // Instalações manuais
        @"/usr/bin/findscu",           // Último recurso
        [self findscuExecutablePath]
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if ([fm isExecutableFileAtPath:path]) {
            NSLog(@"[OsiriXBackup] findscu localizado em: %@", path);
            return path;
        }
    }

    NSLog(@"[OsiriXBackup] ERRO: 'findscu' não encontrado.");
    return nil;
}


- (BOOL)testFindscuExecutable:(NSString *)path {
    if (!path || [path length] == 0) return NO;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:path] || ![fileManager isExecutableFileAtPath:path]) return NO;

    // CORREÇÃO: Usar N2Shell com a assinatura correta
    NSString *output = [N2Shell execute:path arguments:@[@"--version"]];
    if (!output || [output length] == 0) return NO;
    return ([output rangeOfString:@"findscu"].location != NSNotFound &&
            [output rangeOfString:@"DCMTK"].location != NSNotFound);
}

- (void)dealloc {
    [backupTimer invalidate];
    backupTimer = nil;
}

- (NSString *)destinationHost {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"BackupDestinationHost"] ?: @"127.0.0.1";
}

- (NSString *)destinationPort {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"BackupDestinationPort"] ?: @"104";
}

- (NSString *)localAETitle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"BackupLocalAETitle"] ?: @"OSIRIX";
}

- (NSString *)destinationAETitle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"BackupDestinationAETitle"] ?: @"DESTINO";
}

- (BOOL)studyExistsOnDestination:(NSString *)studyUID {
    NSString *findscuPath = [self findscuExecutablePath];
    if (!findscuPath || ![[NSFileManager defaultManager] isExecutableFileAtPath:findscuPath]) {
        NSLog(@"[studyExistsOnDestination] findscu inválido: %@", findscuPath);
        return NO;
    }

    NSString *host = [self destinationHost];
    NSString *port = [self destinationPort];
    NSString *callingAET = [self localAETitle];
    NSString *calledAET = [self destinationAETitle];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:findscuPath];
    [task setArguments:@[@"-v",
                         @"-aet", callingAET,
                         @"-aec", calledAET,
                         @"-P",
                         @"-k", @"QueryRetrieveLevel=STUDY",
                         @"-k", [NSString stringWithFormat:@"StudyInstanceUID=%@", studyUID],
                         host, port]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];

    @try {
        [task launch];
        [task waitUntilExit];

        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

        NSLog(@"[OsiriXBackup] Output do findscu:\n%@", output);
        return ([output containsString:studyUID]);
    } @catch (NSException *exception) {
        NSLog(@"[OsiriXBackup] Erro ao executar findscu: %@", exception);
        return NO;
    }
}


- (void)createUIProgrammatically {
    NSRect frame = NSMakeRect(0, 0, 500, 400);
    self->configWindow = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:(NSWindowStyleMaskTitled |
                                                                 NSWindowStyleMaskClosable |
                                                                 NSWindowStyleMaskResizable)
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    [self->configWindow setTitle:@"Configuração de Backup DICOM"];

    NSView *contentView = [self->configWindow contentView];
    
    CGFloat y = 340;
    CGFloat labelWidth = 120;
    CGFloat fieldWidth = 320;
    CGFloat height = 24;
    CGFloat spacing = 35;

    // Função para criar label
    NSTextField* (^makeLabel)(NSString*, CGFloat) = ^(NSString *title, CGFloat yPos) {
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, yPos, labelWidth, height)];
        [label setStringValue:title];
        [label setBezeled:NO];
        [label setDrawsBackground:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        return label;
    };

    // Host
    [contentView addSubview:makeLabel(@"Host:", y)];
    self->hostField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, y, fieldWidth, height)];
    [contentView addSubview:self->hostField];
    y -= spacing;

    // Porta
    [contentView addSubview:makeLabel(@"Porta:", y)];
    self->portField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, y, fieldWidth, height)];
    [contentView addSubview:self->portField];
    y -= spacing;

    // AE Title
    [contentView addSubview:makeLabel(@"AE Title:", y)];
    self->aeTitleField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, y, fieldWidth, height)];
    [contentView addSubview:self->aeTitleField];
    y -= spacing;

    // AE Destination
    [contentView addSubview:makeLabel(@"AE Destination:", y)];
    self->aeDestinationField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, y, fieldWidth, height)];
    [contentView addSubview:self->aeDestinationField];
    y -= spacing;

    // Checkbox
    self->skipVerificationCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, y, fieldWidth, height)];
    [self->skipVerificationCheckbox setButtonType:NSSwitchButton];
    [self->skipVerificationCheckbox setTitle:@"Pular verificação com echoscu"];
    [contentView addSubview:self->skipVerificationCheckbox];
    y -= spacing;
    
    // Adicionar o novo checkbox
    self->simpleVerificationCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, y, fieldWidth, height)];
    [self->simpleVerificationCheckbox setButtonType:NSSwitchButton];
    [self->simpleVerificationCheckbox setTitle:@"Usar verificação simplificada (recomendado)"];
    [self->simpleVerificationCheckbox setState:NSControlStateValueOn];
    [contentView addSubview:self->simpleVerificationCheckbox];
    y -= spacing;

    // Status label
    self->statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, fieldWidth, height)];
    [self->statusLabel setBezeled:NO];
    [self->statusLabel setDrawsBackground:NO];
    [self->statusLabel setEditable:NO];
    [self->statusLabel setSelectable:NO];
    [self->statusLabel setStringValue:@"Status: aguardando"];
    [contentView addSubview:self->statusLabel];
    y -= spacing;

    // Barra de progresso
    self->progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, y, fieldWidth, 20)];
    [self->progressIndicator setIndeterminate:NO];
    [self->progressIndicator setMinValue:0.0];
    [self->progressIndicator setMaxValue:100.0];
    [contentView addSubview:self->progressIndicator];
    y -= spacing;

    // Botões
    CGFloat buttonWidth = 130;
    CGFloat buttonHeight = 30;
    CGFloat buttonY = 20;

    self->startBackupButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, buttonY, buttonWidth, buttonHeight)];
    [self->startBackupButton setTitle:@"Iniciar Backup"];
    [self->startBackupButton setTarget:self];
    [self->startBackupButton setAction:@selector(startBackup:)];
    [contentView addSubview:self->startBackupButton];

    self->pauseBackupButton = [[NSButton alloc] initWithFrame:NSMakeRect(160, buttonY, buttonWidth, buttonHeight)];
    [self->pauseBackupButton setTitle:@"Pausar Backup"];
    [self->pauseBackupButton setTarget:self];
    [self->pauseBackupButton setAction:@selector(pauseBackup:)];
    [contentView addSubview:self->pauseBackupButton];

    self->stopBackupButton = [[NSButton alloc] initWithFrame:NSMakeRect(300, buttonY, buttonWidth, buttonHeight)];
    [self->stopBackupButton setTitle:@"Parar Backup"];
    [self->stopBackupButton setTarget:self];
    [self->stopBackupButton setAction:@selector(stopBackup:)];
    [contentView addSubview:self->stopBackupButton];
}


- (long)filterImage:(NSString*)menuName {
    // Tentar carregar o XIB se ainda não foi carregado
    if (configWindow == nil) {
        NSBundle *pluginBundle = [NSBundle bundleForClass:[self class]];
        NSArray *topLevelObjects = nil;
        
        // Tentar carregar Settings.xib primeiro (arquivo existente)
        if (![pluginBundle loadNibNamed:@"Settings" owner:self topLevelObjects:&topLevelObjects]) {
            // Se falhar, tentar OsiriXBackup.xib
            if (![pluginBundle loadNibNamed:@"OsiriXBackup" owner:self topLevelObjects:&topLevelObjects]) {
                NSLog(@"[OsiriXBackup] XIB não encontrado, criando interface via código");
                [self createUIProgrammatically];
            } else {
                NSLog(@"[OsiriXBackup] OsiriXBackup.xib carregado com sucesso");
            }
        } else {
            NSLog(@"[OsiriXBackup] Settings.xib carregado com sucesso");
        }
    }

    if ([menuName isEqualToString:@"Iniciar Backup DICOM"]) {
        if (self->isBackupRunning) {
            if (![self->configWindow isVisible]) {
                [self->configWindow makeKeyAndOrderFront:self];
            }
        } else {
            if (self->hostAddress && self->portNumber > 0 && self->aeDestination && self->aeTitle) {
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:@"Iniciar Backup DICOM"];
                [alert setInformativeText:@"Deseja iniciar o backup com as configurações salvas ou editar as configurações primeiro?"];
                [alert addButtonWithTitle:@"Iniciar"];
                [alert addButtonWithTitle:@"Configurar"];
                
                if ([alert runModal] == NSAlertFirstButtonReturn) {
                    [self startBackupProcess];
                } else {
                    [self->configWindow makeKeyAndOrderFront:self];
                }
            } else {
                [self->configWindow makeKeyAndOrderFront:self];
            }
        }
    } else if ([menuName isEqualToString:@"Configurações de Backup"]) {
        [self->configWindow makeKeyAndOrderFront:self];
    }
    
    return 0;
}


- (void)loadSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    hostAddress = [defaults objectForKey:@"OsiriXBackupHostAddress"];
    portNumber = [defaults integerForKey:@"OsiriXBackupPortNumber"];
    aeDestination = [defaults objectForKey:@"OsiriXBackupAEDestination"];
    aeTitle = [defaults objectForKey:@"OsiriXBackupAETitle"];
    findscuPath = [defaults objectForKey:@"OsiriXBackupFindscuPath"];
    skipVerification = [defaults boolForKey:@"OsiriXBackupSkipVerification"];
    useSimpleVerification = [defaults boolForKey:@"OsiriXBackupUseSimpleVerification"];
    
    // Se nunca foi salvo, define como padrão ativado
    if (![defaults objectForKey:@"OsiriXBackupUseSimpleVerification"]) {
        useSimpleVerification = YES;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->hostField) {
            [self->hostField setStringValue:self->hostAddress ?: @""];
            [self->portField setStringValue:[NSString stringWithFormat:@"%ld", (long)self->portNumber]];
            [self->aeDestinationField setStringValue:self->aeDestination ?: @""];
            [self->aeTitleField setStringValue:self->aeTitle ?: @"OSIRIX"];
            [self->skipVerificationCheckbox setState:self->skipVerification ? NSControlStateValueOn : NSControlStateValueOff];
            [self->simpleVerificationCheckbox setState:self->useSimpleVerification ? NSControlStateValueOn : NSControlStateValueOff];
        }
    });
}

- (void)saveSettingsToDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:hostAddress forKey:@"OsiriXBackupHostAddress"];
    [defaults setInteger:portNumber forKey:@"OsiriXBackupPortNumber"];
    [defaults setObject:aeDestination forKey:@"OsiriXBackupAEDestination"];
    [defaults setObject:aeTitle forKey:@"OsiriXBackupAETitle"];
    [defaults setObject:findscuPath forKey:@"OsiriXBackupFindscuPath"];
    [defaults setBool:skipVerification forKey:@"OsiriXBackupSkipVerification"];
    [defaults setBool:useSimpleVerification forKey:@"OsiriXBackupUseSimpleVerification"];
    [defaults synchronize];
}

- (IBAction)closeBackupWindow:(id)sender {
    [configWindow orderOut:self];
}

- (IBAction)saveSettings:(id)sender { // IBAction -> Main Thread
    hostAddress = [hostField stringValue];
    portNumber = [[portField stringValue] integerValue];
    aeDestination = [aeDestinationField stringValue];
    aeTitle = [aeTitleField stringValue];
    skipVerification = ([skipVerificationCheckbox state] == NSControlStateValueOn);
    useSimpleVerification = ([simpleVerificationCheckbox state] == NSControlStateValueOn);
    [self saveSettingsToDefaults];
    [configWindow orderOut:self];
    if (sender == startBackupButton) { // Se "Iniciar Backup" foi clicado na config e depois "Salvar" implicitamente
        [self startBackupProcess];
    }
}

- (IBAction)cancelSettings:(id)sender { // IBAction -> Main Thread
    [self loadSettings];
    [configWindow orderOut:self];
}

- (IBAction)toggleBackup:(id)sender { // IBAction -> Main Thread
    if (isBackupRunning) {
        [self stopBackup:sender];
    } else {
        hostAddress = [hostField stringValue]; // Garante que os valores atuais da UI sejam usados
        portNumber = [[portField stringValue] integerValue];
        aeDestination = [aeDestinationField stringValue];
        aeTitle = [aeTitleField stringValue];
        skipVerification = ([skipVerificationCheckbox state] == NSControlStateValueOn);
        useSimpleVerification = ([simpleVerificationCheckbox state] == NSControlStateValueOn);
        [self saveSettingsToDefaults]; // Salva antes de iniciar
        [self startBackupProcess];
    }
}

- (IBAction)startBackup:(id)sender {
    NSLog(@"[OsiriXBackup] Backup iniciado.");
    [self startBackupProcess];
}

- (void)checkActiveTransfersAndClose {
    [transferLock lock];
    if (activeTransfers.count == 0) {
        [configWindow close];
    }
    [transferLock unlock];
}


- (void)startBackupProcess { // Chamado por UI Actions -> Main Thread
    if (!hostAddress || [hostAddress length] == 0 || portNumber <= 0 ||
        !aeDestination || [aeDestination length] == 0 || !aeTitle || [aeTitle length] == 0) {
        NSAlert *alert = [NSAlert alertWithMessageText:@"Configurações Incompletas" defaultButton:@"OK" alternateButton:nil otherButton:nil informativeTextWithFormat:@"Por favor, complete todas as configurações."];
        [alert runModal];
        return;
    }

    if (!skipVerification && (!findscuPath || [findscuPath length] == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:findscuPath])) {
        NSAlert *alert = [NSAlert alertWithMessageText:@"Ferramenta findscu não encontrada" defaultButton:@"Pular Verificação" alternateButton:@"Cancelar" otherButton:@"Procurar" informativeTextWithFormat:@"Caminho do findscu não configurado ou inválido. Pular verificação pode duplicar estudos."];
        NSInteger result = [alert runModal];
        if (result == NSAlertAlternateReturn) return; // Cancelar
        if (result == NSAlertOtherReturn) { // Procurar
            NSOpenPanel *openPanel = [NSOpenPanel openPanel];
            [openPanel setCanChooseFiles:YES]; [openPanel setCanChooseDirectories:NO]; [openPanel setAllowsMultipleSelection:NO];
            [openPanel setTitle:@"Selecionar o executável findscu"];
            if ([openPanel runModal] == NSModalResponseOK) {
                findscuPath = [[[openPanel URLs] objectAtIndex:0] path];
                [self saveSettingsToDefaults];
            } else return; // Cancelou seleção
        } else { // Pular
            skipVerification = YES;
            [skipVerificationCheckbox setState:NSControlStateValueOn];
            [self saveSettingsToDefaults];
        }
    }

    DicomDatabase *database = [DicomDatabase activeLocalDatabase];
    NSArray *allStudies = [database objectsForEntity:@"Study"];
    @synchronized(pendingStudies) {
        [pendingStudies removeAllObjects];
        [pendingStudies addObjectsFromArray:allStudies];
    }
    isBackupRunning = YES;
    isBackupPaused = NO;

    [startBackupButton setTitle:@"Parar Backup"];
    [pauseBackupButton setEnabled:YES]; [stopBackupButton setEnabled:YES];
    [pauseBackupButton setTitle:@"Pausar"];
    [closeWindowButton setHidden:YES]; [pauseBackupButton setHidden:NO]; [stopBackupButton setHidden:NO];
    [progressIndicator setDoubleValue:0.0];
    [statusLabel setStringValue:@"Iniciando backup..."];

    if (![configWindow isVisible]) { // Ainda pode ser chamado aqui de filterImage
        [configWindow makeKeyAndOrderFront:self];
    }

    [hostField setEnabled:NO]; [portField setEnabled:NO]; [aeDestinationField setEnabled:NO];
    [aeTitleField setEnabled:NO]; [skipVerificationCheckbox setEnabled:NO];
    
    [self processNextStudy]; // Inicia o processo em background (processNextStudy despacha para background)
}

- (IBAction)pauseBackup:(id)sender { // IBAction -> Main Thread
    if (!isBackupRunning) return;
    isBackupPaused = !isBackupPaused;
    if (isBackupPaused) {
        [pauseBackupButton setTitle:@"Continuar"];
        [statusLabel setStringValue:@"Backup pausado. Transferências atuais concluirão."];
        NSLog(@"### BACKUP PAUSADO PELO USUÁRIO ###");
        // A lógica de não iniciar novas transferências está em processNextStudy
        // Se não houver transferências ativas, o statusLabel pode ser atualizado para "Backup pausado."
        [transferLock lock];
        if ([activeTransfers count] == 0) {
            [statusLabel setStringValue:@"Backup pausado."];
        }
        [transferLock unlock];

    } else {
        [pauseBackupButton setTitle:@"Pausar"];
        [statusLabel setStringValue:@"Retomando backup..."];
        NSLog(@"### BACKUP RETOMADO PELO USUÁRIO ###");
        [self processNextStudy]; // Tenta continuar o processamento
    }
}

- (BOOL)verifyStudyTransferSuccess:(NSString *)studyInstanceUID
                          seriesUID:(NSString *)seriesUID
                      expectedCount:(int)expectedImages
{
    NSString *findscuPath = [self findscuExecutablePath];
    if (!findscuPath || ![[NSFileManager defaultManager] isExecutableFileAtPath:findscuPath]) {
        NSLog(@"[verifyStudyTransferSuccess] Caminho inválido para findscu: %@", findscuPath);
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:findscuPath];
    [task setArguments:@[
        @"-xi", @"-S",
        @"-k", @"0008,0052=IMAGE",
        @"-k", [NSString stringWithFormat:@"0020,000D=%@", studyInstanceUID],
        @"-k", [NSString stringWithFormat:@"0020,000E=%@", seriesUID],
        @"-aet", aeTitle,
        @"-aec", aeDestination,
        hostAddress,
        [NSString stringWithFormat:@"%d", (int)portNumber]
    ]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        NSLog(@"[verifyStudyTransferSuccess] Erro ao executar findscu: %@", exception);
        return NO;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"# Dicom-Data-Set" options:0 error:nil];
    NSUInteger count = [regex numberOfMatchesInString:output options:0 range:NSMakeRange(0, output.length)];

    NSLog(@"Verificação de envio para série %@: Esperado %d, Recebido %lu", seriesUID, expectedImages, (unsigned long)count);

    return count >= expectedImages;
}


- (IBAction)stopBackup:(id)sender { // IBAction -> Main Thread
    if (!isBackupRunning) return;
    [transferLock lock];
    NSUInteger activeCount = [activeTransfers count];
    [transferLock unlock];
    if (activeCount > 0) {
        NSAlert *alert = [NSAlert alertWithMessageText:@"Interromper Backup" defaultButton:@"Sim" alternateButton:@"Não" otherButton:nil informativeTextWithFormat:@"Há %lu transferências ativas. Interromper mesmo assim?", (unsigned long)activeCount];
        if ([alert runModal] != NSAlertDefaultReturn) return;
    }
    [self actuallyStopBackup];
}

- (void)actuallyStopBackup { // Chamado pela Main Thread
    NSLog(@"### BACKUP INTERROMPIDO PELO USUÁRIO ###");
    isBackupRunning = NO; // Sinaliza para parar de processar novos estudos
    isBackupPaused = NO;

    @synchronized(pendingStudies) {
        [pendingStudies removeAllObjects]; // Limpa a fila de espera
    }
    
    // Não cancela as transferências DICOM em andamento com DCMTKStoreSCU (ele não tem um método de cancelamento fácil)
    // Elas continuarão até terminar ou falhar. O monitoramento delas chamará finalizeBackup se necessário.

    [statusLabel setStringValue:@"Interrompendo backup..."];

    [transferLock lock];
    NSUInteger activeCount = [activeTransfers count];
    [transferLock unlock];

    if (activeCount == 0) { // Se não há transferências ativas
        [self finalizeBackup];
    } else {
        [statusLabel setStringValue:[NSString stringWithFormat:@"Aguardando %lu transferências atuais concluírem...", (unsigned long)activeCount]];
        // monitorTransferCompletion chamará finalizeBackup quando activeCount chegar a 0 se o backup foi interrompido.
    }
}

- (void)finalizeBackup { // Deve ser chamado na Main Thread
    NSLog(@"### PROCESSO DE BACKUP FINALIZADO/INTERROMPIDO ###");
    [backupTimer invalidate];
    backupTimer = nil;
    isBackupRunning = NO;
    isBackupPaused = NO;

    // Calcular progresso final se necessário
    DicomDatabase *database = [DicomDatabase activeLocalDatabase];
    NSArray *allStudiesInDb = [database objectsForEntity:@"Study"];
    double totalStudiesInDb = [allStudiesInDb count];
    double completedOrSkippedStudies = 0;
    @synchronized(pendingStudies) {
         completedOrSkippedStudies = totalStudiesInDb - [pendingStudies count] - [activeTransfers count];
    }
     if (completedOrSkippedStudies < 0) completedOrSkippedStudies = 0;


    if ([activeTransfers count] == 0 && [pendingStudies count] == 0) { // Completou tudo ou foi interrompido sem pendências
        [statusLabel setStringValue:@"Backup finalizado!"];
        [progressIndicator setDoubleValue:100.0];
    } else { // Interrompido com coisas pendentes ou ativas (que não serão mais processadas)
        [statusLabel setStringValue:@"Backup interrompido."];
        if (totalStudiesInDb > 0) {
            [progressIndicator setDoubleValue:(100.0 * completedOrSkippedStudies / totalStudiesInDb)];
        } else {
            [progressIndicator setDoubleValue:0.0];
        }
    }

    [startBackupButton setTitle:@"Iniciar Backup"];
    [pauseBackupButton setEnabled:NO]; [stopBackupButton setEnabled:NO];
    [pauseBackupButton setTitle:@"Pausar"];
    [pauseBackupButton setHidden:YES]; [stopBackupButton setHidden:YES];
    [closeWindowButton setHidden:NO];
    [hostField setEnabled:YES]; [portField setEnabled:YES]; [aeDestinationField setEnabled:YES];
    [aeTitleField setEnabled:YES]; [skipVerificationCheckbox setEnabled:YES];
    [retryCounts removeAllObjects];
}

- (NSString *)findscuExecutablePath {
    NSString *pluginPath = [[NSBundle bundleForClass:[self class]] bundlePath];
    NSString *fullPath = [pluginPath stringByAppendingPathComponent:@"Contents/Resources/findscu"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:fullPath]) {
        NSLog(@"[OsiriXBackup] ERRO: findscu não encontrado em %@", fullPath);
        return nil;
    }
    return fullPath;
}

- (BOOL)studyFullyExistsOnDestination:(DicomStudy *)study {
    NSLog(@"[OsiriXBackup] Verificando COMPLETUDE do estudo: %@", study.studyInstanceUID);
    NSString *studyUID = study.studyInstanceUID;
    
    // CORREÇÃO CRUCIAL:
    // NÃO devemos pular a verificação, pois é essencial para evitar duplicações!
    if (skipVerification) {
        NSLog(@"[OsiriXBackup] Forçando reenvio para estudo: %@", study.studyInstanceUID);
        return NO; // Assume que não existe para forçar reenvio
    }
    // Esta opção deve ser removida ou reformulada para outro propósito
    
    // Se useSimpleVerification for TRUE, usa o método simplificado
    if (useSimpleVerification) {
        // Usa o método de verificação mais simples e rápido
        BOOL studyExists = [self studyExistsWithCountCheck:study.studyInstanceUID];
        NSLog(@"[OsiriXBackup] Verificação simplificada para o estudo %@: %@",
              study.studyInstanceUID, studyExists ? @"EXISTE" : @"NÃO EXISTE");
        return studyExists;
    }
    
    // Contar imagens do estudo localmente
    NSUInteger localImageCount = 0;
    NSMutableDictionary *localSeriesInstanceDetails = [NSMutableDictionary dictionary];
    
    for (DicomSeries *series in [study valueForKey:@"series"]) {
        NSString *seriesUID = [series valueForKey:@"seriesInstanceUID"];
        NSArray *imagesInSeries = [series valueForKey:@"images"];
        NSUInteger imageCount = [imagesInSeries count];
        
        if (imageCount > 0) {
            localImageCount += imageCount;
            localSeriesInstanceDetails[seriesUID] = @(imageCount);
        }
    }
    
    if (localImageCount == 0) {
        NSLog(@"[OsiriXBackup] Estudo sem imagens: %@", studyUID);
        return NO;
    }
    
    // Comparar com a contagem no servidor (usando uma consulta Series Finder)
    NSString *findscuPath = [self findscuExecutablePath];
    
    // Listar séries do estudo para contar imagens
    NSUInteger remoteImageCount = 0;
    NSMutableArray *seriesInfo = [NSMutableArray array];
    
    // Primeiro buscar séries
    NSTask *seriesTask = [[NSTask alloc] init];
    [seriesTask setLaunchPath:findscuPath];
    [seriesTask setArguments:@[
        @"-S", @"-xi",
        @"-k", @"0008,0052=SERIES",
        @"-k", [NSString stringWithFormat:@"0020,000D=%@", studyUID],
        @"-k", @"0020,000E",  // SeriesInstanceUID
        @"-k", @"0020,1209",  // Number of Series Related Instances
        @"-k", @"0008,103E",  // Series Description
        @"-aet", [self localAETitle],
        @"-aec", [self destinationAETitle],
        @"-to", @"40",
        [self destinationHost],
        [self destinationPort]
    ]];
    
    NSPipe *seriesPipe = [NSPipe pipe];
    [seriesTask setStandardOutput:seriesPipe];
    [seriesTask setStandardError:seriesPipe];
    
    @try {
        [seriesTask launch];
        [seriesTask waitUntilExit];
        
        NSData *seriesData = [[seriesPipe fileHandleForReading] readDataToEndOfFile];
        NSString *seriesOutput = [[NSString alloc] initWithData:seriesData encoding:NSUTF8StringEncoding];
        
        // Processar informações de séries e imagens
        NSArray<NSString *> *lines = [seriesOutput componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSMutableDictionary *currentSeries = nil;
        
        for (NSString *line in lines) {
            if ([line containsString:@"# Dicom-Data-Set"]) {
                if (currentSeries && [currentSeries count] > 0) {
                    [seriesInfo addObject:[currentSeries copy]];
                }
                currentSeries = [NSMutableDictionary dictionary];
            }
            else if (currentSeries) {
                if ([line containsString:@"(0020,000E)"]) {  // SeriesInstanceUID
                    NSRange range = [line rangeOfString:@"] "];
                    if (range.location != NSNotFound) {
                        currentSeries[@"seriesUID"] = [line substringFromIndex:range.location+2];
                    }
                }
                else if ([line containsString:@"(0020,1209)"]) {  // Número de instâncias na série
                    NSRange range = [line rangeOfString:@"] "];
                    if (range.location != NSNotFound) {
                        NSString *countStr = [line substringFromIndex:range.location+2];
                        NSInteger count = [countStr integerValue];
                        currentSeries[@"imageCount"] = @(count);
                        remoteImageCount += count;
                    }
                }
                else if ([line containsString:@"(0008,103E)"]) {  // Series Description
                    NSRange range = [line rangeOfString:@"] "];
                    if (range.location != NSNotFound) {
                        currentSeries[@"description"] = [line substringFromIndex:range.location+2];
                    }
                }
            }
        }
        
        // Adicionar a última série
        if (currentSeries && [currentSeries count] > 0) {
            [seriesInfo addObject:currentSeries];
        }
    } @catch (NSException *exception) {
        NSLog(@"[OsiriXBackup] Exceção ao buscar séries: %@", exception);
        return NO;
    }
    
    // Caso tenha havido problemas com o método anterior, tentar uma aproximação mais simples
    if (remoteImageCount == 0 && [seriesInfo count] == 0) {
        NSLog(@"[OsiriXBackup] Tentando método alternativo para contagem de imagens...");
        
        // Verificar C-FIND ao nível de estudo com número de instâncias
        NSTask *alternativeTask = [[NSTask alloc] init];
        [alternativeTask setLaunchPath:findscuPath];
        [alternativeTask setArguments:@[
            @"-S", @"-xi",
            @"-k", @"0008,0052=STUDY",
            @"-k", [NSString stringWithFormat:@"0020,000D=%@", studyUID],
            @"-k", @"0020,1208",  // Number of Study Related Instances
            @"-aet", [self localAETitle],
            @"-aec", [self destinationAETitle],
            @"-to", @"30",
            [self destinationHost],
            [self destinationPort]
        ]];
        
        NSPipe *altPipe = [NSPipe pipe];
        [alternativeTask setStandardOutput:altPipe];
        [alternativeTask setStandardError:altPipe];
        
        @try {
            [alternativeTask launch];
            [alternativeTask waitUntilExit];
            
            NSData *altData = [[altPipe fileHandleForReading] readDataToEndOfFile];
            NSString *altOutput = [[NSString alloc] initWithData:altData encoding:NSUTF8StringEncoding];
            
            // Buscar número de instâncias
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\(0020,1208\\).*?\\] (\\d+)" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:altOutput options:0 range:NSMakeRange(0, [altOutput length])];
            
            if (match && match.numberOfRanges > 1) {
                NSString *countStr = [altOutput substringWithRange:[match rangeAtIndex:1]];
                remoteImageCount = [countStr integerValue];
                NSLog(@"[OsiriXBackup] Contagem alternativa de imagens: %lu", (unsigned long)remoteImageCount);
            }
        } @catch (NSException *exception) {
            NSLog(@"[OsiriXBackup] Exceção no método alternativo: %@", exception);
        }
    }
    
    // Para estudos pequenos, com menos de 100 imagens, ainda tenta obter detalhes completos
    if (localImageCount < 100) {
        NSArray<NSDictionary *> *detailedInstances = [self fetchImageLevelInstancesForStudy:studyUID];
        if ([detailedInstances count] > remoteImageCount) {
            remoteImageCount = [detailedInstances count];
        }
    }
    
    // Log dos resultados
    NSLog(@"[OsiriXBackup] Comparação de contagem para %@:", studyUID);
    NSLog(@"[OsiriXBackup] Imagens no PACS local: %lu", (unsigned long)localImageCount);
    NSLog(@"[OsiriXBackup] Imagens no servidor remoto: %lu", (unsigned long)remoteImageCount);
    
    // Critério de sucesso:
    // Para estudo pequeno (<100): Contagem exata ou presença de todas as séries
    // Para estudo grande (>=100): Contagem aproximada (>=90% das imagens)
    if (localImageCount < 100) {
        return remoteImageCount >= localImageCount;
    } else {
        // Para estudos grandes, considere completo se tiver pelo menos 90% das imagens
        double completionPercentage = (remoteImageCount * 100.0) / localImageCount;
        BOOL isComplete = completionPercentage >= 90.0;
        
        NSLog(@"[OsiriXBackup] Completude: %.1f%% (%@)",
              completionPercentage,
              isComplete ? @"COMPLETO" : @"INCOMPLETO");
        
        return isComplete;
    }
}

- (void)processNextStudy {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ // Processamento em background
        if (self->isBackupPaused || !self->isBackupRunning) {
            NSLog(@"Backup pausado ou não rodando. Parando processNextStudy.");
            if (self->isBackupPaused) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self updateStatusForPausedBackup]; });
            }
            return;
        }

        DicomStudy *currentStudy = nil;
        @synchronized(self->pendingStudies) {
            if ([self->pendingStudies count] == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([self->activeTransfers count] == 0 && self->isBackupRunning) { // Só finaliza se não houver transferências ativas
                        NSLog(@"Todos estudos processados e sem transferências ativas.");
                        [self finalizeBackup];
                    } else if (self->isBackupRunning) {
                        NSLog(@"Fila de estudos vazia, aguardando %lu transferências ativas.", (unsigned long)[self->activeTransfers count]);
                        [self->statusLabel setStringValue:[NSString stringWithFormat:@"Aguardando %lu transferências...", (unsigned long)[self->activeTransfers count]]];
                    }
                });
                return;
            }
        }

        [self->transferLock lock];
        NSUInteger currentActiveTransfers = [self->activeTransfers count];
        [self->transferLock unlock];

        if (currentActiveTransfers >= MAX_SIMULTANEOUS_TRANSFERS) {
            NSLog(@"Muitas transferências ativas (%lu). Aguardando.", (unsigned long)currentActiveTransfers);
            dispatch_async(dispatch_get_main_queue(), ^{
                 [self->statusLabel setStringValue:[NSString stringWithFormat:@"Aguardando slot (%lu ativas)...", (unsigned long)currentActiveTransfers]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self processNextStudy];
                });
            });
            return;
        }
        
        @synchronized(self->pendingStudies) { // Pegar o próximo estudo com segurança
             if ([self->pendingStudies count] > 0) {
                 currentStudy = [self->pendingStudies objectAtIndex:0];
                 [self->pendingStudies removeObjectAtIndex:0];
             }
        }

        if (!currentStudy) { // Deveria ter sido pego no primeiro check, mas por segurança
            if (self->isBackupRunning) { // Se ainda rodando, tenta de novo
                 dispatch_async(dispatch_get_main_queue(), ^{
                    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(processNextStudy) userInfo:nil repeats:NO];
                 });
            }
            return;
        }

        NSString *studyUID = [currentStudy valueForKey:@"studyInstanceUID"];
        NSString *studyName = [currentStudy valueForKey:@"name"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateBackupProgress]; // Atualiza o progresso antes de verificar/enviar
            [self->statusLabel setStringValue:[NSString stringWithFormat:@"Verificando: %@", studyName]];
        });

        BOOL studyExistsOnDest = [self studyFullyExistsOnDestination:currentStudy];

        if (!self->isBackupRunning) return; // Verifica novamente se o backup foi interrompido

        if (studyExistsOnDest) {
            NSLog(@"Estudo %@ já existe completo. Pulando.", studyName);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->statusLabel setStringValue:[NSString stringWithFormat:@"Pulado: %@", studyName]];
                // updateBackupProgress já foi chamado, não precisa de novo aqui para "pulado"
                // apenas o status.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self processNextStudy];
                });
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->statusLabel setStringValue:[NSString stringWithFormat:@"Enviando: %@", studyName]];
            });
            NSLog(@"Enviando estudo: %@", studyName);
            NSMutableArray *filesToSend = [NSMutableArray array];
            NSArray *seriesArray = [currentStudy valueForKey:@"series"];
            for (DicomSeries *series in seriesArray) {
                NSArray *imagesInSeries = [series valueForKey:@"images"];
                for (id imageObj in imagesInSeries) { // DicomImage
                    NSString *path = [imageObj valueForKey:@"completePath"];
                    if (path) [filesToSend addObject:path];
                }
            }

            if ([filesToSend count] == 0) {
                NSLog(@"Nenhum arquivo para enviar para o estudo %@", studyName);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->statusLabel setStringValue:[NSString stringWithFormat:@"Sem arquivos: %@", studyName]];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self processNextStudy];
                    });
                });
                return; // Volta para o início do método (na thread de background)
            }

            [self->transferLock lock];
            [self->activeTransfers addObject:studyUID];
            [self->transferLock unlock];

            DCMTKStoreSCU *storeSCU = [[DCMTKStoreSCU alloc] initWithCallingAET:self->aeTitle
                                                                       calledAET:self->aeDestination
                                                                        hostname:self->hostAddress
                                                                            port:(int)self->portNumber
                                                                     filesToSend:filesToSend
                                                                  transferSyntax:0
                                                                 extraParameters:nil];
            NSDictionary *userInfoDict = @{
                @"studyUID": studyUID, @"studyName": studyName,
                @"storeSCU": storeSCU, @"dicomStudy": currentStudy
            };
            NSThread *monitorThread = [[NSThread alloc] initWithTarget:self selector:@selector(monitorTransferCompletion:) object:userInfoDict];
            [monitorThread start];
//            [NSThread detachNewThreadSelector:@selector(run) toTarget:storeSCU withObject:nil];
            
            // Após iniciar uma transferência, imediatamente tenta agendar a próxima se houver slots.
            // Não espera esta transferência atual terminar para popular os slots.
            if (self->isBackupRunning && !self->isBackupPaused) { // Verifica se ainda deve continuar
                dispatch_async(dispatch_get_main_queue(), ^{ // Agendar da main thread
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self processNextStudy];
                    });
                });
            }
        }
    }); // Fim do dispatch_async global queue
}

- (NSString *)generateTransferStatusReport:(NSString *)studyUID withStudy:(DicomStudy *)study {
    NSMutableString *report = [NSMutableString string];
    
    NSString *studyName = [study valueForKey:@"name"] ?: @"(Sem nome)";
    NSString *studyDate = [study valueForKey:@"date"] ? [[study valueForKey:@"date"] description] : @"(Sem data)";
    
    [report appendFormat:@"=== RELATÓRIO DE TRANSFERÊNCIA ===\n"];
    [report appendFormat:@"Estudo: %@ (%@)\n", studyName, studyUID];
    [report appendFormat:@"Data: %@\n\n", studyDate];
    
    // Informações locais
    NSArray *seriesArray = [study valueForKey:@"series"];
    NSUInteger totalLocalImages = 0;
    
    [report appendFormat:@"--- DADOS LOCAIS ---\n"];
    [report appendFormat:@"Número de séries: %lu\n", (unsigned long)[seriesArray count]];
    
    for (DicomSeries *series in seriesArray) {
        NSString *seriesUID = [series valueForKey:@"seriesInstanceUID"];
        NSString *seriesName = [series valueForKey:@"name"] ?: @"(Sem nome)";
        NSString *modality = [series valueForKey:@"modality"] ?: @"(Desconhecida)";
        NSArray *imagesInSeries = [series valueForKey:@"images"];
        NSUInteger imageCount = [imagesInSeries count];
        totalLocalImages += imageCount;
        
        [report appendFormat:@"  • Série: %@ (%@)\n", seriesName, seriesUID];
        [report appendFormat:@"    Modalidade: %@\n", modality];
        [report appendFormat:@"    Imagens: %lu\n", (unsigned long)imageCount];
    }
    
    [report appendFormat:@"Total de imagens locais: %lu\n\n", (unsigned long)totalLocalImages];
    
    // Informações remotas
    [report appendFormat:@"--- DADOS NO DESTINO ---\n"];
    
    NSArray<NSDictionary *> *remoteInstances = [self fetchImageLevelInstancesForStudy:studyUID];
    
    if ([remoteInstances count] == 0) {
        [report appendString:@"Nenhuma imagem encontrada no destino.\n"];
    } else {
        // Contar imagens por série
        NSMutableDictionary *seriesCounts = [NSMutableDictionary dictionary];
        NSMutableDictionary *seriesInfo = [NSMutableDictionary dictionary];
        
        for (NSDictionary *instance in remoteInstances) {
            NSString *seriesUID = instance[@"SeriesInstanceUID"];
            if (!seriesUID) continue;
            
            // Contar imagens
            NSNumber *currentCount = seriesCounts[seriesUID] ?: @(0);
            seriesCounts[seriesUID] = @([currentCount integerValue] + 1);
            
            // Guardar informações adicionais (apenas uma vez por série)
            if (!seriesInfo[seriesUID]) {
                NSMutableDictionary *info = [NSMutableDictionary dictionary];
                if (instance[@"Modality"]) info[@"modality"] = instance[@"Modality"];
                if (instance[@"SeriesDescription"]) info[@"name"] = instance[@"SeriesDescription"];
                seriesInfo[seriesUID] = info;
            }
        }
        
        [report appendFormat:@"Número de séries: %lu\n", (unsigned long)[seriesCounts count]];
        
        for (NSString *seriesUID in seriesCounts) {
            NSDictionary *info = seriesInfo[seriesUID] ?: @{};
            NSString *seriesName = info[@"name"] ?: @"(Sem nome)";
            NSString *modality = info[@"modality"] ?: @"(Desconhecida)";
            NSNumber *count = seriesCounts[seriesUID];
            
            [report appendFormat:@"  • Série: %@ (%@)\n", seriesName, seriesUID];
            [report appendFormat:@"    Modalidade: %@\n", modality];
            [report appendFormat:@"    Imagens: %@\n", count];
        }
        
        [report appendFormat:@"Total de imagens no destino: %lu\n\n", (unsigned long)[remoteInstances count]];
    }
    
    // Status da transferência
    [report appendFormat:@"--- ESTADO DA TRANSFERÊNCIA ---\n"];
    
    if ([remoteInstances count] == 0) {
        [report appendString:@"Estado: NENHUMA IMAGEM TRANSFERIDA\n"];
    } else if ([remoteInstances count] < totalLocalImages) {
        [report appendFormat:@"Estado: TRANSFERÊNCIA INCOMPLETA (%.1f%%)\n",
                        (100.0 * [remoteInstances count]) / totalLocalImages];
    } else {
        [report appendString:@"Estado: TRANSFERÊNCIA COMPLETA\n"];
    }
    
    return report;
}

// Integração realizada dentro de OsiriXBackup
// Função para usar findscu com filtro IMAGE
// e obter a lista de SOPInstanceUIDs para determinado StudyInstanceUID

- (NSArray<NSDictionary *> *)fetchImageLevelInstancesForStudy:(NSString *)studyUID {
    NSString *findscuPath = [self findscuExecutablePath];
    if (!findscuPath || ![[NSFileManager defaultManager] isExecutableFileAtPath:findscuPath]) {
        NSLog(@"[fetchImageLevelInstancesForStudy] Caminho inválido para findscu: %@", findscuPath);
        return @[];
    }

    // Parâmetros de conexão
    NSString *hostname = [self destinationHost];
    NSString *port = [self destinationPort];
    NSString *callingAET = [self localAETitle];
    NSString *calledAET = [self destinationAETitle];
    
    // Usar abordagem alternativa: buscar informações por SÉRIE em vez de IMAGEM
    // Isso é mais eficiente e pode evitar os problemas de timeout
    
    // Passo 1: Obter as séries do estudo
    NSMutableArray<NSString *> *seriesUIDs = [NSMutableArray array];
    NSTask *seriesTask = [[NSTask alloc] init];
    [seriesTask setLaunchPath:findscuPath];
    [seriesTask setArguments:@[
        @"-xi", @"-S",  // Formato de saída estendido e silencioso
        @"-k", @"0008,0052=SERIES",  // Nível de consulta SERIES (mais leve)
        @"-k", [NSString stringWithFormat:@"0020,000D=%@", studyUID],  // StudyInstanceUID
        @"-k", @"0020,000E",  // SeriesInstanceUID
        @"-k", @"0008,0060",  // Modality
        @"-k", @"0008,103E",  // Series Description
        @"-aet", callingAET,
        @"-aec", calledAET,
        @"-to", @"60",  // Timeout de 60 segundos para esta consulta
        hostname,
        port
    ]];

    NSPipe *seriesPipe = [NSPipe pipe];
    [seriesTask setStandardOutput:seriesPipe];
    [seriesTask setStandardError:seriesPipe];
    
    NSLog(@"[fetchImageLevelInstancesForStudy] Buscando séries para estudo %@", studyUID);
    
    @try {
        [seriesTask launch];
        [seriesTask waitUntilExit];
        
        NSData *seriesData = [[seriesPipe fileHandleForReading] readDataToEndOfFile];
        NSString *seriesOutput = [[NSString alloc] initWithData:seriesData encoding:NSUTF8StringEncoding];
        
        // Extrair SeriesInstanceUIDs
        NSArray<NSString *> *lines = [seriesOutput componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSString *currentSeriesUID = nil;
        
        for (NSString *line in lines) {
            if ([line containsString:@"(0020,000E)"]) {  // SeriesInstanceUID
                NSRange range = [line rangeOfString:@"] "];
                if (range.location != NSNotFound) {
                    currentSeriesUID = [line substringFromIndex:range.location+2];
                    [seriesUIDs addObject:currentSeriesUID];
                }
            }
        }
        
        NSLog(@"[fetchImageLevelInstancesForStudy] Encontradas %lu séries para o estudo %@",
              (unsigned long)[seriesUIDs count], studyUID);
    } @catch (NSException *exception) {
        NSLog(@"[fetchImageLevelInstancesForStudy] Exceção ao buscar séries: %@", exception);
        return @[];
    }
    
    if ([seriesUIDs count] == 0) {
        NSLog(@"[fetchImageLevelInstancesForStudy] Nenhuma série encontrada para o estudo %@", studyUID);
        return @[];
    }
    
    // Passo 2: Para cada série, buscar imagens com consultas separadas
    NSMutableArray<NSDictionary *> *allInstances = [NSMutableArray array];
    
    for (NSString *seriesUID in seriesUIDs) {
        NSLog(@"[fetchImageLevelInstancesForStudy] Buscando imagens para série %@", seriesUID);
        
        NSTask *imageTask = [[NSTask alloc] init];
        [imageTask setLaunchPath:findscuPath];
        [imageTask setArguments:@[
            @"-xi", @"-S",  // Formato de saída estendido e silencioso
            @"-k", @"0008,0052=IMAGE",  // Nível de consulta IMAGE
            @"-k", [NSString stringWithFormat:@"0020,000D=%@", studyUID],  // StudyInstanceUID
            @"-k", [NSString stringWithFormat:@"0020,000E=%@", seriesUID],  // SeriesInstanceUID
            @"-k", @"0008,0018",  // SOPInstanceUID
            @"-k", @"0020,0013",  // InstanceNumber
            @"-k", @"0008,0060",  // Modality
            @"-aet", callingAET,
            @"-aec", calledAET,
            @"-to", @"60",  // Timeout aumentado
            @"-P",  // Usar presentation context
            @"-ll", @"error",  // Reduzir nível de log para melhorar desempenho
            hostname,
            port
        ]];

        NSPipe *imagePipe = [NSPipe pipe];
        [imageTask setStandardOutput:imagePipe];
        [imageTask setStandardError:imagePipe];
        
        // Evitar bloqueio indefinido com um timeout auxiliar
        __block BOOL taskFinished = NO;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        
        NSThread *timeoutThread = [[NSThread alloc] initWithBlock:^{
            NSTimeInterval timeout = 90.0;  // 90 segundos para cada série
            NSDate *startTime = [NSDate date];
            
            while (!taskFinished && [[NSDate date] timeIntervalSinceDate:startTime] < timeout) {
                [NSThread sleepForTimeInterval:0.5];
            }
            
            if (!taskFinished) {
                NSLog(@"[fetchImageLevelInstancesForStudy] Timeout ao buscar imagens da série %@", seriesUID);
                [imageTask terminate];
            }
            
            dispatch_semaphore_signal(semaphore);
        }];
        [timeoutThread start];
        
        @try {
            [imageTask launch];
            [imageTask waitUntilExit];
            taskFinished = YES;
            
            NSData *imageData = [[imagePipe fileHandleForReading] readDataToEndOfFile];
            NSString *imageOutput = [[NSString alloc] initWithData:imageData encoding:NSUTF8StringEncoding];
            
            // Verificar se a saída contém resultados válidos
            if ([imageOutput containsString:@"# Dicom-Data-Set"]) {
                // Processar resultados
                NSArray<NSString *> *imageLines = [imageOutput componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                NSMutableDictionary *currentInstance = nil;
                
                for (NSString *line in imageLines) {
                    if ([line containsString:@"# Dicom-Data-Set"]) {
                        if (currentInstance && [currentInstance count] > 0) {
                            [allInstances addObject:[currentInstance copy]];
                        }
                        currentInstance = [NSMutableDictionary dictionary];
                        // Adicionar SeriesInstanceUID para garantir que todas as instâncias tenham essa informação
                        currentInstance[@"SeriesInstanceUID"] = seriesUID;
                    }
                    else if (currentInstance) {
                        if ([line containsString:@"(0008,0018)"]) {  // SOPInstanceUID
                            NSRange range = [line rangeOfString:@"] "];
                            if (range.location != NSNotFound) {
                                currentInstance[@"SOPInstanceUID"] = [line substringFromIndex:range.location+2];
                            }
                        }
                        else if ([line containsString:@"(0020,0013)"]) {  // InstanceNumber
                            NSRange range = [line rangeOfString:@"] "];
                            if (range.location != NSNotFound) {
                                currentInstance[@"InstanceNumber"] = [line substringFromIndex:range.location+2];
                            }
                        }
                        else if ([line containsString:@"(0008,0060)"]) {  // Modality
                            NSRange range = [line rangeOfString:@"] "];
                            if (range.location != NSNotFound) {
                                currentInstance[@"Modality"] = [line substringFromIndex:range.location+2];
                            }
                        }
                    }
                }
                
                // Adicionar o último instance
                if (currentInstance && [currentInstance count] > 0) {
                    [allInstances addObject:currentInstance];
                }
                
                NSLog(@"[fetchImageLevelInstancesForStudy] Série %@: Encontradas %lu instâncias",
                      seriesUID, (unsigned long)[allInstances count] - [allInstances count]);
            } else {
                NSLog(@"[fetchImageLevelInstancesForStudy] Nenhuma instância encontrada para série %@", seriesUID);
            }
        } @catch (NSException *exception) {
            NSLog(@"[fetchImageLevelInstancesForStudy] Exceção ao buscar imagens da série %@: %@", seriesUID, exception);
        }
        
        // Aguardar pelo timeout thread
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        
        // Pausar brevemente entre as consultas para não sobrecarregar o servidor
        [NSThread sleepForTimeInterval:0.5];
    }
    
    NSLog(@"[fetchImageLevelInstancesForStudy] Total de %lu instâncias encontradas para o estudo %@",
          (unsigned long)[allInstances count], studyUID);
    
    return allInstances;
}

- (BOOL)studyExistsWithCountCheck:(NSString *)studyUID {
    NSString *findscuPath = [self findscuExecutablePath];
    if (!findscuPath) return NO;
    
    NSLog(@"[studyExistsWithCountCheck] Verificando estudo %@ no servidor", studyUID);
    
    // Parâmetros DICOM
    NSString *hostname = [self destinationHost];
    NSString *port = [self destinationPort];
    NSString *callingAET = [self localAETitle];
    NSString *calledAET = [self destinationAETitle];
    
    // Consulta de contagem de séries no nível de STUDY
    NSTask *studyTask = [[NSTask alloc] init];
    [studyTask setLaunchPath:findscuPath];
    [studyTask setArguments:@[
        @"-S", @"-xi",  // Silent mode e extended info
        @"-k", @"0008,0052=STUDY",  // Query/Retrieve Level
        @"-k", [NSString stringWithFormat:@"0020,000D=%@", studyUID],  // StudyInstanceUID
        @"-k", @"0020,1200",  // Number of Studies Related Series
        @"-k", @"0020,1206",  // Number of Studies Related Instances
        @"-aet", callingAET,
        @"-aec", calledAET,
        @"-to", @"30",  // Timeout de 30 segundos
        hostname,
        port
    ]];
    
    NSPipe *studyPipe = [NSPipe pipe];
    [studyTask setStandardOutput:studyPipe];
    [studyTask setStandardError:studyPipe];
    
    @try {
        [studyTask launch];
        [studyTask waitUntilExit];
        
        NSData *studyData = [[studyPipe fileHandleForReading] readDataToEndOfFile];
        NSString *studyOutput = [[NSString alloc] initWithData:studyData encoding:NSUTF8StringEncoding];
        
        // Verifica se recebemos algum resultado (o estudo existe no servidor)
        if ([studyOutput containsString:@"# Dicom-Data-Set"]) {
            NSLog(@"[studyExistsWithCountCheck] Estudo %@ encontrado no servidor", studyUID);
            return YES;
        } else {
            NSLog(@"[studyExistsWithCountCheck] Estudo %@ não encontrado no servidor", studyUID);
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"[studyExistsWithCountCheck] Exceção ao verificar estudo: %@", exception);
        return NO;
    }
}

- (void)monitorTransferCompletion:(NSDictionary *)userInfo {
    NSString *studyUID = userInfo[@"studyUID"];
    NSString *studyName = userInfo[@"studyName"];
    DicomStudy *completedStudy = userInfo[@"dicomStudy"];
    DCMTKStoreSCU *storeSCU = userInfo[@"storeSCU"];

    NSLog(@"Monitorando transferência para: %@ (%@)", studyName, studyUID);

    @try {
        [storeSCU run];
    } @catch (NSException *e) {
        NSLog(@"[OsiriXBackup] Exceção ao executar storeSCU: %@", e);
    }

    [NSThread sleepForTimeInterval:3.0];  // Aguardar mais tempo para o servidor processar

    // Para verificação PÓS-ENVIO:
    BOOL transferSuccess = NO; // Inicializar como falha, a verificação determinará o sucesso

    if (!skipVerification) {
        const int maxAttempts = 3;
        const NSTimeInterval retryDelay = 7.0;
        
        if (useSimpleVerification) {
            // Usar verificação simplificada para validar a transferência
            for (int attempt = 1; attempt <= maxAttempts && !transferSuccess; attempt++) {
                NSLog(@"Verificando envio do estudo (tentativa %d de %d)...", attempt, maxAttempts);
                
                // Aguardar para dar tempo ao servidor PACS de processar as imagens
                [NSThread sleepForTimeInterval:(attempt == 1) ? 5.0 : retryDelay];
                
                // Usar verificação simplificada
                BOOL exists = [self studyExistsWithCountCheck:studyUID];
                transferSuccess = exists;
                
                NSLog(@"[monitorTransferCompletion] Verificação simplificada para estudo: %@, Resultado: %@",
                      studyName, exists ? @"EXISTE" : @"NÃO EXISTE");
                
                if (transferSuccess) {
                    NSLog(@"Transferência para estudo %@ verificada com sucesso!", studyName);
                    break;
                } else if (attempt < maxAttempts) {
                    NSLog(@"Transferência incompleta, tentando novamente em %.1f segundos...", retryDelay);
                }
            }
        } else {
            // Usar verificação detalhada original
            for (int attempt = 1; attempt <= maxAttempts && !transferSuccess; attempt++) {
                NSLog(@"Verificando envio do estudo (tentativa %d de %d)...", attempt, maxAttempts);
                
                // Dar mais tempo para o servidor processar as imagens antes de verificar
                [NSThread sleepForTimeInterval:(attempt == 1) ? 5.0 : retryDelay];
                
                // Verificar se o estudo foi transferido com sucesso usando a verificação detalhada
                transferSuccess = [self studyFullyExistsOnDestination:completedStudy];
                
                if (transferSuccess) {
                    NSLog(@"Transferência para estudo %@ verificada com sucesso!", studyName);
                    break;
                } else if (attempt < maxAttempts) {
                    NSLog(@"Transferência incompleta, tentando novamente em %.1f segundos...", retryDelay);
                }
            }
        }
    } else {
        NSLog(@"[monitorTransferCompletion] Verificação pulada para estudo: %@", studyName);
    }

    if (!transferSuccess) {
        NSLog(@"### ERRO NA TRANSFERÊNCIA: %@ (%@) ###", studyName, studyUID);
        if (isBackupRunning && !isBackupPaused && completedStudy) {
            @synchronized(pendingStudies) {
                NSNumber *currentCount = self->retryCounts[studyUID] ?: @(0);
                NSUInteger newCount = [currentCount unsignedIntegerValue] + 1;

                if (newCount <= 3) {
                    self->retryCounts[studyUID] = @(newCount);
                    [pendingStudies addObject:completedStudy];
                    NSLog(@"Estudo %@ readicionado (tentativa %lu de 3).", studyName, (unsigned long)newCount);
                } else {
                    NSLog(@"Estudo %@ excedeu o número máximo de tentativas e será ignorado.", studyName);
                }
            }
        }
    } else {
        NSLog(@"Transferência para %@ (%@) concluída com sucesso.", studyName, studyUID);
        [self->retryCounts removeObjectForKey:studyUID];
    }

    [transferLock lock];
    [activeTransfers removeObject:studyUID];
    NSUInteger currentActiveTransfersCount = [activeTransfers count];
    [transferLock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{ [self updateBackupProgress]; });

    if (isBackupRunning && !isBackupPaused) {
        [self processNextStudy];
    } else {
        if (isBackupPaused) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self updateStatusForPausedBackup]; });
        }
        if (!isBackupRunning && currentActiveTransfersCount == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self finalizeBackup]; });
        }
    }
}

- (void)updateStatusForPausedBackup { // Chamado pela Main Thread ou despacha para ela
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->isBackupPaused) {
             [self->statusLabel setStringValue:@"Backup pausado."];
             [self->transferLock lock];
             if ([self->activeTransfers count] > 0) {
                 [self->statusLabel setStringValue:[NSString stringWithFormat:@"Pausado, aguardando %lu transferências...", (unsigned long)[self->activeTransfers count]]];
             }
             [self->transferLock unlock];
        }
    });
}

- (void)updateBackupProgress { // Chamado pela Main Thread ou despacha para ela
    dispatch_async(dispatch_get_main_queue(), ^{
        DicomDatabase *database = [DicomDatabase activeLocalDatabase];
        NSArray *allStudiesInDb = [database objectsForEntity:@"Study"];
        double totalStudiesInDb = [allStudiesInDb count];
        double studiesProcessedOrInQueue;

        @synchronized(self->pendingStudies) {
            // "Processados" são aqueles que não estão mais na fila 'pendingStudies'
            // Esta métrica indica quantos foram retirados da fila para verificação/envio.
            studiesProcessedOrInQueue = totalStudiesInDb - [self->pendingStudies count];
        }
        
        double progress = 0.0;
        if (totalStudiesInDb > 0) {
            progress = 100.0 * (studiesProcessedOrInQueue / totalStudiesInDb);
            if (progress > 100.0) progress = 100.0; // Garante que não passe de 100%
            if (progress < 0.0) progress = 0.0;     // Garante que não seja negativo
        } else if ([allStudiesInDb count] == 0) { // Se não há estudos no DB
             progress = 100.0; // Considera 100% completo
        }


        [self->progressIndicator setDoubleValue:progress];
        
        NSString *currentOperation = @"";
         if (self->isBackupPaused) {
            currentOperation = @"Pausado. ";
        } else if (self->isBackupRunning) {
            [self->transferLock lock];
            NSUInteger activeCount = [self->activeTransfers count];
            [self->transferLock unlock];
            if (activeCount > 0) {
                 currentOperation = [NSString stringWithFormat:@"Enviando (%lu)... ", (unsigned long)activeCount];
            } else if ([self->pendingStudies count] > 0) { // Só mostra "Verificando" se não houver envios ativos
                 currentOperation = @"Verificando... ";
            } else { // Nem enviando, nem verificando (fila vazia), mas backup pode estar rodando (aguardando finalização)
                currentOperation = @"Concluindo... ";
            }
        }

        NSUInteger studiesDone = (NSUInteger)round(studiesProcessedOrInQueue);
        if (studiesDone > totalStudiesInDb) studiesDone = (NSUInteger)totalStudiesInDb; // Evita mostrar X de Y onde X > Y

        NSString *statusText = [NSString stringWithFormat:@"%@Progresso: %.0f%% (%lu de %lu)",
                                currentOperation, progress, studiesDone, (unsigned long)totalStudiesInDb];
        [self->statusLabel setStringValue:statusText];
    });
}

@end
