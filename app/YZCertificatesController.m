#import "YZCertificatesController.h"
#import "YZCertificates.h"
#import "YZClassic.h"
#import "YZCompat.h"
#import "YZCrash.h"
#import "YZSheets.h"
#import "YZStrings.h"
#import "YZTheme.h"
#import <objc/message.h>

static const CGFloat YZCertificatesBarHeight = 64;
static const CGFloat YZCertificatesRowHeight = 56;
static NSString *const YZCertificatesRowIdentifier = @"yozora.certificates.row";

@implementation YZCertificatesController

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    _table.delegate = nil;
    _table.dataSource = nil;
    [_dialog dismissSilently];
    [_dialog release];
    [_card release];
    [_bar release];
    [_titleLabel release];
    [_subtitleLabel release];
    [_hintLabel release];
    [_add release];
    [_paste release];
    [_table release];
    [_entries release];
    [_fill removeFromSuperview];
    [_fill release];
    [super dealloc];
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    self.view = root;
    [root release];
    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.layer.cornerRadius = [YZTheme sheetRadius];
    _card.clipsToBounds = YES;
    [self.view addSubview:_card];
    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    [_card addSubview:_bar];
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = [YZTheme boldSystemFontOfSize:17];
    _titleLabel.text = YZT(@"Сертификаты");
    [_bar addSubview:_titleLabel];
    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.backgroundColor = [UIColor clearColor];
    _subtitleLabel.font = [YZTheme systemFontOfSize:12];
    [_bar addSubview:_subtitleLabel];
    _add = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _add.frame = CGRectMake(0, 0, 44, 44);
    _add.layer.cornerRadius = 22;
    _add.accessibilityLabel = YZT(@"Добавить сертификат из файла");
    [_add addTarget:self action:@selector(addPressed) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_add];
    _paste = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _paste.frame = CGRectMake(0, 0, 44, 44);
    _paste.layer.cornerRadius = 22;
    _paste.accessibilityLabel = YZT(@"Вставить сертификат из буфера обмена");
    [_paste addTarget:self action:@selector(pastePressed) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_paste];
    _hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _hintLabel.backgroundColor = [UIColor clearColor];
    _hintLabel.font = [YZTheme systemFontOfSize:12];
    _hintLabel.numberOfLines = 0;
    _hintLabel.lineBreakMode = YZLineBreakWordWrapping;
    _hintLabel.text = YZT(@"Сертификат из файла .crt, .cer или .pem становится доверенным для всех сайтов. Добавляйте только те, которым верите, например корень своей сети.");
    [_card addSubview:_hintLabel];
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.allowsSelection = NO;
    _table.dataSource = self;
    _table.delegate = self;
    [_card addSubview:_table];
}

- (void)restyle {
    self.view.backgroundColor = [YZTheme screenColor];
    YZPaintBehindScreens(self.navigationController);
    [YZTheme styleTransparentNavigationBar:self.navigationController.navigationBar];
    if (!_fill)
        _fill = [[YZBarFill alloc] initWithFrame:CGRectZero];
    [_fill applyTheme];
    YZInstallBarTitle(self, YZT(@"Сертификаты"), self, @selector(back));
    _card.backgroundColor = [YZTheme cardColor];
    _titleLabel.textColor = [YZTheme textColor];
    _subtitleLabel.textColor = [YZTheme subtleTextColor];
    _hintLabel.textColor = [YZTheme subtleTextColor];
    [YZClassic styleGlyphKey:_add icon:YZIconPlus size:22 modernRadius:22];
    [YZClassic styleGlyphKey:_paste icon:YZIconCopy size:22 modernRadius:22];
    [self.view setNeedsLayout];
}

- (void)back { [self.navigationController popViewControllerAnimated:YES]; }

- (void)reload {
    [_entries release];
    _entries = [[YZCertificates entries] retain];
    [_table reloadData];
    _subtitleLabel.text = [_entries count] ? [NSString stringWithFormat:@"%lu", (unsigned long)[_entries count]] : YZT(@"Своих сертификатов нет");
    [self.view setNeedsLayout];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:@"screen YZCertificatesController"];
    [self restyle];
    [self reload];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width, height = self.view.bounds.size.height;
    CGFloat top = [YZTheme barOverlap:self.navigationController.navigationBar];
    YZInstallBarTitle(self, YZT(@"Сертификаты"), self, @selector(back));
    [_fill placeInView:self.view controller:self];
    CGFloat side = 12;
    _card.frame = CGRectMake(side, top + 4, width - 2 * side, MAX((CGFloat)0, height - top - 4 - 12));
    CGFloat cw = _card.bounds.size.width;
    _bar.frame = CGRectMake(0, 0, cw, YZCertificatesBarHeight);
    CGFloat right = cw - 16 - 22;
    _paste.center = CGPointMake(right, YZCertificatesBarHeight / 2);
    if (!_add.hidden) {
        _add.center = CGPointMake(right, YZCertificatesBarHeight / 2);
        _paste.center = CGPointMake(right - 48, YZCertificatesBarHeight / 2);
    }
    CGFloat textWidth = MAX((CGFloat)0, CGRectGetMinX(_paste.frame) - 8 - 20);
    _titleLabel.frame = CGRectMake(20, YZCertificatesBarHeight / 2 - 20, textWidth, 22);
    _subtitleLabel.frame = CGRectMake(20, YZCertificatesBarHeight / 2 + 2, textWidth, 16);
    CGFloat hintHeight = ceil([_hintLabel sizeThatFits:CGSizeMake(MAX(cw - 40, (CGFloat)10), 2000)].height);
    _hintLabel.frame = CGRectMake(20, YZCertificatesBarHeight, cw - 40, hintHeight);
    CGFloat tableTop = CGRectGetMaxY(_hintLabel.frame) + 8;
    _table.frame = CGRectMake(0, tableTop, cw, MAX((CGFloat)0, _card.bounds.size.height - tableTop - 6));
}

#pragma mark adding

// what the person is asked before a certificate becomes trusted
- (void)offer:(NSArray *)parsed {
    if (_dialog || ![parsed count])
        return;
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *info in parsed) {
        if ([names count] == 5) {
            [names addObject:@"…"];
            break;
        }
        [names addObject:[NSString stringWithFormat:@"%@ (%@)", [info objectForKey:@"name"], [info objectForKey:@"print"]]];
    }
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@", [names componentsJoinedByString:@"\n"],
                         YZT(@"Браузер будет доверять сайтам с этим сертификатом. Добавляйте его, только если знаете, откуда он.")];
    __block YZCertificatesController *me = self;
    _dialog = [[YZDialog dialogWithTitle:YZT(@"Доверять сертификату?") message:message cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Доверять")
                             destructive:NO handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        [me->_dialog release];
        me->_dialog = nil;
        if (index == 0)
            return;
        NSString *error = nil;
        [YZCertificates add:parsed error:&error];
        [me reload];
        if (error)
            [me say:error];
    }] retain];
    [_dialog showInView:self.view];
}

- (void)say:(NSString *)text {
    if (_dialog)
        return;
    __block YZCertificatesController *me = self;
    _dialog = [[YZDialog dialogWithTitle:YZT(@"Сертификат не добавлен") message:text cancelTitle:nil confirmTitle:YZT(@"Понятно")
                             destructive:NO handler:^(NSInteger index, NSArray *texts) {
        (void)index;
        (void)texts;
        [me->_dialog release];
        me->_dialog = nil;
    }] retain];
    [_dialog showInView:self.view];
}

- (void)takeData:(NSData *)data {
    NSString *error = nil;
    NSArray *parsed = [YZCertificates parseData:data error:&error];
    if (!parsed) {
        [self say:error];
        return;
    }
    [self offer:parsed];
}

- (void)pastePressed {
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (![text length]) {
        [self say:YZT(@"В буфере обмена нет текста сертификата")];
        return;
    }
    [self takeData:[text dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES]];
}

// a certificate is a few kilobytes, a bigger file is not one and is not read into the memory of an old phone
static const unsigned long long YZCertificateFileLimit = 1024 * 1024;

// ios before 8 has no system picker: the sheet of the app lists the downloads folder (a certificate fetched by a page lands there), the storage of
// the device where the process may read it, and the system picker where there is one
- (void)pickFromSheet {
    NSString *accept = @".crt,.cer,.pem,.der,.p7b";
    if (![YZFilePicker hasSourceForAccept:accept]) {
        [self say:YZT(@"Выбирать нечего: скачайте файл сертификата в Yozora, он появится в «Загрузках», или вставьте текст из буфера обмена")];
        return;
    }
    _picking = YES;
    __block YZCertificatesController *me = self;
    YZFilePicker *picker = [[[YZFilePicker alloc] initWithHost:self accept:accept multiple:NO bottomInset:0 completion:^(NSArray *paths) {
        me->_picking = NO;
        if (![paths count])
            return;
        NSString *path = [paths objectAtIndex:0];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        if ([[attributes objectForKey:NSFileSize] unsignedLongLongValue] > YZCertificateFileLimit) {
            [me say:YZT(@"Файл слишком большой для сертификата")];
            return;
        }
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data)
            [me takeData:data];
        else
            [me say:YZT(@"Файл не удалось прочитать")];
    }] autorelease];
    [picker present];
}

// UIDocumentPickerViewController came with ios 8, looked up at run time, the armv7 sdk has none
- (void)addPressed {
    if (_picking)
        return;
    Class pickerClass = NSClassFromString(@"UIDocumentPickerViewController");
    SEL initializer = NSSelectorFromString(@"initWithDocumentTypes:inMode:");
    id picker = [pickerClass alloc];
    if (!pickerClass || ![picker respondsToSelector:initializer]) {
        [picker release];
        [self pickFromSheet];
        return;
    }
    // the import mode copies the file into the app, so it can be read after the picker is gone
    picker = ((id (*)(id, SEL, NSArray *, NSInteger))(void *)objc_msgSend)(picker, initializer, [NSArray arrayWithObject:@"public.item"], 0);
    [picker setValue:self forKey:@"delegate"];
    _picking = YES;
    [self presentViewController:[picker autorelease] animated:YES completion:nil];
}

- (void)documentPicker:(id)picker didPickDocumentsAtURLs:(NSArray *)urls {
    (void)picker;
    _picking = NO;
    NSURL *url = [urls count] ? [urls objectAtIndex:0] : nil;
    NSDictionary *attributes = [url isFileURL] ? [[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:NULL] : nil;
    NSData *data = [url isFileURL] && [[attributes objectForKey:NSFileSize] unsignedLongLongValue] <= YZCertificateFileLimit ? [NSData dataWithContentsOfFile:[url path]] : nil;
    // the picker closes itself, the answer waits for it
    [self performSelector:@selector(takeFileData:) withObject:data ? data : (id)[NSNull null] afterDelay:0.4];
}

- (void)takeFileData:(id)data {
    if ([data isKindOfClass:[NSData class]])
        [self takeData:data];
    else
        [self say:YZT(@"Файл не удалось прочитать")];
}

// the single selection of ios 8 to 10
- (void)documentPicker:(id)picker didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:picker didPickDocumentsAtURLs:url ? [NSArray arrayWithObject:url] : nil];
}

- (void)documentPickerWasCancelled:(id)picker {
    (void)picker;
    _picking = NO;
}

#pragma mark rows

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return (NSInteger)[_entries count]; }

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path { return YZCertificatesRowHeight; }

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:YZCertificatesRowIdentifier];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:YZCertificatesRowIdentifier] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.detailTextLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.font = [YZTheme systemFontOfSize:15];
        cell.detailTextLabel.font = [YZTheme systemFontOfSize:12];
    }
    NSUInteger index = (NSUInteger)path.row;
    if (index < [_entries count]) {
        NSDictionary *entry = [_entries objectAtIndex:index];
        cell.textLabel.text = [entry objectForKey:@"name"];
        cell.textLabel.textColor = [YZTheme textColor];
        cell.detailTextLabel.textColor = [YZTheme subtleTextColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"SHA-1 %@", [entry objectForKey:@"print"]];
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path { return YES; }

- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path { return UITableViewCellEditingStyleDelete; }

- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete || (NSUInteger)path.row >= [_entries count])
        return;
    [YZCertificates removeEntryNamed:[[_entries objectAtIndex:(NSUInteger)path.row] objectForKey:@"file"]];
    [self reload];
}

@end
