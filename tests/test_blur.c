#include "yozora_blur.h"
#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "test_blur: %s:%d: %s\n", __FILE__, __LINE__, #condition); ++failures; } } while (0)

int main(void)
{
    /* the lightness of a picture: black, white, the weights of the channels, alpha unread, a stride wider than a row, and empty input */
    uint8_t black[4 * 4 * 4], white[4 * 4 * 4], mixed[2 * 4];
    memset(black, 0, sizeof black);
    memset(white, 255, sizeof white);
    CHECK(yozora_luma_average(black, 4, 4, 16) == 0);
    CHECK(yozora_luma_average(white, 4, 4, 16) == 255);
    mixed[0] = 255; mixed[1] = 0; mixed[2] = 0; mixed[3] = 0;
    mixed[4] = 0; mixed[5] = 255; mixed[6] = 0; mixed[7] = 255;
    CHECK(yozora_luma_average(mixed, 1, 1, 4) == 76);
    CHECK(yozora_luma_average(mixed + 4, 1, 1, 4) == 149);
    CHECK(yozora_luma_average(mixed, 2, 1, 8) == 113);
    uint8_t wide[2 * 12];
    memset(wide, 255, sizeof wide);
    memset(wide + 8, 0, 4);
    memset(wide + 20, 0, 4);
    CHECK(yozora_luma_average(wide, 2, 2, 12) == 255);
    CHECK(yozora_luma_average(wide, 0, 2, 12) == 0);
    CHECK(yozora_luma_average(wide, 2, 0, 12) == 0);
    CHECK(yozora_luma_average(wide, 2, 2, 7) == 0);
    CHECK(yozora_luma_average(NULL, 2, 2, 12) == 0);

    if (failures) {
        fprintf(stderr, "test_blur: %d failures\n", failures);
        return 1;
    }
    printf("test_blur: ok\n");
    return 0;
}
