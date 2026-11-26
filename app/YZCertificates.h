#import <Foundation/Foundation.h>

/* root certificates the person added. they are kept one by one in the certificates folder of the profile (Library/Yozora, or Documents/Yozora when that refuses writes; PEM, named by the
   sha-1 of the certificate) and every consumer of the roots (the page loads, the translator, the stream proxy)
   reads one merged file: the bundled roots followed by these. the merged file gets a new name whenever the set
   changes, because curl keeps a parsed store per file name and would not read a changed file for a day */

@interface YZCertificates : NSObject
/* the roots file to give to the core, the bundle's own while nothing was added */
+ (NSString *)rootsPath;
/* the certificates found in a file's bytes (PEM with any number of blocks, or one DER), as dictionaries with
   "der" (NSData), "name" and "print" (the first bytes of the sha-1 as hex). nil with *error set when none is valid */
+ (NSArray *)parseData:(NSData *)data error:(NSString **)error;
/* the added certificates in the order they were added: "name", "print", "file" */
+ (NSArray *)entries;
/* keeps the parsed certificates and hands the new roots file to the core, the translator and the stream proxy,
   returns how many were new */
+ (NSUInteger)add:(NSArray *)parsed error:(NSString **)error;
+ (BOOL)removeEntryNamed:(NSString *)file;
@end
