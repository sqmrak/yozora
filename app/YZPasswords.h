#import <Foundation/Foundation.h>

/* a login kept for a site: the site (core/yozora_password.h), the login and when it was last saved. the password itself stays in the
   keychain and is read only when it is filled, copied or shown */
@interface YZPasswordAccount : NSObject {
    NSString *_site;
    NSString *_user;
    NSDate *_modified;
}
@property(nonatomic, copy) NSString *site;
@property(nonatomic, copy) NSString *user;
@property(nonatomic, retain) NSDate *modified;
@end

/* a login form the page sent: the address of the page that held it, the login (empty when the form had none) and the password */
@interface YZPasswordCapture : NSObject {
    NSString *_site;
    NSString *_user;
    NSString *_password;
}
@property(nonatomic, copy) NSString *site;
@property(nonatomic, copy) NSString *user;
@property(nonatomic, copy) NSString *password;
@end

/* the passwords of sites in the keychain (internet passwords, readable only while the device is unlocked) and the sites the person said
   never for. every call runs on the main thread */
@interface YZPasswords : NSObject
/* every kept login, sorted by site and then by login. nil and a reason in error when the keychain refused the reading */
+ (NSArray *)accountsWithError:(NSString **)error;
/* the logins of one site, the one saved last first */
+ (NSArray *)accountsForSite:(NSString *)site;
/* nil when there is none or the keychain refused, the refusal is logged */
+ (NSString *)passwordForSite:(NSString *)site user:(NSString *)user;
/* stores or replaces the password of the login. NO and a reason in error when the keychain refused */
+ (BOOL)savePassword:(NSString *)password site:(NSString *)site user:(NSString *)user error:(NSString **)error;
+ (BOOL)removeSite:(NSString *)site user:(NSString *)user error:(NSString **)error;

+ (BOOL)neverSavesForSite:(NSString *)site;
+ (void)setNeverSaves:(BOOL)never site:(NSString *)site;
+ (NSArray *)neverSites;

/* the site of an https address, nil for any other */
+ (NSString *)siteOfAddress:(NSString *)address;
/* a script for the isolated world of the page: it reads the login form whose password field holds text and answers with the page address,
   the login and the password as json, an empty text when there is none */
+ (NSString *)captureScript;
/* turns the answer of the capture script into a capture, nil for an empty, malformed or non https answer */
+ (YZPasswordCapture *)captureFromAnswer:(NSString *)answer;
/* a script that fills the one empty password field of the page and the login field before it, "filled" when it did. a page with more than
   one password field (a sign up or a change of password) is left alone */
+ (NSString *)fillScriptWithUser:(NSString *)user password:(NSString *)password;
@end
