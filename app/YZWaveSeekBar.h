#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

/* the height a bar of this kind is laid out in, and the room its ends keep for the handle */
#define YZWaveSeekBarHeight 28.0
#define YZWaveSeekBarInset 6.0

/* the full screen seek bar, the Material 3 Expressive progress bar as in exteria: the played part is a wave
   that travels while playing and lies flat when not, a pill handle squeezes under a finger, loaded is a
   brighter line. value changed fires while the finger moves, touch up inside once on lift, setting values
   sends nothing */
@interface YZWaveSeekBar : UIControl {
    CAShapeLayer *_rest;
    CAShapeLayer *_buffer;
    CALayer *_clip;
    CAShapeLayer *_wave;
    CALayer *_thumb;
    float _value;
    float _buffered;
    BOOL _waving;
    BOOL _plain;
    BOOL _dragging;
    CGSize _laidSize;
    BOOL _observing;
}
/* the played part and the loaded end as fractions of the stream, 0 to 1 */
@property (nonatomic, assign) float value;
@property (nonatomic, assign) float buffered;
@property (nonatomic, assign) BOOL waving;
/* an ordinary bar: a straight line, a round handle that grows under a finger, no wave and nothing that travels. waving is ignored. set once, before the
   bar is laid out */
@property (nonatomic, assign) BOOL plain;
@property (nonatomic, readonly, getter=isDragging) BOOL dragging;
/* the colors of the wave and handle, of the loaded line and of the rest */
@property (nonatomic, copy) UIColor *playedColor;
/* the line after the played part, white at a quarter by default for the dark player, a list on a light ground sets its own */
@property (nonatomic, copy) UIColor *restColor;
/* a value that follows playback glides to the new place over the quarter second between ticks */
- (void)setValue:(float)value gliding:(BOOL)gliding;
@end
