#include <fio.h>
#include <fiobj.h>
#include <http.h>
#include <stdlib.h>
#include <string.h>

// --- Types ---

typedef void (*fiow_handler)(http_s *h);
typedef void (*fiow_sse_handler)(http_sse_s *sse);
typedef void (*fiow_sse_msg_fn)(http_sse_s *sse, void *udata,
                                const char *msg, unsigned int msg_len);

// --- Handlers ---

static fiow_handler request_handler = NULL;
static fiow_sse_msg_fn sse_msg_handler = NULL;

static const char *allowed_origin = NULL;
static size_t allowed_origin_len = 0;

static const char *stream_prefix = NULL;
static size_t stream_prefix_len = 0;
static fiow_sse_handler stream_on_open = NULL;
static fiow_sse_handler stream_on_close = NULL;

// --- Request logging ---

extern void fiow_log_msg(int level, const char *msg, unsigned int len);

static void log_request(http_s *h, int status) {
    fio_str_info_s method = fiobj_obj2cstr(h->method);
    fio_str_info_s path = fiobj_obj2cstr(h->path);
    fio_str_info_s peer = http_peer_addr(h);

    char buf[512];
    int len = snprintf(buf, sizeof(buf), "%.*s %.*s %d",
        (int)method.len, method.data,
        (int)path.len, path.data,
        status);
    if (len > 0) { fiow_log_msg(1, buf, (unsigned int)len); }
}

// --- SSE udata ---

typedef struct {
    char suffix[32];
    char body[1024];
    unsigned int body_len;
    char pk[33];
} fiow_sse_udata;

// --- Internal dispatch ---

static int try_sse_upgrade(http_s *h, fio_str_info_s path) {
    if (!stream_prefix) { return 0; }
    if (path.len < stream_prefix_len) { return 0; }
    if (memcmp(path.data, stream_prefix, stream_prefix_len) != 0) { return 0; }

    fiow_sse_udata *ud = calloc(1, sizeof(fiow_sse_udata));
    if (!ud) { return 0; }

    size_t suffix_len = path.len - stream_prefix_len;
    if (suffix_len >= sizeof(ud->suffix)) suffix_len = sizeof(ud->suffix) - 1;
    memcpy(ud->suffix, path.data + stream_prefix_len, suffix_len);
    ud->suffix[suffix_len] = '\0';

    // Capture cookie pk before upgrade destroys the request
    http_parse_cookies(h, 0);
    if (h->cookies && h->cookies != FIOBJ_INVALID) {
        FIOBJ key = fiobj_str_new("pk", 2);
        FIOBJ val = fiobj_hash_get(h->cookies, key);
        fiobj_free(key);
        if (val && val != FIOBJ_INVALID) {
            fio_str_info_s s = fiobj_obj2cstr(val);
            if (s.len == 32) {
                memcpy(ud->pk, s.data, 32);
                ud->pk[32] = '\0';
            }
        }
    }

    log_request(h, 200);
    http_set_header2(h,
        (fio_str_info_s){ .data = "X-Accel-Buffering", .len = 17 },
        (fio_str_info_s){ .data = "no", .len = 2 });
    http_upgrade2sse(h,
        .on_open = stream_on_open,
        .on_close = stream_on_close,
        .udata = ud);
    return 1;
}

const char *fiow_get_header(http_s *h, const char *name,
                             unsigned int name_len, unsigned int *out_len);

static void on_request(http_s *h) {
    fio_str_info_s path = fiobj_obj2cstr(h->path);

    if (try_sse_upgrade(h, path)) { return; }

    fio_str_info_s method = fiobj_obj2cstr(h->method);
    if (method.len == 4 && memcmp(method.data, "POST", 4) == 0) {
        // CSRF: reject POSTs with a mismatched Origin header
        if (allowed_origin) {
            unsigned int origin_len;
            const char *origin = fiow_get_header(h, "origin", 6, &origin_len);
            if (origin && (origin_len != allowed_origin_len ||
                           memcmp(origin, allowed_origin, allowed_origin_len) != 0)) {
                log_request(h, 403);
                http_send_error(h, 403);
                return;
            }
        }

        // Guard against malformed bodies that can infinite-loop facil.io's parser.
        unsigned int cl_len;
        const char *cl_str = fiow_get_header(h, "content-length", 14, &cl_len);
        if (cl_str && cl_len > 0) {
            char *endptr;
            unsigned long body_len = strtoul(cl_str, &endptr, 10);
            if (endptr == cl_str || body_len > 4096) {
                log_request(h, 413);
                http_send_error(h, 413);
                return;
            }
            http_parse_body(h);
        }
    }

    if (request_handler) {
        request_handler(h);
        return;
    }

    log_request(h, 404);
    http_send_error(h, 404);
}

static void on_upgrade(http_s *h, char *requested_protocol, size_t len) {
    if (len == 3 && memcmp(requested_protocol, "sse", 3) == 0) {
        fio_str_info_s path = fiobj_obj2cstr(h->path);
        if (try_sse_upgrade(h, path)) { return; }
    }
    log_request(h, 400);
    http_send_error(h, 400);
}

// --- Public API ---

void fiow_set_origin(const char *origin) {
    allowed_origin = origin;
    allowed_origin_len = origin ? strlen(origin) : 0;
}

void fiow_listen(const char *port) {
    http_listen(port, NULL,
        .on_request = on_request,
        .on_upgrade = on_upgrade,
        .public_folder = NULL,
        .public_folder_length = 0,
        .log = 0);
    fio_start(.threads = 1, .workers = 1);
}

void fiow_on_request(fiow_handler handler) { request_handler = handler; }

void fiow_on_stream(const char *prefix, fiow_sse_handler on_open, fiow_sse_handler on_close) {
    stream_prefix = prefix;
    stream_prefix_len = prefix ? strlen(prefix) : 0;
    stream_on_open = on_open;
    stream_on_close = on_close;
}

void fiow_respond(http_s *h, int status, const char *content_type,
                  const char *body, unsigned int body_len,
                  const char *cache_control) {
    log_request(h, status);
    h->status = status;
    http_set_header2(h,
        (fio_str_info_s){ .data = "content-type", .len = 12 },
        (fio_str_info_s){ .data = (char *)content_type, .len = strlen(content_type) });
    http_set_header2(h,
        (fio_str_info_s){ .data = "cache-control", .len = 13 },
        (fio_str_info_s){ .data = (char *)cache_control, .len = strlen(cache_control) });
    http_send_body(h, (void *)body, body_len);
}

void fiow_parse_body(http_s *h) {
    http_parse_body(h);
}

const char *fiow_get_header(http_s *h, const char *name,
                             unsigned int name_len, unsigned int *out_len) {
    FIOBJ key = fiobj_str_new(name, name_len);
    FIOBJ val = fiobj_hash_get(h->headers, key);
    fiobj_free(key);
    if (!val || val == FIOBJ_INVALID) { *out_len = 0; return NULL; }
    fio_str_info_s s = fiobj_obj2cstr(val);
    *out_len = (unsigned int)s.len;
    return s.data;
}

const char *fiow_get_form_param(http_s *h, const char *name,
                                unsigned int name_len, unsigned int *out_len) {
    if (!h->params || h->params == FIOBJ_INVALID) { *out_len = 0; return NULL; }
    FIOBJ key = fiobj_str_new(name, name_len);
    FIOBJ val = fiobj_hash_get(h->params, key);
    fiobj_free(key);
    if (!val || val == FIOBJ_INVALID) { *out_len = 0; return NULL; }
    fio_str_info_s s = fiobj_obj2cstr(val);
    *out_len = (unsigned int)s.len;
    return s.data;
}

const char *fiow_get_cookie(http_s *h, const char *name,
                             unsigned int name_len, unsigned int *out_len) {
    http_parse_cookies(h, 0);
    if (!h->cookies || h->cookies == FIOBJ_INVALID) { *out_len = 0; return NULL; }
    FIOBJ key = fiobj_str_new(name, name_len);
    FIOBJ val = fiobj_hash_get(h->cookies, key);
    fiobj_free(key);
    if (!val || val == FIOBJ_INVALID) { *out_len = 0; return NULL; }
    fio_str_info_s s = fiobj_obj2cstr(val);
    *out_len = (unsigned int)s.len;
    return s.data;
}

void fiow_redirect(http_s *h, const char *location, unsigned int location_len) {
    log_request(h, 302);
    h->status = 302;
    http_set_header2(h,
        (fio_str_info_s){ .data = "location", .len = 8 },
        (fio_str_info_s){ .data = (char *)location, .len = location_len });
    http_send_body(h, NULL, 0);
}

int fiow_sse_write(http_sse_s *sse, const char *event,
                   const char *data, unsigned int data_len) {
    return http_sse_write(sse,
        .event = { .data = (char *)event, .len = event ? strlen(event) : 0 },
        .data = { .data = (char *)data, .len = data_len });
}

const char *fiow_get_path(http_s *h, unsigned int *out_len) {
    fio_str_info_s path = fiobj_obj2cstr(h->path);
    *out_len = (unsigned int)path.len;
    return path.data;
}

const char *fiow_get_body(http_s *h, unsigned int *out_len) {
    if (!h->body || h->body == FIOBJ_INVALID) { *out_len = 0; return NULL; }
    fio_str_info_s s = fiobj_obj2cstr(h->body);
    *out_len = (unsigned int)s.len;
    return s.data;
}

int fiow_sse_close(http_sse_s *sse) { return http_sse_close(sse); }
void *fiow_sse_get_udata(http_sse_s *sse) { return sse->udata; }
void fiow_free(void *ptr) { free(ptr); }

const char *fiow_get_method(http_s *h, unsigned int *out_len) {
    fio_str_info_s method = fiobj_obj2cstr(h->method);
    *out_len = (unsigned int)method.len;
    return method.data;
}

const char *fiow_get_query(http_s *h, unsigned int *out_len) {
    if (!h->query || h->query == FIOBJ_INVALID) { *out_len = 0; return NULL; }
    fio_str_info_s s = fiobj_obj2cstr(h->query);
    *out_len = (unsigned int)s.len;
    return s.data;
}

void fiow_run_every(unsigned int ms, void (*task)(void *), void *arg) {
    fio_run_every(ms, 0, task, arg, NULL);
}

void fiow_defer_task(void (*task)(void *, void *), void *udata1, void *udata2) {
    fio_defer(task, udata1, udata2);
}

// --- Pubsub ---

static void on_sse_message(http_sse_s *sse, fio_str_info_s channel,
                            fio_str_info_s msg, void *udata) {
    if (sse_msg_handler) sse_msg_handler(sse, udata, msg.data, (unsigned int)msg.len);
}

void fiow_on_sse_message(fiow_sse_msg_fn fn) { sse_msg_handler = fn; }

void fiow_sse_subscribe(http_sse_s *sse, const char *channel,
                         unsigned int channel_len, void *udata) {
    http_sse_subscribe(sse,
        .channel = { .data = (char*)channel, .len = channel_len },
        .on_message = on_sse_message,
        .udata = udata);
}

void fiow_publish(const char *channel, unsigned int channel_len,
                   const char *msg, unsigned int msg_len) {
    fio_publish(.engine = FIO_PUBSUB_PROCESS,
                .channel = { .data = (char*)channel, .len = channel_len },
                .message = { .data = (char*)msg, .len = msg_len });
}
