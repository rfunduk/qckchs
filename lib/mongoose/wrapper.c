#include "mongoose.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- Types ---

typedef struct {
    struct mg_connection *c;
    struct mg_http_message *hm;
    int responded;
} mgw_req_t;

typedef void (*mgw_handler)(mgw_req_t *r);
typedef void (*mgw_sse_handler)(struct mg_connection *c);
typedef void (*mgw_sse_msg_fn)(struct mg_connection *c, void *udata,
                               const char *msg, unsigned int msg_len);
typedef void (*mgw_log_fn)(int level, const char *msg, unsigned int len);

// --- Globals ---

static mgw_handler request_handler = NULL;
static mgw_sse_msg_fn sse_msg_handler = NULL;
static mgw_log_fn log_callback = NULL;

static const char *allowed_origin = NULL;
static size_t allowed_origin_len = 0;

static const char *stream_prefix = NULL;
static size_t stream_prefix_len = 0;
static mgw_sse_handler stream_on_open = NULL;
static mgw_sse_handler stream_on_close = NULL;

static struct mg_mgr mgr;
static int mgr_ready = 0;

static void mg_log_charcb(char ch, void *param);

static void ensure_mgr(void) {
    if (mgr_ready) return;
    mg_log_set(MG_LL_INFO);
    mg_log_set_fn(mg_log_charcb, NULL);
    mg_mgr_init(&mgr);
    mgr_ready = 1;
}

// --- SSE state ---

typedef struct {
    char suffix[32];
    char body[1024];
    unsigned int body_len;
    char pk[33];
} mgw_sse_udata;

typedef struct sse_sub {
    char *channel;
    size_t channel_len;
    void *udata;
    struct sse_sub *next;
} sse_sub_t;

typedef struct {
    int is_sse;
    mgw_sse_udata *udata;  // ownership transferred to Odin via mgw_sse_get_udata; Odin frees
    sse_sub_t *subs;
} sse_state_t;

// --- Deferred tasks (drained after each poll) ---

typedef struct deferred {
    void (*fn)(void *, void *);
    void *u1;
    void *u2;
    struct deferred *next;
} deferred_t;
static deferred_t *deferred_head = NULL;

// --- Logging ---

static void mgw_log(int level, const char *msg, size_t len) {
    if (log_callback) {
        log_callback(level, msg, (unsigned int)len);
    } else {
        fwrite(msg, 1, len, stderr);
        fputc('\n', stderr);
    }
}

static void log_request(struct mg_http_message *hm, int status) {
    char buf[512];
    int len = snprintf(buf, sizeof(buf), "%.*s %.*s %d",
        (int)hm->method.len, hm->method.buf,
        (int)hm->uri.len, hm->uri.buf,
        status);
    if (len > 0) mgw_log(1, buf, (size_t)len);
}

// mongoose calls one char at a time; buffer until newline
static void mg_log_charcb(char ch, void *param) {
    static char buf[1024];
    static size_t pos = 0;
    (void)param;
    if (ch == '\n') {
        if (pos > 0) mgw_log(1, buf, pos);
        pos = 0;
    } else if (pos < sizeof(buf) - 1) {
        buf[pos++] = ch;
    }
}

static const char *status_reason(int s) {
    switch (s) {
    case 200: return "OK";
    case 204: return "No Content";
    case 302: return "Found";
    case 400: return "Bad Request";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 500: return "Internal Server Error";
    default:  return "";
    }
}

// --- Per-request bump allocator (for form param outputs) ---

static char req_buf[16384];
static size_t req_buf_pos = 0;

static char *req_alloc(size_t n) {
    if (req_buf_pos + n > sizeof(req_buf)) return NULL;
    char *p = req_buf + req_buf_pos;
    req_buf_pos += n;
    return p;
}

// --- SSE upgrade ---

static int try_sse_upgrade(struct mg_connection *c, struct mg_http_message *hm) {
    if (!stream_prefix) return 0;
    if (hm->uri.len < stream_prefix_len) return 0;
    if (memcmp(hm->uri.buf, stream_prefix, stream_prefix_len) != 0) return 0;

    sse_state_t *st = calloc(1, sizeof(*st));
    if (!st) return 0;
    mgw_sse_udata *ud = calloc(1, sizeof(*ud));
    if (!ud) { free(st); return 0; }
    st->is_sse = 1;
    st->udata = ud;

    size_t suffix_len = hm->uri.len - stream_prefix_len;
    if (suffix_len >= sizeof(ud->suffix)) suffix_len = sizeof(ud->suffix) - 1;
    memcpy(ud->suffix, hm->uri.buf + stream_prefix_len, suffix_len);
    ud->suffix[suffix_len] = '\0';

    // Capture pk cookie
    struct mg_str *cookie = mg_http_get_header(hm, "Cookie");
    if (cookie) {
        struct mg_str pk = mg_http_get_header_var(*cookie, mg_str("pk"));
        if (pk.len == 32) {
            memcpy(ud->pk, pk.buf, 32);
            ud->pk[32] = '\0';
        }
    }

    log_request(hm, 200);
    mg_printf(c,
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/event-stream\r\n"
        "Cache-Control: no-cache\r\n"
        "Transfer-Encoding: chunked\r\n"
        "X-Accel-Buffering: no\r\n"
        "\r\n");
    c->fn_data = st;

    if (stream_on_open) stream_on_open(c);
    return 1;
}

static void on_close_conn(struct mg_connection *c) {
    sse_state_t *st = (sse_state_t *)c->fn_data;
    if (!st) return;
    if (st->is_sse && stream_on_close) stream_on_close(c);
    sse_sub_t *s = st->subs;
    while (s) {
        sse_sub_t *n = s->next;
        free(s->channel);
        free(s);
        s = n;
    }
    // udata: if Odin already freed via mgw_sse_get_udata + fio.free, st->udata
    // was set to NULL by mgw_sse_get_udata. Otherwise free here as safety net.
    if (st->udata) free(st->udata);
    free(st);
    c->fn_data = NULL;
}

// --- Request dispatch ---

static void on_http_msg(struct mg_connection *c, struct mg_http_message *hm) {
    req_buf_pos = 0;  // reset per-request bump allocator

    if (try_sse_upgrade(c, hm)) return;

    mgw_req_t req = { c, hm, 0 };

    if (hm->method.len == 4 && memcmp(hm->method.buf, "POST", 4) == 0) {
        if (allowed_origin) {
            struct mg_str *origin = mg_http_get_header(hm, "Origin");
            if (!origin || origin->len != allowed_origin_len ||
                memcmp(origin->buf, allowed_origin, allowed_origin_len) != 0) {
                log_request(hm, 403);
                mg_http_reply(c, 403, "", "Forbidden");
                return;
            }
        }
    }

    if (request_handler) {
        request_handler(&req);
        return;
    }

    log_request(hm, 404);
    mg_http_reply(c, 404, "", "");
}

static void event_handler(struct mg_connection *c, int ev, void *ev_data) {
    if (ev == MG_EV_HTTP_MSG) {
        on_http_msg(c, (struct mg_http_message *)ev_data);
    } else if (ev == MG_EV_CLOSE) {
        on_close_conn(c);
    }
}

// --- Public API ---

void mgw_set_log(mgw_log_fn fn) { log_callback = fn; }

void mgw_set_origin(const char *origin) {
    allowed_origin = origin;
    allowed_origin_len = origin ? strlen(origin) : 0;
}

void mgw_on_request(mgw_handler h) { request_handler = h; }

void mgw_on_stream(const char *prefix, mgw_sse_handler on_open, mgw_sse_handler on_close_h) {
    stream_prefix = prefix;
    stream_prefix_len = prefix ? strlen(prefix) : 0;
    stream_on_open = on_open;
    stream_on_close = on_close_h;
}

void mgw_on_sse_message(mgw_sse_msg_fn fn) { sse_msg_handler = fn; }

void mgw_listen(const char *port) {
    ensure_mgr();

    char url[64];
    snprintf(url, sizeof(url), "http://0.0.0.0:%s", port);
    if (mg_http_listen(&mgr, url, event_handler, NULL) == NULL) {
        char buf[128];
        int n = snprintf(buf, sizeof(buf), "failed to listen on %s", url);
        mgw_log(4, buf, (size_t)n);
        return;
    }

    for (;;) {
        mg_mgr_poll(&mgr, 100);
        while (deferred_head) {
            deferred_t *d = deferred_head;
            deferred_head = d->next;
            d->fn(d->u1, d->u2);
            free(d);
        }
    }
}

void mgw_respond(mgw_req_t *r, int status, const char *content_type,
                 const char *body, unsigned int body_len,
                 const char *cache_control) {
    log_request(r->hm, status);
    char hdrs[512];
    snprintf(hdrs, sizeof(hdrs),
        "Content-Type: %s\r\nCache-Control: %s\r\n",
        content_type, cache_control);
    mg_http_reply(r->c, status, hdrs, "%.*s",
        (int)body_len, body ? body : "");
    r->responded = 1;
}

void mgw_redirect(mgw_req_t *r, const char *location, unsigned int location_len) {
    log_request(r->hm, 302);
    char hdrs[1024];
    snprintf(hdrs, sizeof(hdrs), "Location: %.*s\r\n",
        (int)location_len, location);
    mg_http_reply(r->c, 302, hdrs, "");
    r->responded = 1;
}

const char *mgw_get_path(mgw_req_t *r, unsigned int *out_len) {
    *out_len = (unsigned int)r->hm->uri.len;
    return r->hm->uri.buf;
}

const char *mgw_get_method(mgw_req_t *r, unsigned int *out_len) {
    *out_len = (unsigned int)r->hm->method.len;
    return r->hm->method.buf;
}

const char *mgw_get_query(mgw_req_t *r, unsigned int *out_len) {
    *out_len = (unsigned int)r->hm->query.len;
    return r->hm->query.buf;
}

const char *mgw_get_body(mgw_req_t *r, unsigned int *out_len) {
    *out_len = (unsigned int)r->hm->body.len;
    return r->hm->body.buf;
}

const char *mgw_get_header(mgw_req_t *r, const char *name,
                            unsigned int name_len, unsigned int *out_len) {
    char nbuf[64];
    if (name_len >= sizeof(nbuf)) { *out_len = 0; return NULL; }
    memcpy(nbuf, name, name_len);
    nbuf[name_len] = '\0';
    struct mg_str *h = mg_http_get_header(r->hm, nbuf);
    if (!h) { *out_len = 0; return NULL; }
    char *out = req_alloc(h->len + 1);
    if (!out) { *out_len = 0; return NULL; }
    memcpy(out, h->buf, h->len);
    out[h->len] = '\0';
    *out_len = (unsigned int)h->len;
    return out;
}

const char *mgw_get_form_param(mgw_req_t *r, const char *name,
                                unsigned int name_len, unsigned int *out_len) {
    char nbuf[64];
    if (name_len >= sizeof(nbuf)) { *out_len = 0; return NULL; }
    memcpy(nbuf, name, name_len);
    nbuf[name_len] = '\0';

    // Allocate from per-request bump pool — caller (Odin) reads, doesn't free
    char *out = req_alloc(2048);
    if (!out) { *out_len = 0; return NULL; }
    int n = mg_http_get_var(&r->hm->body, nbuf, out, 2048);
    if (n <= 0) { *out_len = 0; return NULL; }
    *out_len = (unsigned int)n;
    return out;
}

const char *mgw_get_cookie(mgw_req_t *r, const char *name,
                            unsigned int name_len, unsigned int *out_len) {
    struct mg_str *cookie = mg_http_get_header(r->hm, "Cookie");
    if (!cookie) { *out_len = 0; return NULL; }
    struct mg_str v = mg_http_get_header_var(*cookie, mg_str_n(name, name_len));
    if (v.len == 0) { *out_len = 0; return NULL; }
    char *out = req_alloc(v.len + 1);
    if (!out) { *out_len = 0; return NULL; }
    memcpy(out, v.buf, v.len);
    out[v.len] = '\0';
    *out_len = (unsigned int)v.len;
    return out;
}

// --- SSE I/O ---

int mgw_sse_write(struct mg_connection *c, const char *event,
                  const char *data, unsigned int data_len) {
    if (!c || c->is_closing || c->is_draining) return -1;

    // Build entire SSE event into one buffer, send as one chunk
    size_t evlen = (event && *event) ? strlen(event) : 0;
    size_t cap = 32 + evlen + data_len + (data_len / 32 + 1) * 8;
    char *buf = malloc(cap);
    if (!buf) return -1;
    size_t pos = 0;

    if (evlen) {
        memcpy(buf + pos, "event: ", 7); pos += 7;
        memcpy(buf + pos, event, evlen); pos += evlen;
        buf[pos++] = '\n';
    }

    const char *start = data;
    const char *end = data + data_len;
    const char *p = data;
    while (p < end) {
        if (*p == '\n') {
            memcpy(buf + pos, "data: ", 6); pos += 6;
            size_t n = (size_t)(p - start);
            memcpy(buf + pos, start, n); pos += n;
            buf[pos++] = '\n';
            start = p + 1;
        }
        p++;
    }
    if (start < end) {
        memcpy(buf + pos, "data: ", 6); pos += 6;
        size_t n = (size_t)(end - start);
        memcpy(buf + pos, start, n); pos += n;
        buf[pos++] = '\n';
    }
    buf[pos++] = '\n';

    mg_http_write_chunk(c, buf, pos);
    free(buf);
    return 0;
}

int mgw_sse_close(struct mg_connection *c) {
    if (!c) return -1;
    c->is_draining = 1;
    return 0;
}

void *mgw_sse_get_udata(struct mg_connection *c) {
    sse_state_t *st = (sse_state_t *)c->fn_data;
    if (!st) return NULL;
    void *u = st->udata;
    st->udata = NULL;  // ownership transfers — close handler won't double-free
    return u;
}

void mgw_free(void *ptr) { free(ptr); }

// --- Pubsub ---

void mgw_sse_subscribe(struct mg_connection *c, const char *channel,
                       unsigned int channel_len, void *udata) {
    sse_state_t *st = (sse_state_t *)c->fn_data;
    if (!st) return;
    sse_sub_t *sub = malloc(sizeof(*sub));
    if (!sub) return;
    sub->channel = malloc(channel_len);
    if (!sub->channel) { free(sub); return; }
    memcpy(sub->channel, channel, channel_len);
    sub->channel_len = channel_len;
    sub->udata = udata;
    sub->next = st->subs;
    st->subs = sub;
}

void mgw_publish(const char *channel, unsigned int channel_len,
                 const char *msg, unsigned int msg_len) {
    for (struct mg_connection *c = mgr.conns; c; c = c->next) {
        sse_state_t *st = (sse_state_t *)c->fn_data;
        if (!st || !st->is_sse) continue;
        for (sse_sub_t *sub = st->subs; sub; sub = sub->next) {
            if (sub->channel_len == channel_len &&
                memcmp(sub->channel, channel, channel_len) == 0) {
                if (sse_msg_handler) {
                    sse_msg_handler(c, sub->udata, msg, msg_len);
                }
                break;
            }
        }
    }
}

// --- Timers + deferred ---

typedef struct {
    void (*fn)(void *);
    void *arg;
} timer_wrap_t;

static void timer_trampoline(void *arg) {
    timer_wrap_t *w = (timer_wrap_t *)arg;
    w->fn(w->arg);
}

void mgw_run_every(unsigned int ms, void (*task)(void *), void *arg) {
    ensure_mgr();
    timer_wrap_t *w = malloc(sizeof(*w));
    w->fn = task;
    w->arg = arg;
    mg_timer_add(&mgr, ms, MG_TIMER_REPEAT, timer_trampoline, w);
}

void mgw_defer_task(void (*task)(void *, void *), void *u1, void *u2) {
    deferred_t *d = malloc(sizeof(*d));
    if (!d) return;
    d->fn = task;
    d->u1 = u1;
    d->u2 = u2;
    d->next = deferred_head;
    deferred_head = d;
}
