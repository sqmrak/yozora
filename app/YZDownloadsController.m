#import "YZDownloadsController.h"
#import "YZCrash.h"
#import "YZCompat.h"
#import "YZClassic.h"
#import "YZControls.h"
#import "YZDialog.h"
#import "YZStrings.h"
#import "YZTheme.h"
#import "YZWaveSeekBar.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include "yozora_core.h"
#include "yozora_transfer.h"

static NSString *YZSizeText(long long bytes) {
    char text[32];
    yozora_transfer_size_text(bytes, text, sizeof text);
    return [NSString stringWithUTF8String:text];
}

// "2 min", "1 h 5 min", "40 s": the two largest units of the time left
static NSString *YZDurationText(long long seconds) {
    if (seconds < 60)
        return [NSString stringWithFormat:@"%lld %@", seconds < 1 ? 1LL : seconds, YZT(@"с")];
    if (seconds < 3600)
        return [NSString stringWithFormat:@"%lld %@", (seconds + 30) / 60, YZT(@"мин")];
    long long minutes = (seconds + 30) / 60;
    return [NSString stringWithFormat:@"%lld %@ %lld %@", minutes / 60, YZT(@"ч"), minutes % 60, YZT(@"мин")];
}

static const CGFloat YZDownloadCardRadius = 22;
static const CGFloat YZDownloadActiveHeight = 112;
static const CGFloat YZDownloadPlainHeight = 76;
static const CGFloat YZDownloadEmptyHeight = 220;

// a download card: a tonal disc (glyph while running, extension when finished), name, a supporting line and,
// while it runs, a wave bar and a cancel button
@interface YZDownloadCell : UITableViewCell {
@public
    UIView *card;
    UIView *disc;
    UIImageView *icon;
    UILabel *tag;
    UILabel *title;
    UILabel *detail;
    YZWaveSeekBar *bar;
    YZStateButton *cancel;
    YZStateButton *pause;
    BOOL active;
    BOOL empty;
}
@end

@implementation YZDownloadCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    (void)style;
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    card = [[UIView alloc] initWithFrame:CGRectZero];
    card.layer.cornerRadius = [YZTheme isClassic] ? [YZTheme cardRadius] : YZDownloadCardRadius;
    // the card of the classic design has an outline of its own
    card.layer.borderWidth = [YZTheme isClassic] ? 1 : 0;
    card.layer.borderColor = [[YZTheme separatorColor] CGColor];
    [self.contentView addSubview:card];
    disc = [[UIView alloc] initWithFrame:CGRectZero];
    [card addSubview:disc];
    icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [disc addSubview:icon];
    tag = [[UILabel alloc] initWithFrame:CGRectZero];
    tag.font = [YZTheme boldSystemFontOfSize:12];
    tag.textAlignment = YZTextAlignmentCenter;
    tag.backgroundColor = [UIColor clearColor];
    YZShrinkToFit(tag);
    [disc addSubview:tag];
    title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [YZTheme systemFontOfSize:16];
    title.backgroundColor = [UIColor clearColor];
    YZShrinkToFit(title);
    [card addSubview:title];
    detail = [[UILabel alloc] initWithFrame:CGRectZero];
    detail.font = [YZTheme systemFontOfSize:13];
    detail.backgroundColor = [UIColor clearColor];
    YZShrinkToFit(detail);
    [card addSubview:detail];
    bar = [[YZWaveSeekBar alloc] initWithFrame:CGRectZero];
    // the bar only shows the progress, it has no handle to drag and the spoken value is read from the row
    bar.userInteractionEnabled = NO;
    bar.isAccessibilityElement = NO;
    [card addSubview:bar];
    cancel = [[YZStateButton alloc] initWithFrame:CGRectZero];
    cancel.pillSize = CGSizeMake(40, 40);
    cancel.accessibilityLabel = YZT(@"Отменить загрузку");
    [card addSubview:cancel];
    pause = [[YZStateButton alloc] initWithFrame:CGRectZero];
    pause.pillSize = CGSizeMake(40, 40);
    [card addSubview:pause];
    return self;
}

- (void)dealloc {
    [card release];
    [disc release];
    [icon release];
    [tag release];
    [title release];
    [detail release];
    [bar release];
    [cancel release];
    [pause release];
    [super dealloc];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [cancel removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [pause removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    if (empty)
        return;
    card.backgroundColor = highlighted ? [YZTheme pressedColor] : [YZTheme cardColor];
    if (highlighted)
        [YZTheme animateFeedbackOfView:disc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, height = self.contentView.bounds.size.height;
    card.frame = CGRectMake(16, 4, MAX((CGFloat)0, width - 32), MAX((CGFloat)0, height - 8));
    CGFloat cw = card.bounds.size.width, ch = card.bounds.size.height;
    if (empty) {
        CGFloat side = 72;
        disc.bounds = CGRectMake(0, 0, side, side);
        disc.center = CGPointMake(cw / 2, ch / 2 - 34);
        disc.layer.cornerRadius = [YZTheme isClassic] ? 16 : side / 2;
        icon.frame = CGRectInset(disc.bounds, 20, 20);
        title.frame = CGRectMake(16, ch / 2 + 14, cw - 32, 22);
        detail.frame = CGRectMake(16, ch / 2 + 38, cw - 32, 18);
        title.textAlignment = YZTextAlignmentCenter;
        detail.textAlignment = YZTextAlignmentCenter;
        return;
    }
    title.textAlignment = YZTextAlignmentLeft;
    detail.textAlignment = YZTextAlignmentLeft;
    CGFloat side = 44;
    CGFloat top = active ? 16 : (ch - side) / 2;
    disc.bounds = CGRectMake(0, 0, side, side);
    disc.center = CGPointMake(16 + side / 2, top + side / 2);
    // a rounded square tile in the classic design, a disc in the modern one
    disc.layer.cornerRadius = [YZTheme isClassic] ? 10 : side / 2;
    icon.frame = CGRectInset(disc.bounds, 10, 10);
    tag.frame = CGRectInset(disc.bounds, 3, 0);
    CGFloat left = 16 + side + 14;
    CGFloat right = active ? 100 : 16;
    CGFloat textTop = active ? top + 2 : (ch - 40) / 2;
    title.frame = CGRectMake(left, textTop, MAX((CGFloat)0, cw - left - right), 20);
    detail.frame = CGRectMake(left, textTop + 22, MAX((CGFloat)0, cw - left - right), 18);
    cancel.hidden = !active;
    pause.hidden = !active;
    bar.hidden = !active;
    cancel.frame = CGRectMake(cw - 52, 10, 44, 44);
    pause.frame = CGRectMake(cw - 96, 10, 44, 44);
    bar.frame = CGRectMake(10, ch - YZWaveSeekBarHeight - 10, MAX((CGFloat)0, cw - 20), YZWaveSeekBarHeight);
}
@end

@implementation YZDownloadsController
@synthesize downloadsDelegate = _downloadsDelegate;

+ (NSString *)directory {
    NSArray *roots = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = [roots count] ? [roots objectAtIndex:0] : NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:@"Downloads"];
}

- (id)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self)
        return nil;
    _rows = [[NSMutableArray alloc] init];
    _signature = [[NSArray alloc] init];
    _samples = [[NSMutableDictionary alloc] init];
    self.title = YZT(@"Загрузки");
    return self;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    [_timer invalidate];
    _preview.delegate = nil;
    [_preview release];
    [_rows release];
    [_signature release];
    [_samples release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // the large title above the rows is the title of the screen, the bar keeps only its buttons
    self.navigationItem.titleView = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    self.navigationItem.rightBarButtonItem = [YZTheme barButtonItemWithTitle:YZT(@"Готово") bold:YES target:self action:@selector(finish)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:[NSString stringWithFormat:@"screen %@", NSStringFromClass([self class])]];
    self.tableView.backgroundColor = [YZTheme screenColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.tableHeaderView = [self headerForWidth:self.tableView.bounds.size.width];
    [YZTheme styleNavigationBar:self.navigationController.navigationBar];
    [self reload];
    // the numbers of a running download change under the list
    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(reload) userInfo:nil repeats:YES];
}

// the title of the screen (not in the classic design, which has the bar for it) and under it the address of the folder the files are in, a
// link that opens it
- (UIView *)headerForWidth:(CGFloat)width {
    UIView *title = [YZTheme isClassic] ? nil : [YZTheme titleHeaderWithText:self.title width:width];
    CGFloat top = title ? title.frame.size.height - 14 : 10;
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, width, top + 44)] autorelease];
    header.backgroundColor = title ? [YZTheme surfaceColor] : [UIColor clearColor];
    if (title)
        [header addSubview:title];
    UIButton *link = [UIButton buttonWithType:UIButtonTypeCustom];
    link.frame = CGRectMake(28, top, MAX((CGFloat)0, width - 56), 34);
    link.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    link.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    link.titleLabel.font = [YZTheme systemFontOfSize:15];
    link.titleLabel.lineBreakMode = YZLineBreakTailTruncation;
    [link setTitle:YZT(@"Папка с файлами: Yozora › Downloads") forState:UIControlStateNormal];
    [link setTitleColor:[YZTheme isClassic] ? [YZClassic inkColor] : [YZTheme accentColor] forState:UIControlStateNormal];
    [link setTitleColor:[YZTheme subtleTextColor] forState:UIControlStateHighlighted];
    link.accessibilityLabel = YZT(@"Открыть папку с файлами");
    [link addTarget:self action:@selector(openFolderPressed) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:link];
    return header;
}

// the Files app opens a folder of this app by its path (ios 13 and later, and only because Info.plist shares Documents). a system without the
// scheme, or one that refuses, is told where the files are in words, so nobody has to look for them
- (void)openFolderPressed {
    NSString *directory = [YZDownloadsController directory];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *escaped = [directory stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = escaped ? [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:escaped]] : nil;
    UIApplication *application = [UIApplication sharedApplication];
    SEL modern = NSSelectorFromString(@"openURL:options:completionHandler:");
    if (!url || ![application respondsToSelector:modern]) {
        [self showFolderLocation:directory];
        return;
    }
    void (^done)(BOOL) = ^(BOOL opened) {
        if (!opened)
            [self showFolderLocation:directory];
    };
    void (*open)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) = (void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))(void *)objc_msgSend;
    open(application, modern, url, [NSDictionary dictionary], [[done copy] autorelease]);
}

- (void)showFolderLocation:(NSString *)directory {
    YZDialog *dialog = [YZDialog dialogWithTitle:YZT(@"Папка с файлами") message:[NSString stringWithFormat:@"%@\n\n%@", YZT(@"Файлы лежат в папке Downloads внутри Yozora: приложение «Файлы», На iPhone, Yozora, Downloads. Полный путь:"), directory]
                                     cancelTitle:nil confirmTitle:YZT(@"Закрыть") destructive:NO handler:^(NSInteger index, NSArray *texts) {
        (void)index;
        (void)texts;
    }];
    [dialog showInView:self.navigationController ? self.navigationController.view : self.view];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)finish {
    [_downloadsDelegate downloadsControllerDidFinish:self];
}

static BOOL YZRowIsActive(NSDictionary *row) {
    int state = [[row objectForKey:@"state"] intValue];
    return state == YOZORA_DOWNLOAD_QUEUED || state == YOZORA_DOWNLOAD_RUNNING || state == YOZORA_DOWNLOAD_PAUSED;
}

// rows keep their cells while only numbers change, a cell is rebuilt when a row comes, goes or changes state,
// which also changes its height
- (NSArray *)signatureOfRows:(NSArray *)rows {
    NSMutableArray *signature = [NSMutableArray arrayWithCapacity:[rows count]];
    for (NSDictionary *row in rows)
        [signature addObject:[NSString stringWithFormat:@"%@:%@:%@", [row objectForKey:@"id"], [row objectForKey:@"state"], [row objectForKey:@"path"]]];
    return signature;
}

// speed from the bytes since the last pass, smoothed so the figure does not jump every half second
- (double)speedOfDownload:(unsigned)identifier received:(long long)received now:(CFTimeInterval)now {
    NSNumber *key = [NSNumber numberWithUnsignedInt:identifier];
    NSDictionary *last = [_samples objectForKey:key];
    double speed = 0;
    if (last) {
        CFTimeInterval before = [[last objectForKey:@"time"] doubleValue];
        long long bytes = [[last objectForKey:@"received"] longLongValue];
        speed = [[last objectForKey:@"speed"] doubleValue];
        if (now - before >= 0.4) {
            speed = yozora_transfer_speed(speed, received - bytes, now - before);
        } else {
            return speed;
        }
    }
    [_samples setObject:[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithDouble:now], @"time", [NSNumber numberWithLongLong:received], @"received",
        [NSNumber numberWithDouble:speed], @"speed", nil] forKey:key];
    return speed;
}

// the downloads of this run first, then the files that earlier runs left in the folder, newest first
- (void)reload {
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet *known = [NSMutableSet set];
    NSMutableSet *running = [NSMutableSet set];
    CFTimeInterval now = CACurrentMediaTime();
    yozora_download list[50];
    int count = yozora_downloads_list(list, 50);
    for (int i = 0; i < count; ++i) {
        NSString *path = list[i].path[0] ? [NSString stringWithUTF8String:list[i].path] : nil;
        if (path)
            [known addObject:path];
        double speed = 0;
        if (list[i].state == YOZORA_DOWNLOAD_RUNNING) {
            speed = [self speedOfDownload:list[i].id received:list[i].received now:now];
            [running addObject:[NSNumber numberWithUnsignedInt:list[i].id]];
        }
        [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithUnsignedInt:list[i].id], @"id",
            [NSNumber numberWithInt:list[i].state], @"state",
            [NSNumber numberWithLongLong:list[i].received], @"received",
            [NSNumber numberWithLongLong:list[i].total], @"total",
            [NSNumber numberWithDouble:speed], @"speed",
            [NSString stringWithUTF8String:list[i].name], @"name",
            path ? path : @"", @"path",
            [NSString stringWithUTF8String:list[i].error], @"error", nil]];
    }
    // a download that ended or was forgotten takes its sample with it, a restart starts the estimate over
    for (NSNumber *key in [_samples allKeys]) {
        if (![running containsObject:key])
            [_samples removeObjectForKey:key];
    }
    NSString *directory = [YZDownloadsController directory];
    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableArray *older = [NSMutableArray array];
    for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([name hasSuffix:@".part"] || [name hasPrefix:@"."] || [known containsObject:path])
            continue;
        NSDictionary *attributes = [files attributesOfItemAtPath:path error:NULL];
        [older addObject:[NSDictionary dictionaryWithObjectsAndKeys:name, @"name", path, @"path",
                          [NSNumber numberWithInt:YOZORA_DOWNLOAD_DONE], @"state",
                          [attributes objectForKey:NSFileSize] ? [attributes objectForKey:NSFileSize] : [NSNumber numberWithInt:0], @"received",
                          [attributes objectForKey:NSFileModificationDate] ? [attributes objectForKey:NSFileModificationDate] : [NSDate distantPast], @"date", nil]];
    }
    [older sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [[b objectForKey:@"date"] compare:[a objectForKey:@"date"]]; }];
    [rows addObjectsFromArray:older];
    // nothing changed on screen while the numbers are the same, a scrolling list is not rebuilt for nothing
    if ([rows isEqualToArray:_rows])
        return;
    NSArray *signature = [self signatureOfRows:rows];
    BOOL sameCells = [signature isEqualToArray:_signature];
    [_rows setArray:rows];
    [_signature release];
    _signature = [signature retain];
    if (!sameCells || ![self isViewLoaded]) {
        [self.tableView reloadData];
        return;
    }
    // only numbers moved: the visible cards take them in place and the bar glides to its new end
    for (NSIndexPath *path in [self.tableView indexPathsForVisibleRows]) {
        YZDownloadCell *cell = (YZDownloadCell *)[self.tableView cellForRowAtIndexPath:path];
        if ([cell isKindOfClass:[YZDownloadCell class]] && (NSUInteger)path.row < [_rows count])
            [self configureCell:cell row:[_rows objectAtIndex:path.row] gliding:YES];
    }
}

- (void)configureEmptyCell:(YZDownloadCell *)cell {
    cell->empty = YES;
    cell->active = NO;
    cell->card.backgroundColor = [YZTheme cardColor];
    cell->disc.backgroundColor = [YZTheme stateColor];
    cell->icon.image = [YZTheme icon:YZIconDownload size:32 color:[YZTheme accentColor]];
    cell->tag.text = nil;
    cell->title.text = YZT(@"Загрузок нет");
    cell->title.font = [YZTheme systemFontOfSize:18];
    cell->title.textColor = [YZTheme textColor];
    cell->detail.text = YZT(@"Скачанные файлы появятся здесь");
    cell->detail.textColor = [YZTheme subtleTextColor];
    cell->bar.hidden = YES;
    cell->cancel.hidden = YES;
    cell->pause.hidden = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    [cell setNeedsLayout];
}

// the capital extension of a file, "PDF" or "ZIP", for the disc of a finished download; empty when the name has none that fits
static NSString *YZExtensionTag(NSString *name) {
    NSString *extension = [[name pathExtension] uppercaseString];
    return [extension length] && [extension length] <= 4 ? extension : nil;
}

- (void)configureCell:(YZDownloadCell *)cell row:(NSDictionary *)row gliding:(BOOL)gliding {
    int state = [[row objectForKey:@"state"] intValue];
    long long received = [[row objectForKey:@"received"] longLongValue];
    long long total = [[row objectForKey:@"total"] longLongValue];
    double speed = [[row objectForKey:@"speed"] doubleValue];
    BOOL active = YZRowIsActive(row);
    BOOL failed = state == YOZORA_DOWNLOAD_FAILED;
    cell->empty = NO;
    cell->active = active;
    cell->card.backgroundColor = [YZTheme cardColor];
    cell->title.font = [YZTheme systemFontOfSize:16];
    cell->title.text = [row objectForKey:@"name"];
    cell->title.textColor = [YZTheme textColor];
    cell->detail.textColor = [YZTheme subtleTextColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSString *tag = state == YOZORA_DOWNLOAD_DONE ? YZExtensionTag([row objectForKey:@"name"]) : nil;
    cell->disc.backgroundColor = failed ? [YZTheme errorContainerColor] : [YZTheme stateColor];
    cell->tag.text = tag;
    cell->tag.textColor = [YZTheme accentColor];
    cell->icon.hidden = tag != nil;
    if (failed)
        cell->icon.image = [YZTheme icon:YZIconClose size:24 color:[YZTheme onErrorContainerColor]];
    else if (!tag)
        cell->icon.image = [YZTheme icon:YZIconDownload size:24 color:[YZTheme accentColor]];
    NSString *line;
    switch (state) {
    case YOZORA_DOWNLOAD_QUEUED:
        line = YZT(@"Ждёт очереди");
        break;
    case YOZORA_DOWNLOAD_PAUSED:
        line = total > 0 ? [NSString stringWithFormat:@"%@ · %@", YZT(@"Приостановлено"), [NSString stringWithFormat:YZT(@"%@ из %@"), YZSizeText(received), YZSizeText(total)]]
                         : [NSString stringWithFormat:@"%@ · %@", YZT(@"Приостановлено"), YZSizeText(received)];
        break;
    case YOZORA_DOWNLOAD_RUNNING: {
        NSString *size = total > 0 ? [NSString stringWithFormat:YZT(@"%@ из %@"), YZSizeText(received), YZSizeText(total)] : YZSizeText(received);
        NSMutableString *text = [NSMutableString stringWithString:size];
        if (speed > 0)
            [text appendFormat:@" · %@/s", YZSizeText((long long)speed)];
        long long left = yozora_transfer_remaining_seconds(received, total, speed);
        if (left >= 0)
            [text appendFormat:@" · %@", [NSString stringWithFormat:YZT(@"ещё %@"), YZDurationText(left)]];
        line = text;
        break;
    }
    case YOZORA_DOWNLOAD_FAILED:
        line = [NSString stringWithFormat:@"%@: %@", YZT(@"Не загружено"), [row objectForKey:@"error"]];
        cell->detail.textColor = [YZTheme errorColor];
        break;
    case YOZORA_DOWNLOAD_CANCELLED:
        line = YZT(@"Отменено");
        break;
    default:
        line = YZSizeText(received);
    }
    cell->detail.text = line;
    if (active) {
        double fraction = (state == YOZORA_DOWNLOAD_RUNNING || state == YOZORA_DOWNLOAD_PAUSED) ? yozora_transfer_fraction(received, total) : 0;
        cell->bar.playedColor = [YZTheme accentColor];
        cell->bar.restColor = [[YZTheme accentColor] colorWithAlphaComponent:0.24f];
        cell->bar.waving = state == YOZORA_DOWNLOAD_RUNNING;
        // an unknown total has no end to draw: the wave runs on an empty track and the line above carries the byte count
        [cell->bar setValue:fraction < 0 ? 0 : (float)fraction gliding:gliding];
        // a paused download offers to go on, one that is queued or running offers to stop
        BOOL paused = state == YOZORA_DOWNLOAD_PAUSED;
        [cell->pause setImage:[YZTheme icon:paused ? YZIconPlay : YZIconPause size:22 color:[YZTheme textColor]] forState:UIControlStateNormal];
        cell->pause.accessibilityLabel = paused ? YZT(@"Продолжить загрузку") : YZT(@"Приостановить загрузку");
        [cell->pause removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell->pause addTarget:self action:@selector(pausePressed:) forControlEvents:UIControlEventTouchUpInside];
        cell->pause.tag = [[row objectForKey:@"id"] intValue];
        [cell->cancel setImage:[YZTheme icon:YZIconClose size:22 color:[YZTheme textColor]] forState:UIControlStateNormal];
        [cell->cancel removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell->cancel addTarget:self action:@selector(cancelPressed:) forControlEvents:UIControlEventTouchUpInside];
        cell->cancel.tag = [[row objectForKey:@"id"] intValue];
    }
    cell->bar.hidden = !active;
    cell->cancel.hidden = !active;
    cell->pause.hidden = !active;
    [cell setNeedsLayout];
}

- (void)pausePressed:(UIButton *)button {
    unsigned identifier = (unsigned)button.tag;
    for (NSDictionary *row in _rows) {
        if ([[row objectForKey:@"id"] unsignedIntValue] != identifier)
            continue;
        if ([[row objectForKey:@"state"] intValue] == YOZORA_DOWNLOAD_PAUSED)
            yozora_download_resume(identifier);
        else
            yozora_download_pause(identifier);
        break;
    }
    [self reload];
}

- (void)cancelPressed:(UIButton *)button {
    // the file is cleaned up by the manager, the row stays until it says it is cancelled
    yozora_download_cancel((unsigned)button.tag);
    [self reload];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table;
    (void)section;
    return [_rows count] ? (NSInteger)[_rows count] : 1;
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    if (![_rows count])
        return YZDownloadEmptyHeight;
    return YZRowIsActive([_rows objectAtIndex:path.row]) ? YZDownloadActiveHeight : YZDownloadPlainHeight;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *identifier = @"download";
    YZDownloadCell *cell = (YZDownloadCell *)[table dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[[YZDownloadCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier] autorelease];
    if (![_rows count])
        [self configureEmptyCell:cell];
    else
        [self configureCell:cell row:[_rows objectAtIndex:path.row] gliding:NO];
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (![_rows count])
        return;
    NSDictionary *row = [_rows objectAtIndex:path.row];
    NSString *file = [row objectForKey:@"path"];
    if ([[row objectForKey:@"state"] intValue] != YOZORA_DOWNLOAD_DONE || ![file length])
        return;
    [_preview release];
    _preview = [[UIDocumentInteractionController interactionControllerWithURL:[NSURL fileURLWithPath:file]] retain];
    _preview.delegate = self;
    // the viewer of the system, or the sheet that lists the apps that open the file when it has none
    if (![_preview presentPreviewAnimated:YES])
        [_preview presentOpenInMenuFromRect:[table rectForRowAtIndexPath:path] inView:table animated:YES];
}

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller {
    (void)controller;
    return self;
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    // a running download is stopped by its own button, a swipe takes away what has ended
    return [_rows count] > 0 && !YZRowIsActive([_rows objectAtIndex:path.row]);
}

- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete || ![_rows count])
        return;
    NSDictionary *row = [_rows objectAtIndex:path.row];
    int state = [[row objectForKey:@"state"] intValue];
    unsigned identifier = [[row objectForKey:@"id"] unsignedIntValue];
    NSString *file = [row objectForKey:@"path"];
    if (YZRowIsActive(row))
        return;
    if (identifier)
        yozora_download_forget(identifier);
    if (state == YOZORA_DOWNLOAD_DONE && [file length])
        [[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
    [_rows removeObjectAtIndex:path.row];
    [_signature release];
    _signature = [[self signatureOfRows:_rows] retain];
    if ([_rows count])
        [table deleteRowsAtIndexPaths:[NSArray arrayWithObject:path] withRowAnimation:UITableViewRowAnimationLeft];
    else
        [table reloadData];
}

@end
