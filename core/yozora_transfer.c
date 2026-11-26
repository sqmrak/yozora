#include "yozora_transfer.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

#define TRANSFER_MAX_SECONDS (24 * 60 * 60)

size_t yozora_transfer_size_text(int64_t bytes, char *out, size_t capacity)
{
    if (!out || !capacity)
        return 0;
    out[0] = 0;
    if (bytes < 0)
        bytes = 0;
    int written;
    if (bytes < 1024)
        written = snprintf(out, capacity, "%lld B", (long long)bytes);
    else if (bytes < 1024 * 1024)
        written = snprintf(out, capacity, "%lld KB", (long long)((bytes + 512) / 1024));
    else if (bytes < (int64_t)1024 * 1024 * 1024)
        written = snprintf(out, capacity, "%.1f MB", (double)bytes / (1024.0 * 1024.0));
    else
        written = snprintf(out, capacity, "%.1f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0));
    if (written < 0) {
        out[0] = 0;
        return 0;
    }
    return (size_t)written < capacity ? (size_t)written : capacity - 1;
}

void yozora_transfer_copy_text(char *out, size_t capacity, const char *text)
{
    if (!out || !capacity)
        return;
    size_t length = 0;
    if (text) {
        while (text[length] && length < capacity - 1)
            ++length;
        /* the text goes on past the field: step back over a started character and its continuation bytes */
        if (text[length]) {
            while (length > 0 && ((unsigned char)text[length] & 0xC0) == 0x80)
                --length;
        }
        memcpy(out, text, length);
    }
    out[length] = 0;
}

double yozora_transfer_fraction(int64_t received, int64_t total)
{
    if (total <= 0)
        return -1;
    if (received <= 0)
        return 0;
    if (received >= total)
        return 1;
    return (double)received / (double)total;
}

double yozora_transfer_speed(double previous, int64_t delta_bytes, double seconds)
{
    if (!(previous > 0))
        previous = 0;
    if (!(seconds > 0) || !isfinite(seconds) || delta_bytes < 0)
        return previous;
    double instant = (double)delta_bytes / seconds;
    if (!isfinite(instant))
        return previous;
    return previous > 0 ? previous * 0.6 + instant * 0.4 : instant;
}

int64_t yozora_transfer_remaining_seconds(int64_t received, int64_t total, double speed)
{
    if (total <= 0 || !(speed > 0) || !isfinite(speed))
        return -1;
    if (received >= total)
        return 0;
    if (received < 0)
        received = 0;
    double seconds = ceil((double)(total - received) / speed);
    if (!(seconds <= TRANSFER_MAX_SECONDS))
        return -1;
    return (int64_t)seconds;
}
