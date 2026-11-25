#import "YZStreamProxy.h"
#import "YZCertificates.h"
#import <AVFoundation/AVFoundation.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "yozora_stream_proxy.h"

// the three calls of the proxy for a local stream, over the object of core/yozora_hls.h that the stream is
static int YZLocalRead(void *context, const char *name, uint64_t offset, uint8_t *out, size_t capacity, size_t *got, uint64_t *total, const char **contentType) {
    return (int)yozora_hls_read((yozora_hls *)context, name, offset, out, capacity, got, total, contentType);
}
static void YZLocalRetain(void *context) { yozora_hls_retain((yozora_hls *)context); }
static void YZLocalRelease(void *context) { yozora_hls_release((yozora_hls *)context); }

typedef struct {
    int references;
    int count;
    char *names[4];
    char *paths[4];
} YZFileSet;

static int YZFilesRead(void *context, const char *name, uint64_t offset, uint8_t *out, size_t capacity, size_t *got, uint64_t *total, const char **contentType) {
    YZFileSet *set = (YZFileSet *)context;
    *got = 0;
    for (int i = 0; i < set->count; ++i) {
        if (strcmp(set->names[i], name) != 0)
            continue;
        int fd = open(set->paths[i], O_RDONLY);
        struct stat info;
        if (fd < 0)
            return 1;
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
            close(fd);
            return 1;
        }
        *total = (uint64_t)info.st_size;
        size_t length = strlen(name);
        *contentType = length > 6 && strcmp(name + length - 6, ".plist") == 0 ? "text/xml" : "application/octet-stream";
        int status = 0;
        if (capacity) {
            if (offset >= *total && *total) {
                status = 2;
            } else {
                ssize_t n = pread(fd, out, capacity, (off_t)offset);
                *got = n > 0 ? (size_t)n : 0;
            }
        }
        close(fd);
        return status;
    }
    return 1;
}

static void YZFilesRetain(void *context) { __sync_add_and_fetch(&((YZFileSet *)context)->references, 1); }

static void YZFilesRelease(void *context) {
    YZFileSet *set = (YZFileSet *)context;
    if (__sync_sub_and_fetch(&set->references, 1) != 0)
        return;
    for (int i = 0; i < set->count; ++i) {
        free(set->names[i]);
        free(set->paths[i]);
    }
    free(set);
}

@implementation YZStreamProxy {
    yozora_proxy *_proxy;
    unsigned _generation;
}

+ (YZStreamProxy *)shared {
    static YZStreamProxy *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[YZStreamProxy alloc] init]; });
    return shared;
}

- (BOOL)ensureRunning {
    if (_proxy && yozora_proxy_alive(_proxy))
        return YES;
    if (_proxy) {
        NSLog(@"yozora: the stream proxy lost its socket, starting another");
        yozora_proxy_stop(_proxy);
        _proxy = NULL;
    }
    NSString *roots = [YZCertificates rootsPath];
    if (!roots) {
        NSLog(@"yozora: the root certificates are missing from the bundle, the stream proxy cannot start");
        return NO;
    }
    yozora_proxy_config config;
    memset(&config, 0, sizeof config);
    config.ca_bundle = [roots fileSystemRepresentation];
    config.user_agent = yozora_user_agent();
    // avplayer before ios 10 answers -11800 for ext-x-map, the proxy converts the segments
    config.transmux_fmp4 = [AVPlayer instancesRespondToSelector:NSSelectorFromString(@"setAutomaticallyWaitsToMinimizeStalling:")] ? 0 : 1;
    yozora_proxy_status status = yozora_proxy_start(&config, &_proxy);
    if (status != YOZORA_PROXY_OK) {
        NSLog(@"yozora: the stream proxy did not start (%d)", (int)status);
        _proxy = NULL;
        return NO;
    }
    ++_generation;
    return YES;
}

- (void)rootsChanged {
    @synchronized(self) {
        if (_proxy)
            yozora_proxy_stop(_proxy);
        _proxy = NULL;
    }
}

- (NSURL *)proxiedURLForRequest:(const yozora_media_request *)request stream:(unsigned *)stream generation:(unsigned *)generation {
    @synchronized(self) {
        if (![self ensureRunning])
            return nil;
        char local[8192];
        unsigned registered = 0;
        yozora_proxy_status status = yozora_proxy_register(_proxy, request->url, request->cookie, request->referer, local, sizeof local, &registered);
        if (status != YOZORA_PROXY_OK) {
            NSLog(@"yozora: the stream proxy refused a stream (%d)", (int)status);
            return nil;
        }
        if (stream)
            *stream = registered;
        if (generation)
            *generation = _generation;
        return [NSURL URLWithString:[NSString stringWithUTF8String:local]];
    }
}

- (NSURL *)localURLForMediaID:(unsigned)mediaID core:(yozora_core *)core stream:(unsigned *)stream generation:(unsigned *)generation {
    // the core hands over a reference: the proxy keeps it for the stream, and it is let go here when the proxy takes none
    yozora_hls *hls = yozora_core_mse_stream(core, mediaID);
    if (!hls)
        return nil;
    @synchronized(self) {
        if (![self ensureRunning]) {
            yozora_hls_release(hls);
            return nil;
        }
        char local[256];
        unsigned registered = 0;
        yozora_proxy_status status = yozora_proxy_register_local(_proxy, YZLocalRead, YZLocalRetain, YZLocalRelease, hls, local, sizeof local, &registered);
        if (status != YOZORA_PROXY_OK) {
            NSLog(@"yozora: the stream proxy refused a local stream (%d)", (int)status);
            yozora_hls_release(hls);
            return nil;
        }
        if (stream)
            *stream = registered;
        if (generation)
            *generation = _generation;
        return [NSURL URLWithString:[[NSString stringWithUTF8String:local] stringByAppendingString:@YOZORA_HLS_NAME_PLAYLIST]];
    }
}

- (NSURL *)proxiedURLForAddress:(NSString *)address stream:(unsigned *)stream generation:(unsigned *)generation {
    @synchronized(self) {
        if (![self ensureRunning])
            return nil;
        char local[8192];
        unsigned registered = 0;
        yozora_proxy_status status = yozora_proxy_register(_proxy, [address UTF8String], "", "", local, sizeof local, &registered);
        if (status != YOZORA_PROXY_OK) {
            NSLog(@"yozora: the stream proxy refused %@ (%d)", [[NSURL URLWithString:address] host], (int)status);
            return nil;
        }
        if (stream)
            *stream = registered;
        if (generation)
            *generation = _generation;
        return [NSURL URLWithString:[NSString stringWithUTF8String:local]];
    }
}

- (NSURL *)localURLForFiles:(NSDictionary *)files stream:(unsigned *)stream generation:(unsigned *)generation {
    if (![files count] || [files count] > 4)
        return nil;
    YZFileSet *set = calloc(1, sizeof *set);
    if (!set)
        return nil;
    set->references = 1;
    for (NSString *name in files) {
        set->names[set->count] = strdup([name UTF8String]);
        set->paths[set->count] = strdup([[files objectForKey:name] fileSystemRepresentation]);
        if (!set->names[set->count] || !set->paths[set->count]) {
            ++set->count;
            YZFilesRelease(set);
            return nil;
        }
        ++set->count;
    }
    @synchronized(self) {
        if (![self ensureRunning]) {
            YZFilesRelease(set);
            return nil;
        }
        char local[256];
        unsigned registered = 0;
        yozora_proxy_status status = yozora_proxy_register_local(_proxy, YZFilesRead, YZFilesRetain, YZFilesRelease, set, local, sizeof local, &registered);
        if (status != YOZORA_PROXY_OK) {
            NSLog(@"yozora: the stream proxy refused a set of files (%d)", (int)status);
            YZFilesRelease(set);
            return nil;
        }
        if (stream)
            *stream = registered;
        if (generation)
            *generation = _generation;
        return [NSURL URLWithString:[NSString stringWithUTF8String:local]];
    }
}

- (void)releaseStream:(unsigned)stream generation:(unsigned)generation {
    @synchronized(self) {
        if (_proxy && generation == _generation)
            yozora_proxy_release(_proxy, stream);
    }
}

@end
