#ifndef YOZORA_PASSWORD_H
#define YOZORA_PASSWORD_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* the longest login and password kept, in bytes of utf-8. a longer one is no password a person typed */
#define YOZORA_PASSWORD_USER_MAX 512
#define YOZORA_PASSWORD_MAX 1024
/* the longest site: a host of 253 bytes, a colon and a port */
#define YOZORA_PASSWORD_SITE_MAX 260

/* the site a password belongs to: the host of an https address in lower case without a leading www., with the port when it is not 443.
   an address that is not https, has a login in it (user@host) or a host with other characters than letters, digits, dots and hyphens has
   no site: a password sent over plain http is not kept and a page there is not filled. returns 1 and writes the site with its terminator,
   0 with an empty out when there is none or it does not fit */
int yozora_password_site(const char *address, char *out, size_t capacity);

typedef enum {
    /* nothing to ask: no password, one too long, a site the person said never for, or the stored one is the same */
    YOZORA_PASSWORD_IGNORE,
    /* no password is stored for this login */
    YOZORA_PASSWORD_SAVE,
    /* the login has another password stored */
    YOZORA_PASSWORD_UPDATE
} yozora_password_offer;

/* what to ask after a form with a password was sent. stored is the password kept for this site and login, NULL for none. never is not 0
   when the person said never for this site */
yozora_password_offer yozora_password_decide(const char *user, const char *password, const char *stored, int never);

#ifdef __cplusplus
}
#endif
#endif
