#include "yozora_home.h"
#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "test_home: %s:%d: %s\n", __FILE__, __LINE__, #condition); ++failures; } } while (0)

static int order_is(const uint8_t order[3], int a, int b, int c)
{
    return order[0] == a && order[1] == b && order[2] == c;
}

static int parses_as(const char *text, int a, int b, int c)
{
    uint8_t order[3] = { 9, 9, 9 };
    return yozora_home_order_parse(text, order) == 1 && order_is(order, a, b, c);
}

static int indices_are(const size_t *got, size_t count, const size_t *want, size_t want_count)
{
    if (count != want_count)
        return 0;
    for (size_t i = 0; i < count; ++i) {
        if (got[i] != want[i])
            return 0;
    }
    return 1;
}

static int is_refused(const char *text)
{
    uint8_t order[3] = { 9, 9, 9 };
    return yozora_home_order_parse(text, order) == 0 && order_is(order, 0, 1, 2);
}

int main(void)
{
    uint8_t order[3];
    yozora_home_order_default(order);
    CHECK(order_is(order, 0, 1, 2));

    CHECK(parses_as("0,1,2", 0, 1, 2));
    CHECK(parses_as("2,0,1", 2, 0, 1));
    CHECK(parses_as("1,2,0", 1, 2, 0));
    /* a stored value that is no order of the three blocks gives the default and says so */
    CHECK(is_refused(NULL));
    CHECK(is_refused(""));
    CHECK(is_refused("0,1"));
    CHECK(is_refused("0,1,2,"));
    CHECK(is_refused("0,1,2,3"));
    CHECK(is_refused("0,0,1"));
    CHECK(is_refused("0,1,3"));
    CHECK(is_refused("0 1 2"));
    CHECK(is_refused(" 0,1,2"));
    CHECK(is_refused("0,1,2 "));
    CHECK(is_refused("a,b,c"));
    CHECK(is_refused("00,1,2"));

    char text[8];
    yozora_home_order_default(order);
    CHECK(yozora_home_order_format(order, text, sizeof text) == 5 && !strcmp(text, "0,1,2"));
    order[0] = 2; order[1] = 0; order[2] = 1;
    CHECK(yozora_home_order_format(order, text, sizeof text) == 5 && !strcmp(text, "2,0,1"));
    CHECK(yozora_home_order_format(order, text, 5) == 0 && text[0] == 0);
    CHECK(yozora_home_order_format(order, text, 6) == 5);
    CHECK(yozora_home_order_format(order, text, 0) == 0);
    order[1] = 2;
    CHECK(yozora_home_order_format(order, text, sizeof text) == 0 && text[0] == 0);


    const char *items[] = { "a", "b", "c", "d", "e" };
    size_t out[8];
    size_t n;
    /* nothing placed and nothing hidden keeps the natural order */
    n = yozora_home_arrange(items, 5, NULL, 0, NULL, 0, out, 8);
    { const size_t want[] = { 0, 1, 2, 3, 4 }; CHECK(indices_are(out, n, want, 5)); }
    /* the placed ones lead in their own order, the rest follow in natural order */
    { const char *placed[] = { "d", "b" };
      n = yozora_home_arrange(items, 5, placed, 2, NULL, 0, out, 8);
      const size_t want[] = { 3, 1, 0, 2, 4 }; CHECK(indices_are(out, n, want, 5)); }
    /* a placed address that is gone from the items, a repeated one and a null one are skipped */
    { const char *placed[] = { "x", "c", NULL, "c", "a" };
      n = yozora_home_arrange(items, 5, placed, 5, NULL, 0, out, 8);
      const size_t want[] = { 2, 0, 1, 3, 4 }; CHECK(indices_are(out, n, want, 5)); }
    /* a hidden address is left out even when it was placed */
    { const char *placed[] = { "b", "a" }, *hidden[] = { "b", "e" };
      n = yozora_home_arrange(items, 5, placed, 2, hidden, 2, out, 8);
      const size_t want[] = { 0, 2, 3 }; CHECK(indices_are(out, n, want, 3)); }
    /* capacity bounds what is written, placed ones first */
    { const char *placed[] = { "e" };
      n = yozora_home_arrange(items, 5, placed, 1, NULL, 0, out, 2);
      const size_t want[] = { 4, 0 }; CHECK(indices_are(out, n, want, 2)); }
    /* repeated items show once */
    { const char *repeated[] = { "a", "b", "a", NULL, "c" };
      n = yozora_home_arrange(repeated, 5, NULL, 0, NULL, 0, out, 8);
      const size_t want[] = { 0, 1, 4 }; CHECK(indices_are(out, n, want, 3)); }
    CHECK(yozora_home_arrange(items, 5, NULL, 0, NULL, 0, out, 0) == 0);
    CHECK(yozora_home_arrange(NULL, 5, NULL, 0, NULL, 0, out, 8) == 0);
    CHECK(yozora_home_arrange(items, 0, NULL, 0, NULL, 0, out, 8) == 0);

    size_t moved[] = { 0, 1, 2, 3, 4 };
    CHECK(yozora_home_move(moved, 5, 0, 3) == 1);
    { const size_t want[] = { 1, 2, 3, 0, 4 }; CHECK(indices_are(moved, 5, want, 5)); }
    CHECK(yozora_home_move(moved, 5, 4, 0) == 1);
    { const size_t want[] = { 4, 1, 2, 3, 0 }; CHECK(indices_are(moved, 5, want, 5)); }
    CHECK(yozora_home_move(moved, 5, 2, 2) == 0);
    CHECK(yozora_home_move(moved, 5, 5, 0) == 0);
    CHECK(yozora_home_move(moved, 5, 0, 5) == 0);
    CHECK(yozora_home_move(NULL, 5, 0, 1) == 0);
    { const size_t want[] = { 4, 1, 2, 3, 0 }; CHECK(indices_are(moved, 5, want, 5)); }

    if (failures)
        return 1;
    puts("test_home: ok");
    return 0;
}
