#ifndef YOZORA_TRANSFER_H
#define YOZORA_TRANSFER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* what a download shows: sizes, the fraction done, the speed and the time left. a size that is unknown is zero or less */

/* "512 B", "12 KB", "3.4 MB", "1.2 GB": one decimal from a megabyte on, steps of 1024, a negative size as
   zero. writes at most capacity bytes with the terminator and returns the length, 0 when capacity is 0 */
size_t yozora_transfer_size_text(int64_t bytes, char *out, size_t capacity);

/* copies text into a fixed field and ends it with a terminator. a text that does not fit is cut before the
   character it would split, so the field is always valid utf-8 (a cut character makes NSString return nil).
   a null text gives an empty string, a capacity of 0 writes nothing */
void yozora_transfer_copy_text(char *out, size_t capacity, const char *text);

/* received over total held to 0..1, or -1 when the total is not known (zero or less). a received count past the total gives 1 */
double yozora_transfer_fraction(int64_t received, int64_t total);

/* speed in bytes a second after one more sample: old estimate and last interval mixed 60 to 40, the interval
   alone when there is no estimate (previous of zero or less). a bad interval or a count that went backwards
   keeps the estimate */
double yozora_transfer_speed(double previous, int64_t delta_bytes, double seconds);

/* whole seconds until the rest arrives, rounded up, or -1 when the speed is not positive, the total is
   unknown or the result passes a day (a figure that large says nothing) */
int64_t yozora_transfer_remaining_seconds(int64_t received, int64_t total, double speed);

#ifdef __cplusplus
}
#endif
#endif
