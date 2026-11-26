#import "YZPasswordsController.h"
#import "YZCompat.h"
#import "YZCrash.h"
#import "YZFavicons.h"
#import "YZPasswords.h"
#import "YZStrings.h"
#import "YZTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <dlfcn.h>

static const CGFloat YZPasswordRowHeight = 76;
static const CGFloat YZPasswordNeverRowHeight = 52;
static const CGFloat YZPasswordSide = 12;
static NSString *const YZPasswordRowIdentifier = @"yozora.passwords.row";
static NSString *const YZPasswordNeverIdentifier = @"yozora.passwords.never";
// LAPolicyDeviceOwnerAuthentication of ios 9: the finger or the face, and the passcode when they fail
static const NSInteger YZOwnerPolicy = 2;

static UIFont *YZPasswordFont(CGFloat size) {
    UIFont *font = [UIFont fontWithName:@"JetBrainsMono-Regular" size:size];
    return font ? font : [UIFont fontWithName:@"Courier" size:size];
}

static NSString *YZAccountKey(YZPasswordAccount *account) {
    return [NSString stringWithFormat:@"%@\n%@", account.site, account.user];
}

// a login as a card: the mark of the site on its tile, the site, and the login with the password under it
@interface YZPasswordCell : UITableViewCell {
@public
    UIView *card;
    UILabel *letter;
    UIImageView *icon;
    UILabel *site;
    UILabel *user;
    UILabel *secret;
    UIImageView *chevron;
}
@end

@implementation YZPasswordCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];
    if (!self)
        return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    card = [[UIView alloc] initWithFrame:CGRectZero];
    card.userInteractionEnabled = NO;
    [self.contentView addSubview:card];
    letter = [[UILabel alloc] initWithFrame:CGRectZero];
    letter.textAlignment = YZTextAlignmentCenter;
    letter.font = [YZTheme boldSystemFontOfSize:20];
    letter.textColor = [UIColor whiteColor];
    letter.layer.masksToBounds = YES;
    [card addSubview:letter];
    icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:icon];
    site = [[UILabel alloc] initWithFrame:CGRectZero];
    site.backgroundColor = [UIColor clearColor];
    site.font = [YZTheme boldSystemFontOfSize:16];
    site.lineBreakMode = YZLineBreakTailTruncation;
    [card addSubview:site];
    user = [[UILabel alloc] initWithFrame:CGRectZero];
    user.backgroundColor = [UIColor clearColor];
    user.font = [YZTheme systemFontOfSize:13];
    [card addSubview:user];
    secret = [[UILabel alloc] initWithFrame:CGRectZero];
    secret.backgroundColor = [UIColor clearColor];
    secret.font = YZPasswordFont(13);
    [card addSubview:secret];
    chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
    chevron.contentMode = UIViewContentModeCenter;
    [card addSubview:chevron];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    card.backgroundColor = highlighted ? [YZTheme pressedColor] : [YZTheme cardColor];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, height = self.contentView.bounds.size.height;
    card.frame = CGRectMake(YZPasswordSide, 4, MAX((CGFloat)0, width - 2 * YZPasswordSide), height - 8);
    CGFloat cw = card.bounds.size.width, ch = card.bounds.size.height;
    letter.frame = CGRectMake(14, (ch - 44) / 2, 44, 44);
    icon.frame = CGRectInset(letter.frame, 8, 8);
    chevron.frame = CGRectMake(cw - 34, 0, 24, ch);
    CGFloat textLeft = 14 + 44 + 14, textWidth = MAX((CGFloat)0, cw - textLeft - 40);
    site.frame = CGRectMake(textLeft, ch / 2 - 26, textWidth, 20);
    user.frame = CGRectMake(textLeft, ch / 2 - 5, textWidth, 16);
    secret.frame = CGRectMake(textLeft, ch / 2 + 11, textWidth, 16);
}

- (void)dealloc {
    [card release];
    [letter release];
    [icon release];
    [site release];
    [user release];
    [secret release];
    [chevron release];
    [super dealloc];
}
@end

@implementation YZPasswordsController

+ (void)unlockThen:(void (^)(BOOL unlocked))done {
    void (^finish)(BOOL) = [[done copy] autorelease];
    // LocalAuthentication came with ios 8 and is not linked, so the armv7 slice keeps running on ios 5
    Class contextClass = NSClassFromString(@"LAContext");
    if (!contextClass && dlopen("/System/Library/Frameworks/LocalAuthentication.framework/LocalAuthentication", RTLD_LAZY))
        contextClass = NSClassFromString(@"LAContext");
    SEL canEvaluate = NSSelectorFromString(@"canEvaluatePolicy:error:"), evaluate = NSSelectorFromString(@"evaluatePolicy:localizedReason:reply:");
    id context = contextClass ? [[[contextClass alloc] init] autorelease] : nil;
    if (!context || ![context respondsToSelector:canEvaluate] || ![context respondsToSelector:evaluate]) {
        finish(YES);
        return;
    }
    // no passcode on the device leaves nothing to check, the system says so by refusing the policy
    NSError *error = nil;
    if (!((BOOL (*)(id, SEL, NSInteger, NSError **))objc_msgSend)(context, canEvaluate, YZOwnerPolicy, &error)) {
        finish(YES);
        return;
    }
    void (^reply)(BOOL, NSError *) = ^(BOOL success, NSError *failure) {
        (void)failure;
        dispatch_async(dispatch_get_main_queue(), ^{ finish(success); });
    };
    ((void (*)(id, SEL, NSInteger, NSString *, void (^)(BOOL, NSError *)))objc_msgSend)(context, evaluate, YZOwnerPolicy, YZT(@"Показать сохранённые пароли"), reply);
}

- (id)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self)
        return nil;
    _shown = [[NSMutableArray alloc] init];
    _revealed = [[NSMutableSet alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(iconLoaded:) name:YZFaviconDidLoadNotification object:nil];
    // a password shown in the open is hidden again when the app leaves the screen
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hideRevealed) name:UIApplicationDidEnterBackgroundNotification object:nil];
    return self;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _table.delegate = nil;
    _table.dataSource = nil;
    _search.delegate = nil;
    // a sheet closed here would answer into a controller that is going away
    _sheet.onCancel = nil;
    [_sheet dismissAnimated:NO];
    [_sheet release];
    [_dialog dismissSilently];
    [_dialog release];
    [_table release];
    [_header release];
    [_search release];
    [_count release];
    [_empty release];
    [_emptyDisc release];
    [_emptyIcon release];
    [_emptyText release];
    [_fill removeFromSuperview];
    [_fill release];
    [_accounts release];
    [_shown release];
    [_revealed release];
    [_never release];
    [super dealloc];
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    self.view = root;
    [root release];
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    _header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 112)];
    _search = [[UITextField alloc] initWithFrame:CGRectZero];
    _search.delegate = self;
    _search.borderStyle = UITextBorderStyleNone;
    _search.clearButtonMode = UITextFieldViewModeWhileEditing;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.returnKeyType = UIReturnKeyDone;
    _search.leftViewMode = UITextFieldViewModeAlways;
    _search.leftView = [[[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 40, 24)] autorelease];
    _search.leftView.contentMode = UIViewContentModeCenter;
    _search.font = [YZTheme systemFontOfSize:16];
    _search.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    [_search addTarget:self action:@selector(searchChanged) forControlEvents:UIControlEventEditingChanged];
    [_header addSubview:_search];
    _count = [[UILabel alloc] initWithFrame:CGRectZero];
    _count.backgroundColor = [UIColor clearColor];
    _count.font = [YZTheme systemFontOfSize:13];
    [_header addSubview:_count];
    _table.tableHeaderView = _header;
    _empty = [[UIView alloc] initWithFrame:CGRectZero];
    _empty.userInteractionEnabled = NO;
    _emptyDisc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 88, 88)];
    _emptyDisc.layer.cornerRadius = 44;
    [_empty addSubview:_emptyDisc];
    _emptyIcon = [[UIImageView alloc] initWithFrame:_emptyDisc.bounds];
    _emptyIcon.contentMode = UIViewContentModeCenter;
    [_emptyDisc addSubview:_emptyIcon];
    _emptyText = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyText.backgroundColor = [UIColor clearColor];
    _emptyText.numberOfLines = 0;
    _emptyText.textAlignment = YZTextAlignmentCenter;
    _emptyText.font = [YZTheme systemFontOfSize:15];
    [_empty addSubview:_emptyText];
    [_table addSubview:_empty];
}

- (void)restyle {
    self.view.backgroundColor = [YZTheme screenColor];
    YZPaintBehindScreens(self.navigationController);
    [YZTheme styleTransparentNavigationBar:self.navigationController.navigationBar];
    if (!_fill)
        _fill = [[YZBarFill alloc] initWithFrame:CGRectZero];
    [_fill applyTheme];
    YZInstallBarTitle(self, YZT(@"Пароли"), self, @selector(back));
    _search.backgroundColor = [YZTheme addressFieldColor];
    _search.textColor = [YZTheme fieldInkColor];
    _search.layer.cornerRadius = [YZTheme isClassic] || [YZTheme isFlat] ? 10 : 22;
    _search.placeholder = YZT(@"Поиск по сайтам и логинам");
    ((UIImageView *)_search.leftView).image = [YZTheme icon:YZIconSearch size:20 color:[YZTheme fieldHintColor]];
    _count.textColor = [YZTheme subtleTextColor];
    _emptyDisc.backgroundColor = [YZTheme stateColor];
    _emptyIcon.image = [YZTheme icon:YZIconLock size:40 color:[YZTheme accentColor]];
    _emptyText.textColor = [YZTheme subtleTextColor];
    [_table reloadData];
}

- (void)back { [self.navigationController popViewControllerAnimated:YES]; }

- (void)iconLoaded:(NSNotification *)note {
    (void)note;
    [_table reloadData];
}

- (void)hideRevealed {
    [_revealed removeAllObjects];
    [_table reloadData];
}

// the keychain is read again on every visit, a password saved from a page meanwhile is in the list
- (void)reload {
    NSString *reason = nil;
    NSArray *accounts = [YZPasswords accountsWithError:&reason];
    if (!accounts) {
        accounts = [NSArray array];
        [self showMessage:[NSString stringWithFormat:YZT(@"Пароли не прочитаны: %@"), reason]];
    }
    [accounts retain];
    [_accounts release];
    _accounts = accounts;
    NSArray *never = [[YZPasswords neverSites] retain];
    [_never release];
    _never = never;
    [self filter];
}

- (void)filter {
    NSString *query = [_search.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [_shown removeAllObjects];
    for (YZPasswordAccount *account in _accounts) {
        if (![query length] || [account.site rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound
            || [account.user rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
            [_shown addObject:account];
    }
    NSUInteger total = [_accounts count];
    if (!total)
        _count.text = nil;
    else if ([query length])
        _count.text = [NSString stringWithFormat:YZT(@"Найдено: %lu из %lu"), (unsigned long)[_shown count], (unsigned long)total];
    else
        _count.text = [NSString stringWithFormat:YZT(@"Сохранено паролей: %lu"), (unsigned long)total];
    _emptyText.text = total ? YZT(@"Ничего не найдено") : YZT(@"Здесь появятся пароли, которые вы сохраните на сайтах. Они хранятся в связке ключей этого устройства.");
    _empty.hidden = [_shown count] > 0;
    [_table reloadData];
    [self.view setNeedsLayout];
}

- (void)searchChanged { [self filter]; }

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:@"screen YZPasswordsController"];
    [self restyle];
    [self reload];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_search resignFirstResponder];
    [self hideRevealed];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat top = [YZTheme barOverlap:self.navigationController.navigationBar];
    YZInstallBarTitle(self, YZT(@"Пароли"), self, @selector(back));
    UIEdgeInsets insets = _table.contentInset;
    if (insets.top != top) {
        insets.top = top;
        _table.contentInset = insets;
        _table.scrollIndicatorInsets = insets;
    }
    [_fill attachToScrollView:_table controller:self];
    _header.frame = CGRectMake(0, 0, width, 84);
    _search.frame = CGRectMake(YZPasswordSide + 4, 8, width - 2 * (YZPasswordSide + 4), 44);
    _count.frame = CGRectMake(YZPasswordSide + 8, 8 + 44 + 8, width - 2 * (YZPasswordSide + 8), 18);
    _table.tableHeaderView = _header;
    CGFloat textWidth = MIN(width - 64, (CGFloat)320);
    CGSize fit = [_emptyText sizeThatFits:CGSizeMake(textWidth, 1000)];
    _empty.frame = CGRectMake(0, 84 + 32, width, 88 + 20 + fit.height);
    _emptyDisc.center = CGPointMake(width / 2, 44);
    _emptyText.frame = CGRectMake((width - textWidth) / 2, 88 + 20, textWidth, fit.height);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [_fill attachToScrollView:scrollView controller:self];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    (void)scrollView;
    [_search resignFirstResponder];
}

#pragma mark rows

// the logins, then the sites said never for while the search is empty
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    (void)table;
    return 2;
}

- (BOOL)showsNever {
    return [_never count] && ![_search.text length];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table;
    if (section == 0)
        return (NSInteger)[_shown count];
    return [self showsNever] ? (NSInteger)[_never count] : 0;
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    return path.section == 0 ? YZPasswordRowHeight : YZPasswordNeverRowHeight;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    (void)table;
    return section == 1 && [self showsNever] ? 44 : 0;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    (void)table;
    if (section != 1 || ![self showsNever])
        return nil;
    UIView *view = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, _table.bounds.size.width, 44)] autorelease];
    view.backgroundColor = [YZTheme screenColor];
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(YZPasswordSide + 8, 18, _table.bounds.size.width - 2 * (YZPasswordSide + 8), 20)] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = [YZTheme boldSystemFontOfSize:13];
    label.textColor = [YZTheme accentColor];
    label.text = YZT(@"Никогда не сохранять");
    [view addSubview:label];
    return view;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 1) {
        UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:YZPasswordNeverIdentifier];
        if (!cell) {
            cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:YZPasswordNeverIdentifier] autorelease];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = [UIColor clearColor];
            cell.textLabel.backgroundColor = [UIColor clearColor];
            cell.textLabel.font = [YZTheme systemFontOfSize:15];
        }
        cell.textLabel.textColor = [YZTheme textColor];
        cell.textLabel.text = (NSUInteger)path.row < [_never count] ? [_never objectAtIndex:(NSUInteger)path.row] : nil;
        return cell;
    }
    YZPasswordCell *cell = (YZPasswordCell *)[table dequeueReusableCellWithIdentifier:YZPasswordRowIdentifier];
    if (!cell)
        cell = [[[YZPasswordCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:YZPasswordRowIdentifier] autorelease];
    if ((NSUInteger)path.row >= [_shown count])
        return cell;
    YZPasswordAccount *account = [_shown objectAtIndex:(NSUInteger)path.row];
    cell->card.backgroundColor = [YZTheme cardColor];
    cell->card.layer.cornerRadius = [YZTheme isClassic] ? 10 : 18;
    // the mark of the site comes from the bundle or the cache of icons, a site without one shows its letter
    NSString *host = [[account.site componentsSeparatedByString:@":"] objectAtIndex:0];
    UIImage *mark = [YZFavicons iconForURL:[@"https://" stringByAppendingString:account.site]];
    cell->icon.image = mark;
    cell->icon.hidden = !mark;
    cell->letter.text = mark ? nil : [[host substringToIndex:MIN((NSUInteger)1, [host length])] uppercaseString];
    cell->letter.backgroundColor = mark ? [YZFavicons tileColorForIcon:mark] : [YZTheme tileColorForHost:host];
    cell->letter.layer.cornerRadius = [YZTheme isClassic] ? 9 : 14;
    cell->letter.layer.borderWidth = mark ? 1 : 0;
    cell->letter.layer.borderColor = [[YZTheme separatorColor] CGColor];
    cell->site.text = account.site;
    cell->site.textColor = [YZTheme textColor];
    cell->user.text = [account.user length] ? account.user : YZT(@"Без логина");
    cell->user.textColor = [YZTheme subtleTextColor];
    NSString *password = [_revealed containsObject:YZAccountKey(account)] ? [YZPasswords passwordForSite:account.site user:account.user] : nil;
    cell->secret.text = password ? password : @"••••••••";
    cell->secret.textColor = password ? [YZTheme accentColor] : [YZTheme subtleTextColor];
    cell->chevron.image = [YZTheme icon:YZIconChevron size:20 color:[YZTheme subtleTextColor]];
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    if (path.section != 0 || (NSUInteger)path.row >= [_shown count] || _sheet || _dialog)
        return;
    [_search resignFirstResponder];
    YZPasswordAccount *account = [[[_shown objectAtIndex:(NSUInteger)path.row] retain] autorelease];
    BOOL revealed = [_revealed containsObject:YZAccountKey(account)];
    NSArray *texts = [NSArray arrayWithObjects:YZT(@"Скопировать логин"), YZT(@"Скопировать пароль"), revealed ? YZT(@"Скрыть пароль") : YZT(@"Показать пароль"),
                      YZT(@"Удалить пароль"), nil];
    NSArray *icons = [NSArray arrayWithObjects:[NSNumber numberWithInt:YZIconCopy], [NSNumber numberWithInt:YZIconCopy], [NSNumber numberWithInt:YZIconLock],
                      [NSNumber numberWithInt:YZIconDelete], nil];
    __block YZPasswordsController *me = self;
    NSString *title = [account.user length] ? [NSString stringWithFormat:@"%@ (%@)", account.site, account.user] : account.site;
    _sheet = [[YZPickers presentActionsInView:self.navigationController ? self.navigationController.view : self.view title:title texts:texts icons:icons
                                  bottomInset:0 completion:^(NSInteger index) {
        [me->_sheet release];
        me->_sheet = nil;
        switch (index) {
        case 0:
            [UIPasteboard generalPasteboard].string = account.user;
            break;
        case 1: {
            NSString *password = [YZPasswords passwordForSite:account.site user:account.user];
            if (password)
                [UIPasteboard generalPasteboard].string = password;
            else
                [me showMessage:YZT(@"Пароль не прочитан из связки ключей")];
            break;
        }
        case 2:
            if (revealed)
                [me->_revealed removeObject:YZAccountKey(account)];
            else
                [me->_revealed addObject:YZAccountKey(account)];
            [me->_table reloadData];
            break;
        case 3:
            [me confirmRemoval:account];
            break;
        default:
            break;
        }
    }] retain];
}

- (void)confirmRemoval:(YZPasswordAccount *)account {
    if (_dialog)
        return;
    __block YZPasswordsController *me = self;
    [account retain];
    NSString *message = [NSString stringWithFormat:YZT(@"Пароль для %@ будет удалён с этого устройства."), account.site];
    _dialog = [[YZDialog dialogWithTitle:YZT(@"Удалить пароль?") message:message cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Удалить") destructive:YES
                                handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        [me->_dialog release];
        me->_dialog = nil;
        if (index == 1)
            [me removeAccount:account];
        [account release];
    }] retain];
    [_dialog showInView:self.navigationController ? self.navigationController.view : self.view];
}

- (void)removeAccount:(YZPasswordAccount *)account {
    NSString *reason = nil;
    if (![YZPasswords removeSite:account.site user:account.user error:&reason]) {
        [self showMessage:[NSString stringWithFormat:YZT(@"Пароль не удалён: %@"), reason]];
        return;
    }
    [_revealed removeObject:YZAccountKey(account)];
    [self reload];
}

- (void)showMessage:(NSString *)message {
    if (_dialog)
        return;
    __block YZPasswordsController *me = self;
    _dialog = [[YZDialog dialogWithTitle:YZT(@"Пароли") message:message cancelTitle:nil confirmTitle:YZT(@"Хорошо") destructive:NO
                                handler:^(NSInteger index, NSArray *texts) {
        (void)index;
        (void)texts;
        [me->_dialog release];
        me->_dialog = nil;
    }] retain];
    [_dialog showInView:self.navigationController ? self.navigationController.view : self.view];
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    (void)path;
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    (void)path;
    return UITableViewCellEditingStyleDelete;
}

// a swipe deletes a login after the same question as the menu, or takes a site off the never list at once
- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    if (style != UITableViewCellEditingStyleDelete)
        return;
    if (path.section == 1) {
        if ((NSUInteger)path.row < [_never count])
            [YZPasswords setNeverSaves:NO site:[_never objectAtIndex:(NSUInteger)path.row]];
        [self reload];
        return;
    }
    if ((NSUInteger)path.row < [_shown count])
        [self confirmRemoval:[_shown objectAtIndex:(NSUInteger)path.row]];
    [_table setEditing:NO animated:YES];
}

@end
