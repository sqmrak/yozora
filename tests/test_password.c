#include "yozora_password.h"
#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "test_password: %s:%d: %s\n", __FILE__, __LINE__, #condition); ++failures; } } while (0)

static int site_is(const char *address, const char *want)
{
    char out[YOZORA_PASSWORD_SITE_MAX];
    memset(out, 'x', sizeof out);
    return yozora_password_site(address, out, sizeof out) == 1 && !strcmp(out, want);
}

static int has_no_site(const char *address)
{
    char out[YOZORA_PASSWORD_SITE_MAX];
    memset(out, 'x', sizeof out);
    return yozora_password_site(address, out, sizeof out) == 0 && out[0] == 0;
}

int main(void)
{
    CHECK(site_is("https://example.com/login", "example.com"));
    CHECK(site_is("https://Accounts.Example.COM/?next=/", "accounts.example.com"));
    CHECK(site_is("HTTPS://www.vk.com#top", "vk.com"));
    CHECK(site_is("https://example.com", "example.com"));
    CHECK(site_is("https://example.com:443/a", "example.com"));
    CHECK(site_is("https://example.com:8443/a", "example.com:8443"));
    CHECK(site_is("https://www.example.com:8443", "example.com:8443"));
    CHECK(site_is("https://wwwexample.com/", "wwwexample.com"));
    /* a password over plain http or another scheme has no site */
    CHECK(has_no_site("http://example.com/login"));
    CHECK(has_no_site("ftp://example.com/"));
    CHECK(has_no_site("javascript:alert(1)"));
    CHECK(has_no_site("https:/example.com"));
    CHECK(has_no_site(""));
    CHECK(has_no_site(NULL));
    /* a login inside the address, odd characters, empty hosts and broken ports */
    CHECK(has_no_site("https://bank.com@evil.com/"));
    CHECK(has_no_site("https://user:pass@example.com/"));
    CHECK(has_no_site("https:///path"));
    CHECK(has_no_site("https://www./"));
    CHECK(has_no_site("https://exa_mple.com/"));
    CHECK(has_no_site("https://exa mple.com/"));
    CHECK(has_no_site("https://.example.com/"));
    CHECK(has_no_site("https://-example.com/"));
    CHECK(has_no_site("https://example.com:/"));
    CHECK(has_no_site("https://example.com:0/"));
    CHECK(has_no_site("https://example.com:08443/"));
    CHECK(has_no_site("https://example.com:65536/"));
    CHECK(has_no_site("https://example.com:1234567/"));
    CHECK(has_no_site("https://example.com:12a/"));
    CHECK(has_no_site("https://[::1]/"));

    /* capacity: the site and its terminator must fit */
    char small[12];
    CHECK(yozora_password_site("https://example.com/", small, 12) == 1 && !strcmp(small, "example.com"));
    CHECK(yozora_password_site("https://example.com/", small, 11) == 0 && small[0] == 0);
    CHECK(yozora_password_site("https://example.com/", small, 0) == 0);
    CHECK(yozora_password_site("https://example.com/", NULL, 12) == 0);
    char long_host[300];
    memcpy(long_host, "https://", 8);
    memset(long_host + 8, 'a', 254);
    memcpy(long_host + 262, ".com", 5);
    CHECK(has_no_site(long_host));

    CHECK(yozora_password_decide("me", "secret", NULL, 0) == YOZORA_PASSWORD_SAVE);
    CHECK(yozora_password_decide("", "secret", NULL, 0) == YOZORA_PASSWORD_SAVE);
    CHECK(yozora_password_decide(NULL, "secret", NULL, 0) == YOZORA_PASSWORD_SAVE);
    CHECK(yozora_password_decide("me", "secret", "old", 0) == YOZORA_PASSWORD_UPDATE);
    CHECK(yozora_password_decide("me", "secret", "secret", 0) == YOZORA_PASSWORD_IGNORE);
    CHECK(yozora_password_decide("me", "secret", NULL, 1) == YOZORA_PASSWORD_IGNORE);
    CHECK(yozora_password_decide("me", "", NULL, 0) == YOZORA_PASSWORD_IGNORE);
    CHECK(yozora_password_decide("me", NULL, NULL, 0) == YOZORA_PASSWORD_IGNORE);
    char big[YOZORA_PASSWORD_MAX + 2];
    memset(big, 'p', sizeof big - 1);
    big[sizeof big - 1] = 0;
    CHECK(yozora_password_decide("me", big, NULL, 0) == YOZORA_PASSWORD_IGNORE);
    big[YOZORA_PASSWORD_MAX] = 0;
    CHECK(yozora_password_decide("me", big, NULL, 0) == YOZORA_PASSWORD_SAVE);
    char user[YOZORA_PASSWORD_USER_MAX + 2];
    memset(user, 'u', sizeof user - 1);
    user[sizeof user - 1] = 0;
    CHECK(yozora_password_decide(user, "secret", NULL, 0) == YOZORA_PASSWORD_IGNORE);

    if (failures)
        return 1;
    puts("test_password: ok");
    return 0;
}
