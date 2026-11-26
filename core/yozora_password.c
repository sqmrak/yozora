#include "yozora_password.h"
#include <string.h>

static char lower(char c)
{
    return c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
}

int yozora_password_site(const char *address, char *out, size_t capacity)
{
    static const char scheme[] = "https://";
    if (!out || !capacity)
        return 0;
    out[0] = 0;
    if (!address)
        return 0;
    for (size_t i = 0; i < sizeof scheme - 1; ++i) {
        if (lower(address[i]) != scheme[i])
            return 0;
    }
    const char *host = address + sizeof scheme - 1;
    size_t length = strcspn(host, "/?#");
    /* a login in the address would make "bank.com@evil.com" read as the bank */
    if (memchr(host, '@', length))
        return 0;
    size_t name = length;
    const char *colon = memchr(host, ':', length);
    if (colon)
        name = (size_t)(colon - host);
    if (name >= 4 && lower(host[0]) == 'w' && lower(host[1]) == 'w' && lower(host[2]) == 'w' && host[3] == '.') {
        host += 4;
        name -= 4;
        length -= 4;
    }
    if (!name || name > 253 || host[0] == '.' || host[0] == '-')
        return 0;
    for (size_t i = 0; i < name; ++i) {
        char c = lower(host[i]);
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-'))
            return 0;
    }
    size_t port_length = length - name;
    const char *port = host + name;
    if (port_length) {
        /* ":" alone or a port that is not 1 to 65535 in digits is no address */
        if (port_length < 2 || port_length > 6)
            return 0;
        unsigned value = 0;
        for (size_t i = 1; i < port_length; ++i) {
            if (port[i] < '0' || port[i] > '9')
                return 0;
            value = value * 10 + (unsigned)(port[i] - '0');
        }
        if (!value || value > 65535 || port[1] == '0')
            return 0;
        if (value == 443)
            port_length = 0;
    }
    if (name + port_length + 1 > capacity)
        return 0;
    for (size_t i = 0; i < name; ++i)
        out[i] = lower(host[i]);
    memcpy(out + name, port, port_length);
    out[name + port_length] = 0;
    return 1;
}

yozora_password_offer yozora_password_decide(const char *user, const char *password, const char *stored, int never)
{
    if (!password || !password[0] || never)
        return YOZORA_PASSWORD_IGNORE;
    if (strlen(password) > YOZORA_PASSWORD_MAX || (user && strlen(user) > YOZORA_PASSWORD_USER_MAX))
        return YOZORA_PASSWORD_IGNORE;
    if (!stored)
        return YOZORA_PASSWORD_SAVE;
    return strcmp(stored, password) ? YOZORA_PASSWORD_UPDATE : YOZORA_PASSWORD_IGNORE;
}
