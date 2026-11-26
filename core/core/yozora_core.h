#ifndef YOZORA_CORE_H
#define YOZORA_CORE_H

#include "yozora_types.h"
#include "yozora_scene.h"
#include <stddef.h>
#include "../yozora_hls.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* WebCore runs on one thread for the whole process so a busy page never stops the caller. every call may come
   from one interface thread. calls that change the page return at once and the result shows in state, status
   and picture a moment later, pictures come from yozora_core_tick, which never waits */
typedef struct yozora_core yozora_core;
typedef enum { YOZORA_LOAD_IDLE, YOZORA_LOAD_LOADING, YOZORA_LOAD_COMPLETE, YOZORA_LOAD_FAILED } yozora_load_state;
typedef enum { YOZORA_PAGE_ERROR_OTHER, YOZORA_PAGE_ERROR_DNS, YOZORA_PAGE_ERROR_CONNECTION, YOZORA_PAGE_ERROR_TIMEOUT, YOZORA_PAGE_ERROR_TLS, YOZORA_PAGE_ERROR_INTERRUPTED } yozora_page_error;
yozora_page_error yozora_core_page_error(yozora_core *core);
/* what the phone is: the core sizes its caches, tiles and decoding threads from it */
typedef struct {
    unsigned cores;
    unsigned memory_mb;
} yozora_device;
/* YOZORA_DEVICE_CORES and YOZORA_DEVICE_MEMORY_MB override what the system reports, for testing the smaller profiles */
void yozora_device_info(yozora_device *device);
/* call before UIApplicationMain: ios permits one MAP_JIT region, system framework startup can reserve it first */
void yozora_initialize_javascript(void);
/* before yozora_initialize_javascript: 0 keeps scripts out of the jit for this run, as YOZORA_NO_JIT does.
   the jit is chosen once while JavaScriptCore starts, so a later change counts at the next launch */
void yozora_set_jit_requested(int enabled);
typedef struct {
    /* the build has a jit for this cpu */
    int compiled;
    /* what the setting asked for in this run, and whether YOZORA_NO_JIT in the environment forced it off */
    int requested;
    int forced_off;
    /* what JavaScriptCore runs after it started: baseline jit, dfg tier and regexp jit. a phone that refuses
       executable memory turns them off again while the allocator starts, so active can be 0 with requested 1 */
    int active;
    int dfg;
    int regexp;
    /* 1 when the dfg tier compiles on a thread of its own, 0 when it compiles on the thread that runs the script (the default on armv7) */
    int concurrent;
    /* 1 when the optimizing compiler may run (arm64 phones with 1.7 GB or more), 0 when it is not built or the memory is short */
    int ftl;
    /* the jit executable memory: bytes committed to compiled code and the pool size (0 when the jit is not
       running). a pool that fills leaves the rest of the functions in the interpreter, silently */
    unsigned long long pool_used;
    unsigned long long pool_size;
} yozora_jit_info;
void yozora_jit_info_read(yozora_jit_info *info);

/* what the user chose in the settings, for every page of the process */
typedef struct {
    /* 0 turns the scripts of pages off */
    int javascript;
    /* the size of page text in percent, 50 to 200 */
    int text_zoom_percent;
    /* 1 refuses cookies of sites other than the page unless they already have some */
    int block_third_party_cookies;
    /* 1 asks pages for fewer animations and runs their animation frames at 30 a second */
    int reduce_motion;
    /* 0 draws pages with the fonts of the system instead of the fonts the sites send */
    int web_fonts;
    /* 1 tells pages that the user prefers a dark appearance, sites that support it switch their colors */
    int dark_appearance;
    /* 0 leaves WebGL out of pages (getContext('webgl') answers null), 1 gives them contexts over the OpenGL
       ES of the system. the interface always turns it on */
    int webgl;
    /* 1 offers a link a person followed to the other apps first: addresses with a scheme of another app (tg:,
       mailto:, tel:) and, on a system that has universal links, addresses of other sites that an installed app
       claims. the interface takes them with yozora_core_take_external. 0 leaves every navigation to the page, the
       headless runner never has an interface to answer. the interface turns it on */
    int external_links;
} yozora_options;
/* applies at once to open pages and later ones. defaults: scripts on, 100 percent, cookies of all sites,
   motion as sites want, web fonts loaded, WebGL on */
void yozora_set_options(const yozora_options *options);
/* 1 paints tiles at one pixel for each point, the default keeps the screen scale while loading and scrolling */
void yozora_set_economy_raster(int enabled);
/* 1 while tiles are out of date or at a lower scale than the page wants, so the picture is not final yet */
int yozora_core_painting(yozora_core *core);
/* the headless snapshot api flattens layer scenes into horizontal tiles; the native interface takes scenes directly */
#define YOZORA_MAX_TILES 24
typedef struct {
    const uint8_t *pixels;
    size_t row_bytes;
    unsigned width;
    unsigned height;
    /* the top edge of the tile in the page, in points */
    int document_y;
    /* pixels for each point of this tile */
    float scale;
} yozora_tile;
typedef struct {
    yozora_tile tiles[YOZORA_MAX_TILES];
    unsigned count;
} yozora_frame;

/* waits until the core exists, the first call also starts the core thread */
yozora_core *yozora_core_create(const char *fonts, const char *roots, char *error, size_t capacity);
/* the file of root certificates for every request from now on (page loads and translation); the file must stay while requests use it.
   a path the core cannot read is ignored */
void yozora_core_set_roots(const char *roots);
void yozora_core_destroy(yozora_core *core);
/* transfers ownership to the core thread, no calls may use core after this returns */
void yozora_core_destroy_async(yozora_core *core);
/* keeps a completed page in memory with tasks and loading suspended and raster pixels dropped. returns 0 if a
   load, media, popup, authentication question or open indexeddb connection or request prevents it. waits for
   the core thread, repeated suspend and resume calls do not nest */
int yozora_core_set_suspended(yozora_core *core, int suspended);
/* a user-opened window, with its opener kept by WebCore. the caller owns it and must destroy it */
yozora_core *yozora_core_take_popup(yozora_core *core);
/* a link the page wants another app to open, set by a tap, a click handler or a link the person followed. copies
   the address (at most capacity - 1 bytes, an address that does not fit is dropped) and returns 1, or returns 0
   when there is none. universal is 1 for an http or https address of another site: the page waits, the interface
   must answer with yozora_core_answer_external. universal is 0 for a scheme of another app, the page has
   dropped the navigation and no answer is expected */
int yozora_core_take_external(yozora_core *core, char *url, size_t capacity, int *universal);
/* the answer for a universal link: 1 when an app opened it, so the page stays, 0 to load it in the page. an answer
   when no link waits (the page moved on, stopped or closed meanwhile) does nothing */
void yozora_core_answer_external(yozora_core *core, int opened);
/* window.close requested by a page, the interface dismisses and destroys the window */
int yozora_core_close_requested(yozora_core *core);
/* returns 0 with a text for an address that cannot be a page, an address the page core refuses later ends in the failed state */
int yozora_core_load(yozora_core *core, const char *url, char *error, size_t capacity);
int yozora_core_back(yozora_core *core);
int yozora_core_forward(yozora_core *core);
int yozora_core_reload(yozora_core *core);
void yozora_core_stop(yozora_core *core);
/* size in points, the surface holds width * scale pixels, lowered if a side would pass 2048. a surface that
   cannot be allocated ends in the failed state with a message */
int yozora_core_resize(yozora_core *core, unsigned width, unsigned height, float scale);
/* hands over the held tiles when they changed since the last call, 0 when not. pixels stay valid for two more
   calls. a tile sits at its document_y minus the scroll position asked for last, so the page follows the
   finger while the core still paints ahead */
int yozora_core_tick(yozora_core *core, yozora_frame *frame);
/* takes a retained layer scene, image providers retain individual images before the caller releases the scene */
yozora_scene *yozora_core_take_scene(yozora_core *core);
/* moves the wanted scroll position at once and returns the distance moved, smaller than delta_y at the ends
   of the page. the page follows at its next pass */
int yozora_core_scroll(yozora_core *core, int delta_y);
/* a finger tap in view points: mouse move, press and release, so links, buttons, forms and script handlers all see a click */
void yozora_core_tap(yozora_core *core, int x, int y);
/* a finger of a drag, in view points, as page touch events (touchstart, touchmove, touchend, touchcancel):
   phase 0 begins, 1 moves, 2 ends, 3 cancels. no mouse events, so a drag selects nothing. carousels such as
   the YouTube Shorts feed move by them */
void yozora_core_touch(yozora_core *core, int phase, int x, int y);
/* 1 while the page called preventDefault on a touch event of the gesture in progress, the interface then
   leaves scrolling to the page. the answer comes one core pass after the event, so the first points of a drag
   can have scrolled already */
int yozora_core_touch_claimed(yozora_core *core);
/* stops the core thread from running pages, for the time the app is in the background */
void yozora_set_background(int background);
typedef enum {
    YOZORA_INPUT_NONE,
    YOZORA_INPUT_TEXT,
    YOZORA_INPUT_MULTILINE,
    YOZORA_INPUT_PASSWORD,
    YOZORA_INPUT_EMAIL,
    YOZORA_INPUT_URL,
    YOZORA_INPUT_NUMBER,
    YOZORA_INPUT_SEARCH
} yozora_input_kind;
/* what the focused element accepts, YOZORA_INPUT_NONE when no field or editable area has focus */
yozora_input_kind yozora_core_input_kind(yozora_core *core);
/* typed text as utf-8, a line feed is the return key. returns 0 when nothing is focused for editing */
int yozora_core_insert_text(yozora_core *core, const char *text);
int yozora_core_delete_backward(yozora_core *core);
/* the text an input method is composing, utf-8 (the kana of Japanese before they are converted): the page shows it underlined in
   the field, `caret_start` and `caret_end` are utf-16 units inside it. an empty text ends the composition with nothing in the field.
   returns 0 when nothing is focused for editing */
int yozora_core_set_composition(yozora_core *core, const char *text, int caret_start, int caret_end);
/* ends the composition: `text` replaces what was composed, NULL keeps the composed text as it stands */
int yozora_core_confirm_composition(yozora_core *core, const char *text);
/* scrolls the caret into the visible part of the page, for after the keyboard has covered the bottom */
void yozora_core_reveal_input(yozora_core *core);
yozora_load_state yozora_core_state(yozora_core *core);
const char *yozora_core_status(yozora_core *core);
int yozora_core_scroll_y(yozora_core *core);
/* the interface's requested offset, including movement not applied by WebCore yet */
int yozora_core_scroll_offset(yozora_core *core, uint64_t id, int *x, int *y);
/* one coherent copy for every layer in a display pass, a null core yields an empty state */
void yozora_core_read_scroll_state(yozora_core *core, yozora_scroll_state *state);
/* the zoom of the page layout in percent, 100 until a pinch changes it. it belongs to the site: another site starts at 100 */
int yozora_core_page_zoom(yozora_core *core);
/* zooms the layout to percent (50 to 300, held to it) and keeps the page row at focal_y points from the view
   top under it, the page reflows to the new width. the zoom shows in yozora_core_page_zoom once applied */
void yozora_core_set_page_zoom(yozora_core *core, int percent, int focal_y);
/* drops what the process can rebuild: resource and font caches, decoded images, the back list, a full script
   collection and the Skia caches */
void yozora_core_release_memory(yozora_core *core);
/* queues process-wide pressure cleanup without waiting for scripts, repeated pending requests are combined */
void yozora_release_memory_async(void);
/* the address being loaded, or the committed document address */
const char *yozora_core_url(yozora_core *core);
const char *yozora_core_title(yozora_core *core);
int yozora_core_can_go_back(yozora_core *core);
int yozora_core_can_go_forward(yozora_core *core);
/* 0 to 1 while loading */
float yozora_core_progress(yozora_core *core);
int yozora_core_is_secure(yozora_core *core);
/* the next line the page wrote to its console, 0 when none. the core keeps the last 200, so a page that fails
   to run shows why: an error with its source and line */
int yozora_core_take_console(yozora_core *core, char *line, size_t capacity);
/* returns 1 once for each top-level document that finished loading */
int yozora_core_take_visit(yozora_core *core, yozora_record *visit);

/* page translation. yozora_core_run_script evaluates a script in an isolated world of the top frame (the page
   does not see what it keeps, it sees the document) and returns the result when it is a string, NULL when not
   or when it throws. it waits for the core thread, call it from a thread that may wait. free the answer with
   free */
const char *yozora_translate_script(void);
char *yozora_core_run_script(yozora_core *core, const char *script);
/* a POST over https with the core roots (TLS 1.2 and newer on every ios, whatever the system offers). returns
   the status of the answer, or -1 and a failure text. free the answer with free. it blocks, call it from a
   thread of its own */
int yozora_http_post(const char *url, const char *content_type, const char *body, size_t length, int timeout_seconds,
                     char **answer, size_t *answer_length, char *error, size_t error_capacity);

/* the user agent the pages are fetched with: the stream proxy of the interface sends it too, so a server sees one browser */
const char *yozora_user_agent(void);

/* <video> and <audio> are WebCore elements, the core has no decoder and the system plays the stream. a media
   element that loads an http or https address makes the core queue an OPEN request with a new id, the
   interface opens a player for it, puts the video under the page where yozora_core_videos says (the page
   paints a transparent hole there, so what it draws over the video stays over it) and reports with
   yozora_core_media_event. ids are never reused */
typedef enum {
    YOZORA_MEDIA_OPEN = 1,
    YOZORA_MEDIA_PLAY,
    YOZORA_MEDIA_PAUSE,
    YOZORA_MEDIA_SEEK,
    YOZORA_MEDIA_VOLUME,
    YOZORA_MEDIA_RATE,
    /* the element let go of the stream, the id is not valid after it */
    YOZORA_MEDIA_CLOSE,
    /* the page asked for the full screen player (value 1) or to leave it (value 0). a video plays on the page until it is asked for */
    YOZORA_MEDIA_FULLSCREEN
} yozora_media_command;
typedef struct {
    yozora_media_command command;
    unsigned id;
    /* OPEN only: the stream, the title of the page and 0 for audio */
    char url[4096];
    char title[256];
    int video;
    /* OPEN only: the Cookie header the page would send for the stream and the page origin as Referer, empty
       when none. the system player sends neither, so the interface hands them to the stream proxy. a header
       that does not fit is left out, never cut */
    char cookie[4096];
    char referer[512];
    /* SEEK: seconds. VOLUME: 0 to 1. RATE: times the normal speed, PLAY starts at the last one */
    double value;
    /* VOLUME: 1 when the element is muted */
    int muted;
} yozora_media_request;
/* the next request of a page, 0 when there is none */
int yozora_core_take_media(yozora_core *core, yozora_media_request *request);
/* the stream of a media source: an OPEN of an address starting with "yozora-hls:" names its player id and
   this gives the stream (core/yozora_hls.h) for it, with a reference the caller releases with
   yozora_hls_release. null when there is none */
yozora_hls *yozora_core_mse_stream(yozora_core *core, unsigned id);
typedef enum {
    /* the picture moves at the rate that was asked for */
    YOZORA_MEDIA_PLAYING = 1,
    YOZORA_MEDIA_PAUSED,
    YOZORA_MEDIA_ENDED,
    /* value is the position in seconds */
    YOZORA_MEDIA_TIME,
    /* value is the length in seconds, 0 when the stream has none (live) */
    YOZORA_MEDIA_DURATION,
    /* value is 2 for a network failure, 3 when the stream cannot be decoded and 4 when it is not a stream the system plays */
    YOZORA_MEDIA_ERROR,
    /* the size of the picture in pixels, value is the width and extra the height, 0 and 0 for sound only */
    YOZORA_MEDIA_SIZE,
    /* value is 1 when enough is loaded to play on and 0 when playback ran dry and waits for data */
    YOZORA_MEDIA_READY,
    /* the first picture can be shown */
    YOZORA_MEDIA_FRAME,
    /* a seek finished, value is the position */
    YOZORA_MEDIA_SEEKED,
    /* the loaded part around the position, value is its start and extra its end in seconds */
    YOZORA_MEDIA_BUFFERED,
    /* the person left the full screen player, the element leaves its full screen state and the page hears fullscreenchange */
    YOZORA_MEDIA_FULLSCREEN_LEFT
} yozora_media_event_kind;
/* what the player did, for the element that asked. an id the core does not know is ignored */
void yozora_core_media_event(yozora_core *core, unsigned id, yozora_media_event_kind kind, double value, double extra);
/* where the page videos are as of the last layout, in view points of the view as it stands at that layout (the
   scroll position is not added: a fixed or sticky player keeps its place on screen while the page scrolls, and the
   interface fixes the place in the layer that holds the video when the scene of the same layout arrives). a
   hidden video or one without a player is not listed. layer is the scene layer id that holds the video, 0 when unknown: the system player picture goes into that layer over its tiles and under what lies
   over it, so a black background painted under the video does not hide it. without a layer it lies under the
   whole page and shows only through what is clear */
#define YOZORA_MAX_VIDEOS 8
typedef struct {
    unsigned id;
    int x, y, width, height;
    uint64_t layer;
} yozora_video;
int yozora_core_videos(yozora_core *core, yozora_video *out, int capacity);

/* subresource requests to listed analytics, pixel and ad hosts fail before a connection opens. shared by
   every core, on by default. a page opened by address is never blocked */
void yozora_set_tracker_blocking(int enabled);
int yozora_tracker_blocking(void);
/* requests stopped since the process started */
unsigned long long yozora_blocked_requests(void);
/* requests stopped on the page this core shows, counted from the start of its last load */
unsigned yozora_core_blocked_on_page(yozora_core *core);

/* the user's rules for the blocker in adblock plus syntax (yozora_filter.h), on top of the shipped ones, each
   call replaces the set before. the report counts lines taken, skipped, unsupported and refused, it may be
   NULL */
typedef struct {
    size_t added;
    size_t skipped;
    size_t unsupported;
    size_t invalid;
    size_t dropped;
} yozora_adblock_report;
void yozora_adblock_set_rules(const char *text, size_t length, yozora_adblock_report *report);
/* nothing is blocked or hidden on pages of a host and its subdomains while it is paused. nothing happens in the private session */
void yozora_adblock_set_site_paused(const char *host, int paused);
int yozora_adblock_site_paused(const char *host);

/* the directory for what sites keep: cookies.db and local-storage.txt. call it before the first core is
   created, without it cookies and local storage live in memory. returns 0 with a text when it cannot be
   written */
int yozora_set_site_data(const char *directory, char *error, size_t capacity);
/* writes local storage now, the app calls it when it goes to the background */
void yozora_flush_site_data(void);
/* forgets every cookie and all local storage, logins included */
void yozora_clear_site_data(void);
/* the Cookie header the current session (the profile's, or the private one while it is on) would send to the
   address: name=value pairs, HttpOnly and Secure ones included. returns its length, 0 when none match or the
   address is not valid, -1 when it does not fit capacity (out is empty then). waits for the core thread, call it
   from a thread that may wait */
int yozora_cookie_header(const char *url, char *out, size_t capacity);

/* the private session: pages that start keep cookies, local storage and databases in memory and use no stored
   responses or bytecode, pages started before keep what they had. turn it on before the first private page
   exists and off once the profile's pages run again, no profile page may load while it is on. history is the
   interface's to drop. shared by every core, off at start */
void yozora_set_private_session(int enabled);
int yozora_private_session(void);
/* forgets the cookies, local storage and databases the private session made, called when the last private tab
   has gone */
void yozora_clear_private_session(void);

/* keeps responses of plain GET requests in this directory, which must exist, belong to the user and have mode
   0700. a response with a freshness lifetime is served from disk until it expires, one with a validator is
   asked about first, back and forward use any stored copy. one cache per process, call it once before the
   first load. returns 0 and fills the error text when the directory is unusable */
int yozora_set_http_cache(const char *directory, size_t max_bytes, char *error, size_t capacity);
/* removes every stored response */
void yozora_clear_http_cache(void);
/* waits until responses queued for storing are on disk, for the moment the app leaves the foreground */
void yozora_flush_http_cache(void);

/* keeps the bytecode of external scripts in this directory (it must exist, belong to the user and have mode
   0700). a script loaded again, in this run or the next, skips the parser and bytecode generator. one cache
   per process, call it once before the first core. returns 0 and fills the error text when the directory is
   unusable */
int yozora_set_bytecode_cache(const char *directory, size_t max_bytes, char *error, size_t capacity);
/* removes every stored script */
void yozora_clear_bytecode_cache(void);
/* writes the bytecode that pages gathered so far, for the moment the app leaves the foreground */
void yozora_flush_bytecode_cache(void);
/* files mapped for a script, files that did not match the script and were replaced, files written and bytes written */
void yozora_bytecode_cache_statistics(unsigned long long *loaded, unsigned long long *stale, unsigned long long *stored, unsigned long long *bytes);

/* files pages hand over instead of showing them. a download keeps going while the tab changes, the list is
   the same for every tab */
/* a paused download keeps its part file and counts as unfinished: it stays on the list until it is resumed or cancelled */
enum { YOZORA_DOWNLOAD_QUEUED, YOZORA_DOWNLOAD_RUNNING, YOZORA_DOWNLOAD_DONE, YOZORA_DOWNLOAD_FAILED, YOZORA_DOWNLOAD_CANCELLED, YOZORA_DOWNLOAD_PAUSED };
typedef struct {
    unsigned id;
    int state;
    /* bytes written, and bytes expected, 0 when the server did not say */
    long long received;
    long long total;
    /* the file name, the address while it is not known yet */
    char name[256];
    char path[1024];
    char error[160];
} yozora_download;
/* the folder the files go to, set before the first page. it is made when the first file comes */
void yozora_downloads_set_directory(const char *path);
/* the downloads of this run, newest first. any thread */
int yozora_downloads_list(yozora_download *out, int capacity);
void yozora_download_cancel(unsigned id);
/* stops a queued or running download and keeps what came. resuming sends a Range request that must match the
   first answer (same validator, a 206 that starts where the file ends), a server that cannot do it makes the
   download start over. other states are left alone. downloads end with the app, a part file of an earlier run
   is not picked up */
/* the app is hidden (after yozora_set_background(1)) and downloads go on: the thread runs again to serve
   transfers, pages are hidden and make no passes or frames. 0 holds it still again, when the last download
   ended or the time the system gives a hidden app is over. yozora_set_background(0) ends the quiet run. the
   system ends a hidden app that runs too long, so the interface pauses downloads before that */
void yozora_set_background_downloads(int enabled);
/* called on the core thread when a download ended (done, failed or cancelled) or was paused, with the id the
   list shows. it must return quickly and only hand the event to another thread */
typedef void (*yozora_download_observer)(unsigned id, int state, void *context);
void yozora_downloads_set_observer(yozora_download_observer observer, void *context);
void yozora_download_pause(unsigned id);
void yozora_download_resume(unsigned id);
/* takes a finished, failed or cancelled entry off the list, the file stays */
void yozora_download_forget(unsigned id);

/* a site asked for a name and a password. the interface shows the question and answers with both strings, or
   a null user to refuse, and then the page shows what the server sent */
typedef struct {
    unsigned id;
    char host[256];
    int port;
    char realm[256];
    /* "Basic" or "Digest" */
    char scheme[16];
    int secure;
    /* how many times the server refused the credentials of this question */
    int failures;
} yozora_auth_request;
int yozora_core_take_auth(yozora_core *core, yozora_auth_request *out);
void yozora_core_auth_respond(yozora_core *core, unsigned id, const char *user, const char *password);

/* geolocation. a page that asks for the position puts a question here (its origin address), the interface
   answers with yozora_core_geolocation_answer and, while yozora_core_geolocation_wanted says 1, runs the
   location manager and passes fixes with yozora_core_geolocation_position. a value the system does not know
   is NaN, a denial or failure goes through yozora_core_geolocation_error */
typedef struct {
    unsigned id;
    char origin[256];
} yozora_geolocation_request;
int yozora_core_take_geolocation_request(yozora_core *core, yozora_geolocation_request *out);
void yozora_core_geolocation_answer(yozora_core *core, unsigned id, int allow);
/* 1 while a page watches the position, high_accuracy then tells whether it wants the best the device has */
int yozora_core_geolocation_wanted(yozora_core *core, int *high_accuracy);
void yozora_core_geolocation_position(yozora_core *core, double latitude, double longitude, double accuracy, double altitude, double altitude_accuracy,
    double heading, double speed, double timestamp);
/* denied is 1 when the person or the system refused the position, 0 when it cannot be had now */
void yozora_core_geolocation_error(yozora_core *core, int denied, const char *message);

/* notifications. a page that asks for the permission puts a question here (its origin address), the interface
   answers with yozora_core_notification_answer and the core remembers the decision. a shown notification goes
   into a second queue taken with yozora_core_take_notification: a banner while the app is shown, a local
   notification while hidden */
typedef struct {
    unsigned id;
    char origin[256];
} yozora_notification_request;
int yozora_core_take_notification_request(yozora_core *core, yozora_notification_request *out);
void yozora_core_notification_answer(yozora_core *core, unsigned id, int allow);
typedef struct {
    char origin[256];
    char title[256];
    char body[512];
    char tag[128];
} yozora_notification;
int yozora_core_take_notification(yozora_core *core, yozora_notification *out);

/* what the person decided for sites, kept in files of the site data directory (yozora_set_site_data):
   geolocation and notifications per origin such as "https://example.com", and the blocker pause per host. the
   interface lists and takes back decisions, a site without one asks again. nothing is added in the private
   session */
typedef enum {
    YOZORA_SITE_GEOLOCATION = 0,
    YOZORA_SITE_NOTIFICATIONS = 1,
    /* the sites where the ad blocker is paused: "allowed" of an entry is 1 */
    YOZORA_SITE_ADBLOCK_PAUSED = 2
} yozora_site_kind;
size_t yozora_site_count(yozora_site_kind kind);
/* the index-th site, newest decision first: its key into key of capacity bytes and whether it is allowed. 0
   when there is no such site */
int yozora_site_entry(yozora_site_kind kind, size_t index, char *key, size_t capacity, int *allowed);
void yozora_site_remove(yozora_site_kind kind, const char *key);
void yozora_site_clear(yozora_site_kind kind);

/* the text the user selected. places are in document points with the scroll position they were taken at, the
   interface puts them on screen by their difference to the position of the moment */
typedef struct {
    int active;
    int start_x, start_y, start_height;
    int end_x, end_y, end_height;
    int scroll_y;
    /* the selected text as utf-8, cut at the end of the buffer */
    char text[2048];
} yozora_selection;
/* selects the word at a point of the view */
void yozora_core_select_word(yozora_core *core, int x, int y);
/* selects from one point to another, both at their words. the interface moves the end that the user drags and keeps the other */
void yozora_core_select_range(yozora_core *core, int from_x, int from_y, int to_x, int to_y);
void yozora_core_select_all(yozora_core *core);
void yozora_core_select_clear(yozora_core *core);
/* the selection as of the last pass of the core thread, 0 when nothing is selected */
int yozora_core_selection(yozora_core *core, yozora_selection *out);

/* what lies under a finger that stays down. a link, an image or a video is reported instead of a selection, other text
   is selected as before. places are in view points. addresses are absolute http or https: an inline data
   image or a javascript link is no target, an address that does not fit is dropped, so a link around a huge
   image still shows its own address */
#define YOZORA_HIT_URL 2048
typedef struct {
    int x, y;
    char link[YOZORA_HIT_URL];
    /* the text the link shows, cut at the end of the buffer, empty when the link holds a picture */
    char link_text[256];
    char image[YOZORA_HIT_URL];
    /* the source of the audio or video element under the finger, empty when there is none. a stream the page
       builds in memory (a blob address) is no target */
    char media[YOZORA_HIT_URL];
} yozora_hit;
void yozora_core_long_press(yozora_core *core, int x, int y);
/* the finger of a long press lifts at x, y (where the press began). a press that selected nothing and opened
   no sheet was a slow tap on a control, which Safari clicks on lift, and the click is sent here. a press that
   selected text or opened a sheet sends nothing */
void yozora_core_long_press_release(yozora_core *core, int x, int y);
/* the answers to long presses that found a link or an image, oldest first, 0 when there is none */
int yozora_core_take_hit(yozora_core *core, yozora_hit *out);
/* queues the file at an address a hit reported as a download, with the address of the page as the referrer and
   its cookies. the list of downloads shows it, and the core says in a message when the address cannot be
   downloaded. http and https only */
void yozora_core_download(yozora_core *core, const char *url);

/* the page as a desktop browser sees it: the user agent of Safari on a Mac and a layout at least 980 points
   wide where the zoom floor allows (50 percent shows 640 points on a phone), applied to each new site until
   turned off. the interface reloads, the page does not change by itself. a core starts in the mobile mode */
void yozora_core_set_desktop(yozora_core *core, int enabled);
int yozora_core_desktop(yozora_core *core);

/* find in page: every match is marked, the current one is selected and scrolled into view. direction 0 starts
   at the top, 1 goes to the next match and -1 to the previous, both wrap. matches are counted up to
   YOZORA_FIND_MAX, case is ignored, an empty text clears the search */
#define YOZORA_FIND_MAX 500
typedef struct {
    /* 1 while a search is shown on the page */
    int active;
    /* matches found, 0 when there is none, and the place of the current one from 1 */
    int count;
    int index;
} yozora_find_state;
void yozora_core_find(yozora_core *core, const char *text, int direction);
/* removes the marks and the selection of the search */
void yozora_core_find_clear(yozora_core *core);
/* the result of the last search as of the last pass of the core thread */
void yozora_core_find_state(yozora_core *core, yozora_find_state *out);

/* controls the page asks the person to operate. the interface shows the question and answers by id, an
   unanswered question stays open and a new page or a closed popup makes an answer to an old id harmless */

/* a drop-down list (select): the items as the page lists them, group labels and separators included, the
   select's place in view points and the item chosen now. an answer of -1, or the id of a list that closed,
   changes nothing */
#define YOZORA_CHOICE_MAX 256
#define YOZORA_CHOICE_TEXT 128
enum { YOZORA_CHOICE_DISABLED = 1, YOZORA_CHOICE_GROUP = 2, YOZORA_CHOICE_SEPARATOR = 4, YOZORA_CHOICE_SELECTED = 8 };
typedef struct {
    char text[YOZORA_CHOICE_TEXT];
    int flags;
} yozora_choice_item;
typedef struct {
    unsigned id;
    /* items listed (at most YOZORA_CHOICE_MAX, a longer list is cut) and the one chosen, -1 for none */
    int count;
    int selected;
    /* 1 for a select with multiple, which the page draws as a list in its own layout: chosen items carry
       YOZORA_CHOICE_SELECTED and the answer is yozora_core_choices_respond with every item that stays chosen.
       the core takes a tap on such a list and the page sees it only through that answer */
    int multiple;
    int x, y, width, height;
    yozora_choice_item items[YOZORA_CHOICE_MAX];
} yozora_choice;
int yozora_core_take_choice(yozora_core *core, yozora_choice *out);
void yozora_core_choice_respond(yozora_core *core, unsigned id, int index);
/* the answer for a multiple list: the indexes of the chosen items (a count of -1 changes nothing). the select
   options take that state and the page hears one input and one change event when it differs from before */
void yozora_core_choices_respond(yozora_core *core, unsigned id, const int *indexes, int count);

/* a file field: what it accepts as written in accept (types and extensions, comma separated) and whether more
   than one file is allowed. the answer lists paths of readable files, none when cancelled. the page reads
   them in place, so they stay until the page is closed */
typedef struct {
    unsigned id;
    int multiple;
    char accept[512];
} yozora_file_request;
int yozora_core_take_files(yozora_core *core, yozora_file_request *out);
void yozora_core_files_respond(yozora_core *core, unsigned id, const char *const *paths, int count);

/* a date and time field: its type ("date", "time", "datetime-local", "month" or "week"), the value in that
   type's format ("2026-11-15", "13:45", "2026-11-15T13:45", "2026-11", "2026-W46", empty for none) and the
   limits as the page counts them (ms since 1970 for date, datetime-local and week, ms since midnight for
   time, months since 1970 for month) */
typedef struct {
    unsigned id;
    char type[24];
    char value[64];
    double minimum, maximum, step;
    int x, y, width, height;
} yozora_date_request;
int yozora_core_take_date(yozora_core *core, yozora_date_request *out);
/* a value in the format of the type sets the field, null leaves it as it was */
void yozora_core_date_respond(yozora_core *core, unsigned id, const char *value);

/* a color field: the color as "#rrggbb" (transparency is cut to the opaque part, the field has no alpha) and
   where it is. the answer is "#rrggbb" or "#RRGGBB" in either case, null leaves the field as it was */
typedef struct {
    unsigned id;
    char value[16];
    int x, y, width, height;
} yozora_color_request;
int yozora_core_take_color(yozora_core *core, yozora_color_request *out);
void yozora_core_color_respond(yozora_core *core, unsigned id, const char *value);

/* blocks of the page that scroll on their own, such as overflow auto panels and text areas. the core
   publishes them after every layout, the interface asks which lies under the finger and sends the movement
   there before the rest goes to the page */
int yozora_core_scroll_inner(yozora_core *core, int x, int y, int dx, int dy, int *rest_dx, int *rest_dy);

/* time spent in each phase of yozora_core_tick since creation, for finding slow pages */
typedef struct {
    long long events_ms;
    long long rendering_ms;
    long long layout_ms;
    long long paint_ms;
    /* worker batches that rasterized content, geometry-only scene publications do not repaint tiles */
    long long paints;
    long long rendering_updates;
    /* layouts of the current document */
    long long layouts;
    /* tiles painted whole and tiles that only had a changed part painted again */
    long long tiles_full;
    long long tiles_partial;
    /* core thread passes, passes that came more than 100 ms after the one before, and the longest wait
       between two. a long wait is a script or layout that kept the thread and the picture stays as it was
       meanwhile */
    long long ticks;
    long long slow_ticks;
    long long longest_tick_gap_ms;
} yozora_core_stats;
void yozora_core_read_stats(yozora_core *core, yozora_core_stats *stats);

/* milliseconds since the core thread finished a pass, a page that does not answer keeps it, 0 in the background. any thread */
long long yozora_core_stalled_ms(void);
/* ends the script that keeps the core thread, the page goes on and its next script runs. returns 0 when none runs. any thread */
int yozora_stop_scripts(void);

#ifdef __cplusplus
}
#endif
#endif
