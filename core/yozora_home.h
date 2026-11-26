#ifndef YOZORA_HOME_H
#define YOZORA_HOME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* the blocks of the start page, top to bottom in the order the person chose: the logo with the name, the tiles of the visited sites, the favorites */
enum { YOZORA_HOME_BRAND, YOZORA_HOME_SITES, YOZORA_HOME_FAVORITES, YOZORA_HOME_BLOCKS };

/* the order a person starts with */
void yozora_home_order_default(uint8_t order[YOZORA_HOME_BLOCKS]);

/* reads "1,0,2". the text must name every block once, with nothing else around it. returns 1 and fills order, or returns 0 and fills the default
   order (a null or damaged text is a stored value of another version, not an error to show) */
int yozora_home_order_parse(const char *text, uint8_t order[YOZORA_HOME_BLOCKS]);

/* writes the text parse reads back, with the terminator. returns its length, 0 when capacity is too small or order is not a permutation */
size_t yozora_home_order_format(const uint8_t order[YOZORA_HOME_BLOCKS], char *out, size_t capacity);

/* the most addresses a section keeps in its stored order or its list of hidden sites, older ones beyond it are dropped */
#define YOZORA_HOME_LIST_MAX 64

/* the tiles of a section in the order to show them. items are the addresses in their natural order (most visited first, or the favorites as
   the store lists them), placed are the addresses the person put in order by hand, hidden the ones taken off the page. writes indices into
   items: the placed ones first in their placed order, then the rest in natural order, none hidden and none twice. a null entry is skipped.
   returns how many indices were written, at most capacity */
size_t yozora_home_arrange(const char *const *items, size_t count, const char *const *placed, size_t placed_count,
                           const char *const *hidden, size_t hidden_count, size_t *out, size_t capacity);

/* moves the entry at from to the place to, the ones between shift by one. returns 1 when it moved, 0 when from equals to or either is
   outside count */
int yozora_home_move(size_t *order, size_t count, size_t from, size_t to);

#ifdef __cplusplus
}
#endif
#endif
