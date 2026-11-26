#include "yozora_home.h"
#include <stdio.h>
#include <string.h>

void yozora_home_order_default(uint8_t order[YOZORA_HOME_BLOCKS])
{
    for (uint8_t i = 0; i < YOZORA_HOME_BLOCKS; ++i)
        order[i] = i;
}

static int is_permutation(const uint8_t order[YOZORA_HOME_BLOCKS])
{
    unsigned seen = 0;
    for (int i = 0; i < YOZORA_HOME_BLOCKS; ++i) {
        if (order[i] >= YOZORA_HOME_BLOCKS)
            return 0;
        seen |= 1u << order[i];
    }
    return seen == (1u << YOZORA_HOME_BLOCKS) - 1;
}

int yozora_home_order_parse(const char *text, uint8_t order[YOZORA_HOME_BLOCKS])
{
    uint8_t parsed[YOZORA_HOME_BLOCKS];
    if (text) {
        int ok = 1;
        for (int i = 0; i < YOZORA_HOME_BLOCKS && ok; ++i) {
            if (*text < '0' || *text > '9') {
                ok = 0;
                break;
            }
            parsed[i] = (uint8_t)(*text++ - '0');
            if (i + 1 < YOZORA_HOME_BLOCKS) {
                if (*text != ',')
                    ok = 0;
                else
                    ++text;
            }
        }
        if (ok && !*text && is_permutation(parsed)) {
            for (int i = 0; i < YOZORA_HOME_BLOCKS; ++i)
                order[i] = parsed[i];
            return 1;
        }
    }
    yozora_home_order_default(order);
    return 0;
}

size_t yozora_home_order_format(const uint8_t order[YOZORA_HOME_BLOCKS], char *out, size_t capacity)
{
    if (!out || !capacity)
        return 0;
    out[0] = 0;
    if (!is_permutation(order))
        return 0;
    int written = snprintf(out, capacity, "%u,%u,%u", (unsigned)order[0], (unsigned)order[1], (unsigned)order[2]);
    if (written < 0 || (size_t)written >= capacity) {
        out[0] = 0;
        return 0;
    }
    return (size_t)written;
}

static int listed(const char *item, const char *const *list, size_t count)
{
    for (size_t i = 0; i < count; ++i) {
        if (list[i] && !strcmp(item, list[i]))
            return 1;
    }
    return 0;
}

/* an address already written: history rows are unique, but placed lists come from stored settings of any version */
static int written(const char *const *items, const size_t *out, size_t written_count, const char *item)
{
    for (size_t i = 0; i < written_count; ++i) {
        if (!strcmp(items[out[i]], item))
            return 1;
    }
    return 0;
}

size_t yozora_home_arrange(const char *const *items, size_t count, const char *const *placed, size_t placed_count,
                           const char *const *hidden, size_t hidden_count, size_t *out, size_t capacity)
{
    size_t total = 0;
    if (!items || !out)
        return 0;
    if (!placed)
        placed_count = 0;
    if (!hidden)
        hidden_count = 0;
    for (size_t p = 0; p < placed_count && total < capacity; ++p) {
        if (!placed[p] || listed(placed[p], hidden, hidden_count) || written(items, out, total, placed[p]))
            continue;
        for (size_t i = 0; i < count; ++i) {
            if (items[i] && !strcmp(items[i], placed[p])) {
                out[total++] = i;
                break;
            }
        }
    }
    for (size_t i = 0; i < count && total < capacity; ++i) {
        if (!items[i] || listed(items[i], hidden, hidden_count) || written(items, out, total, items[i]))
            continue;
        out[total++] = i;
    }
    return total;
}

int yozora_home_move(size_t *order, size_t count, size_t from, size_t to)
{
    if (!order || from >= count || to >= count || from == to)
        return 0;
    size_t moving = order[from];
    if (from < to)
        memmove(order + from, order + from + 1, (to - from) * sizeof *order);
    else
        memmove(order + to + 1, order + to, (from - to) * sizeof *order);
    order[to] = moving;
    return 1;
}
