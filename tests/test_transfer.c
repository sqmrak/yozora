#include "yozora_transfer.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "test_transfer: %s:%d: %s\n", __FILE__, __LINE__, #condition); ++failures; } } while (0)

static int text_is(int64_t bytes, const char *expected)
{
    char out[32];
    yozora_transfer_size_text(bytes, out, sizeof out);
    return strcmp(out, expected) == 0;
}

int main(void)
{
    CHECK(text_is(0, "0 B"));
    CHECK(text_is(-5, "0 B"));
    CHECK(text_is(1023, "1023 B"));
    CHECK(text_is(1024, "1 KB"));
    CHECK(text_is(1024 * 1024 - 1, "1024 KB"));
    CHECK(text_is(1024 * 1024, "1.0 MB"));
    CHECK(text_is(3565158, "3.4 MB"));
    CHECK(text_is((int64_t)1024 * 1024 * 1024, "1.0 GB"));
    CHECK(text_is((int64_t)5 * 1024 * 1024 * 1024, "5.0 GB"));

    /* truncation keeps a terminated string, a zero capacity writes nothing */
    char small[4] = {'x', 'x', 'x', 'x'};
    CHECK(yozora_transfer_size_text(1048576, small, 4) == 3);
    CHECK(small[3] == 0 && strcmp(small, "1.0") == 0);
    CHECK(yozora_transfer_size_text(5, small, 0) == 0);
    CHECK(yozora_transfer_size_text(5, NULL, 4) == 0);

    CHECK(yozora_transfer_fraction(50, 100) == 0.5);
    CHECK(yozora_transfer_fraction(0, 100) == 0);
    CHECK(yozora_transfer_fraction(-3, 100) == 0);
    CHECK(yozora_transfer_fraction(100, 100) == 1);
    CHECK(yozora_transfer_fraction(150, 100) == 1);
    CHECK(yozora_transfer_fraction(50, 0) == -1);
    CHECK(yozora_transfer_fraction(50, -1) == -1);

    CHECK(yozora_transfer_speed(0, 1000, 1.0) == 1000);
    CHECK(fabs(yozora_transfer_speed(1000, 2000, 1.0) - 1400) < 1e-9);
    CHECK(fabs(yozora_transfer_speed(1000, 500, 0.5) - 1000) < 1e-9);
    CHECK(yozora_transfer_speed(1000, 2000, 0) == 1000);
    CHECK(yozora_transfer_speed(1000, 2000, -1) == 1000);
    CHECK(yozora_transfer_speed(1000, 2000, NAN) == 1000);
    CHECK(yozora_transfer_speed(1000, 2000, INFINITY) == 1000);
    CHECK(yozora_transfer_speed(1000, -5, 1.0) == 1000);
    CHECK(yozora_transfer_speed(NAN, 700, 1.0) == 700);
    CHECK(yozora_transfer_speed(-4, 700, 1.0) == 700);
    /* a stalled interval pulls the estimate down but not to zero at once */
    CHECK(yozora_transfer_speed(1000, 0, 1.0) == 600);

    CHECK(yozora_transfer_remaining_seconds(0, 1000, 100) == 10);
    CHECK(yozora_transfer_remaining_seconds(0, 1001, 100) == 11);
    CHECK(yozora_transfer_remaining_seconds(1000, 1000, 100) == 0);
    CHECK(yozora_transfer_remaining_seconds(2000, 1000, 100) == 0);
    CHECK(yozora_transfer_remaining_seconds(0, 0, 100) == -1);
    CHECK(yozora_transfer_remaining_seconds(0, 1000, 0) == -1);
    CHECK(yozora_transfer_remaining_seconds(0, 1000, NAN) == -1);
    CHECK(yozora_transfer_remaining_seconds(0, 1000, INFINITY) == -1);
    CHECK(yozora_transfer_remaining_seconds(-50, 1000, 100) == 10);
    /* more than a day left is not shown */
    CHECK(yozora_transfer_remaining_seconds(0, (int64_t)1 << 40, 1) == -1);
    CHECK(yozora_transfer_remaining_seconds(0, 86400, 1) == 86400);
    CHECK(yozora_transfer_remaining_seconds(0, 86401, 1) == -1);

    {
        char field[8];
        memset(field, 'x', sizeof field);
        yozora_transfer_copy_text(field, sizeof field, "abc");
        CHECK(!strcmp(field, "abc"));
        yozora_transfer_copy_text(field, sizeof field, "1234567");
        CHECK(!strcmp(field, "1234567"));
        yozora_transfer_copy_text(field, sizeof field, "12345678");
        CHECK(!strcmp(field, "1234567"));
        /* two-byte characters: 3 of them take 6 bytes, the 4th would split at byte 7 */
        yozora_transfer_copy_text(field, sizeof field, "\xD0\xB0\xD0\xB1\xD0\xB2\xD0\xB3");
        CHECK(!strcmp(field, "\xD0\xB0\xD0\xB1\xD0\xB2"));
        /* a three-byte character that starts at byte 6 does not fit and goes whole */
        yozora_transfer_copy_text(field, sizeof field, "12345\xE3\x81\x82");
        CHECK(!strcmp(field, "12345"));
        yozora_transfer_copy_text(field, sizeof field, "");
        CHECK(field[0] == 0);
        yozora_transfer_copy_text(field, sizeof field, NULL);
        CHECK(field[0] == 0);
        field[0] = 'k';
        yozora_transfer_copy_text(field, 0, "abc");
        CHECK(field[0] == 'k');
        yozora_transfer_copy_text(field, 1, "abc");
        CHECK(field[0] == 0);
    }

    if (failures)
        return 1;
    puts("test_transfer: ok");
    return 0;
}
