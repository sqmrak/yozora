#import "YZDebugOverlay.h"
#import "YZCompat.h"
#import "YZTheme.h"
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <QuartzCore/QuartzCore.h>
#include "yozora_debug.h"
#include "yozora_core.h"
#if defined(__arm64__)
#import "../core/core/YozoraMetal.h"
#endif

static const CGFloat YZOverlayWidth = 236;
static const CGFloat YZOverlayRow = 16;
static const CGFloat YZOverlayPad = 10;

typedef enum {
    YZOverlayFPS,
    YZOverlayCPU,
    YZOverlayRender,
    YZOverlayMemory,
    YZOverlayGPU,
    YZOverlayJIT,
    YZOverlayRows
} YZOverlayRow_t;

static UIFont *YZMonoFont(CGFloat size) {
    UIFont *font = [UIFont fontWithName:@"JetBrainsMono-Regular" size:size];
    return font ? font : [UIFont fontWithName:@"Courier" size:size];
}

static UIColor *YZGood(void) { return [UIColor colorWithRed:0.48f green:0.88f blue:0.54f alpha:1]; }
static UIColor *YZWarn(void) { return [UIColor colorWithRed:1.0f green:0.82f blue:0.40f alpha:1]; }
static UIColor *YZBad(void) { return [UIColor colorWithRed:1.0f green:0.42f blue:0.42f alpha:1]; }

// the processor time of all threads in percent of one core, as Xcode adds it up, a busy two core phone reads
// up to 200
static double YZProcessCPU(void) {
    thread_array_t threads;
    mach_msg_type_number_t count;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
        return 0;
    double total = 0;
    for (mach_msg_type_number_t i = 0; i < count; ++i) {
        thread_basic_info_data_t info;
        mach_msg_type_number_t size = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &size) == KERN_SUCCESS && !(info.flags & TH_FLAGS_IDLE))
            total += info.cpu_usage / (double)TH_USAGE_SCALE * 100.0;
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    return total;
}

// the pages of the process that are in memory now, in bytes
static unsigned long long YZResidentBytes(void) {
    task_basic_info_data_t info;
    mach_msg_type_number_t size = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size) != KERN_SUCCESS)
        return 0;
    return info.resident_size;
}

static NSString *YZMachineIdentifier(void) {
    char machine[64] = { 0 };
    size_t size = sizeof machine;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0)
        return @"";
    return [NSString stringWithUTF8String:machine];
}

@implementation YZDebugOverlay
@synthesize site = _site;

+ (CGSize)preferredSize {
    // six numbers, the phone and the site, between two pads
    return CGSizeMake(YZOverlayWidth, YZOverlayPad * 2 + YZOverlayRow * (YZOverlayRows + 2) + 6);
}

- (UILabel *)labelWithColor:(UIColor *)color align:(int)alignment {
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.font = YZMonoFont(10.5f);
    label.textColor = color;
    label.textAlignment = alignment;
    label.lineBreakMode = YZLineBreakTailTruncation;
    [self addSubview:label];
    return label;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = [UIColor colorWithWhite:0.06f alpha:0.78f];
    self.layer.cornerRadius = 16;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [[UIColor colorWithWhite:1 alpha:0.12f] CGColor];
    _keys = [[NSMutableArray alloc] init];
    _values = [[NSMutableArray alloc] init];
    static NSString *const names[] = { @"FPS", @"CPU", @"RENDER", @"MEM", @"GPU", @"JIT" };
    for (int i = 0; i < YZOverlayRows; ++i) {
        UILabel *key = [self labelWithColor:[UIColor colorWithWhite:1 alpha:0.5f] align:YZTextAlignmentLeft];
        key.text = names[i];
        [_keys addObject:key];
        [_values addObject:[self labelWithColor:[UIColor whiteColor] align:YZTextAlignmentRight]];
    }
    // the dot of the accent that lights up while the overlay reads
    _dot = [[UIView alloc] initWithFrame:CGRectMake(YZOverlayWidth - YZOverlayPad - 6, YZOverlayPad + 5, 6, 6)];
    _dot.backgroundColor = [YZTheme accentColor];
    _dot.layer.cornerRadius = 3;
    [self addSubview:_dot];
    NSString *identifier = YZMachineIdentifier();
    char model[48];
    yozora_device_model_name([identifier UTF8String], model, sizeof model);
    yozora_device device;
    yozora_device_info(&device);
    _device = [[NSString stringWithFormat:@"%s · iOS %@ · %u MB", model, [[UIDevice currentDevice] systemVersion], device.memory_mb] retain];
    _deviceLabel = [[self labelWithColor:[UIColor colorWithWhite:1 alpha:0.62f] align:YZTextAlignmentLeft] retain];
    _deviceLabel.font = YZMonoFont(10);
    _deviceLabel.text = _device;
    _siteLabel = [[self labelWithColor:[UIColor whiteColor] align:YZTextAlignmentLeft] retain];
    _siteLabel.font = YZMonoFont(10);
    _siteLabel.text = @"-";
    _windowStart = CACurrentMediaTime();
    return self;
}

- (void)dealloc {
    [_keys release];
    [_values release];
    [_dot release];
    [_site release];
    [_device release];
    [_deviceLabel release];
    [_siteLabel release];
    [super dealloc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inner = self.bounds.size.width - 2 * YZOverlayPad;
    CGFloat y = YZOverlayPad;
    for (int i = 0; i < YZOverlayRows; ++i) {
        [[_keys objectAtIndex:i] setFrame:CGRectMake(YZOverlayPad, y, 54, YZOverlayRow)];
        [[_values objectAtIndex:i] setFrame:CGRectMake(YZOverlayPad + 54, y, inner - 54, YZOverlayRow)];
        y += YZOverlayRow;
    }
    _dot.backgroundColor = [YZTheme accentColor];
    CGFloat y2 = YZOverlayPad + YZOverlayRow * YZOverlayRows + 6;
    _deviceLabel.frame = CGRectMake(YZOverlayPad, y2, inner, YZOverlayRow);
    _siteLabel.frame = CGRectMake(YZOverlayPad, y2 + YZOverlayRow, inner, YZOverlayRow);
}

- (void)setSite:(NSString *)site {
    if (site == _site || [site isEqualToString:_site])
        return;
    [site retain];
    [_site release];
    _site = site;
    _siteLabel.text = [_site length] ? _site : @"-";
}

- (void)noteFrame { ++_frames; }
- (void)noteScene { ++_scenes; }

- (void)setValue:(int)row text:(NSString *)text color:(UIColor *)color {
    UILabel *label = [_values objectAtIndex:row];
    label.text = text;
    label.textColor = color;
}

// tiles of the pages: Metal on arm64 from ios 11, the cpu elsewhere or when Metal is off or refused
- (void)refreshGPU {
#if defined(__arm64__)
    yozora_metal_info info;
    yozora_metal_info_read(&info);
    char held[16];
    yozora_format_bytes(info.surface_bytes, held, sizeof held);
    switch (info.state) {
    case 1:
        [self setValue:YZOverlayGPU text:[NSString stringWithFormat:@"Metal %llu  cpu %llu  %s", info.tiles, info.fallbacks, held]
                 color:info.fallbacks * 10 > info.tiles ? YZWarn() : YZGood()];
        return;
    case 2:
        [self setValue:YZOverlayGPU text:@"Metal refused, cpu" color:YZBad()];
        return;
    case 3:
        [self setValue:YZOverlayGPU text:@"Metal waits for a page" color:[UIColor whiteColor]];
        return;
    default:
        break;
    }
#endif
    [self setValue:YZOverlayGPU text:@"cpu raster" color:[UIColor whiteColor]];
}

// the tiers JavaScriptCore runs after it started and the code memory in use
- (void)refreshJIT {
    yozora_jit_info jit;
    yozora_jit_info_read(&jit);
    if (!jit.compiled || !jit.active) {
        [self setValue:YZOverlayJIT text:@"off, interpreter" color:jit.requested ? YZBad() : [UIColor whiteColor]];
        return;
    }
    char used[16];
    yozora_format_bytes(jit.pool_used, used, sizeof used);
    [self setValue:YZOverlayJIT text:[NSString stringWithFormat:@"base%s%s%s  %s", jit.dfg ? " dfg" : "", jit.ftl ? " ftl" : "", jit.regexp ? " re" : "", used] color:YZGood()];
}

- (void)refreshWithCore:(yozora_core *)core {
    CFTimeInterval now = CACurrentMediaTime();
    double elapsed = now - _windowStart;
    // twice a second, a reading that is too young has measured nothing
    if (elapsed < 0.5)
        return;
    _windowStart = now;
    _fps = _frames / elapsed;
    _sceneRate = _scenes / elapsed;
    _frames = 0;
    _scenes = 0;
    yozora_device device;
    yozora_device_info(&device);

    UIColor *fpsColor = _fps >= 50 ? YZGood() : (_fps >= 30 ? YZWarn() : YZBad());
    [self setValue:YZOverlayFPS text:[NSString stringWithFormat:@"%.0f  scenes %.0f/s", _fps, _sceneRate] color:fpsColor];

    double cpu = YZProcessCPU();
    double share = cpu / (device.cores ? device.cores : 1);
    [self setValue:YZOverlayCPU text:[NSString stringWithFormat:@"%.0f%%  of %u cores", cpu, device.cores] color:share < 60 ? YZGood() : (share < 85 ? YZWarn() : YZBad())];

    // the core thread and its raster worker: layout, style and painting, in milliseconds spent for each second that passed
    double render = 0;
    if (core) {
        yozora_core_stats stats;
        yozora_core_read_stats(core, &stats);
        long long spent = stats.rendering_ms + stats.layout_ms + stats.paint_ms;
        if (_previousPaintMs && spent >= _previousPaintMs)
            render = (spent - _previousPaintMs) / (elapsed * 1000.0) * 100.0;
        _previousPaintMs = spent;
    }
    [self setValue:YZOverlayRender text:[NSString stringWithFormat:@"%.0f%%  layout+paint", render] color:render < 50 ? YZGood() : (render < 80 ? YZWarn() : YZBad())];

    unsigned long long resident = YZResidentBytes();
    char size[16];
    yozora_format_bytes(resident, size, sizeof size);
    double use = device.memory_mb ? resident / (device.memory_mb * 1048576.0) : 0;
    [self setValue:YZOverlayMemory text:[NSString stringWithFormat:@"%s  %.0f%%", size, use * 100] color:use < 0.35 ? YZGood() : (use < 0.55 ? YZWarn() : YZBad())];

    [self refreshGPU];
    [self refreshJIT];

    // the dot blinks once for every reading
    _dot.alpha = 1;
    [UIView animateWithDuration:0.4 animations:^{ _dot.alpha = 0.25f; }];
}

@end
