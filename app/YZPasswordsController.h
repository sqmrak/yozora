#import <UIKit/UIKit.h>
#import "YZControls.h"
#import "YZDialog.h"
#import "YZSheets.h"

/* the saved passwords as a list of cards: the mark of the site, the site, the login and the hidden password. a search line filters by site
   and login, a tap opens the actions of the login (copy, show, delete), a swipe deletes. the sites said never for stand in a list of their
   own under it and a swipe takes one back */
@interface YZPasswordsController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate> {
    UITableView *_table;
    UIView *_header;
    UITextField *_search;
    UILabel *_count;
    UIView *_empty;
    UIView *_emptyDisc;
    UIImageView *_emptyIcon;
    UILabel *_emptyText;
    YZBarFill *_fill;
    // every login read from the keychain, the ones the search keeps, and the logins whose password is shown in the open
    NSArray *_accounts;
    NSMutableArray *_shown;
    NSMutableSet *_revealed;
    NSArray *_never;
    YZSheet *_sheet;
    YZDialog *_dialog;
}
/* asks for the passcode or the finger of the owner where the system can (ios 9 and newer with a passcode set) and runs done with YES once
   the list may be shown. older systems have no such check and show it at once */
+ (void)unlockThen:(void (^)(BOOL unlocked))done;
@end
