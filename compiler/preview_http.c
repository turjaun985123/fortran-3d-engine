/* preview_http.c -- clang-18 HTTP server helper for `f3dc preview`.
 *
 * Native port of the transport half of tools/f3dc/preview.py
 * (ThreadingHTTPServer + BaseHTTPRequestHandler).  This file knows
 * NOTHING about scenes, HTML or JSON: body generation is delegated
 * to Fortran.  The Fortran side (src/f3dc_preview.f90) drives it
 * through this small ISO_C_BINDING API:
 *
 *   int preview_http_open(const char *host, int port,
 *                         int *actual_port,
 *                         char *errbuf, int errcap, int *errlen)
 *       Create/bind/listen a TCP socket on host:port (port 0 =
 *       kernel picks a free one, like Python's server_address with
 *       port 0).  Returns the listening fd (>= 0) and the actual
 *       bound port, or -1 on failure with the strerror() text in
 *       errbuf (errlen bytes written, not NUL-terminated).
 *       Also installs a SIGINT handler that only sets a flag, so
 *       the Fortran serve loop can shut down gracefully and print
 *       Python's "preview stopped" line (serve_once returns -2).
 *
 *       Bind-address policy (v3.0 X1 -- safe by default):
 *       the preview is a local development server, so the default
 *       policy binds LOOPBACK ONLY and never falls back to
 *       INADDR_ANY:
 *         - NULL or empty host          -> 127.0.0.1
 *         - literal IPv4 in 127.0.0.0/8 -> that address
 *         - any other literal IPv4 (including 0.0.0.0)
 *                                       -> REFUSED (EADDRNOTAVAIL)
 *         - a hostname (e.g. "localhost") is resolved with
 *           getaddrinfo(); the first result in 127.0.0.0/8 is
 *           bound.  If it resolves to no loopback address, or
 *           does not resolve at all, the open is REFUSED --
 *           never silently widened to all interfaces.
 *       Binding a non-loopback address requires an explicit
 *       opt-in in the host string itself: prefix the address
 *       with "ext:", e.g. "ext:0.0.0.0" or "ext:192.168.1.10".
 *       The current Fortran caller (f3dc_preview.f90) passes the
 *       literal "127.0.0.1" and needs no change; if an external
 *       bind is ever wanted, that is the side that would pass
 *       the "ext:"-prefixed host (and surface the exposure in
 *       its own UI/CLI), keeping this signature unchanged.
 *
 *   typedef void (*f3d_preview_handler_fn)(
 *       const char *method, int method_len,
 *       const char *path,   int path_len,
 *       char *body_buf,  int body_cap,  int *body_len,
 *       int *status,
 *       char *ctype_buf, int ctype_cap, int *ctype_len)
 *       Request handler implemented in Fortran (bind(C)).  Called
 *       TWICE per request: first with body_buf == NULL / body_cap
 *       == 0 to query the needed body_len, then with a buffer of
 *       exactly that capacity to fill.  ctype_buf is a fixed
 *       128-byte scratch on both calls.  The handler sets *status
 *       (HTTP status code) on both calls.
 *
 *   int preview_http_serve_once(int fd, f3d_preview_handler_fn h,
 *                               int timeout_ms)
 *       poll() the listening socket for up to timeout_ms; on a
 *       connection, read one HTTP request (request line + headers,
 *       up to 64 KiB), invoke the handler for method+path, and
 *       write an HTTP/1.1 response:
 *         HTTP/1.1 <status> <reason>
 *         Content-Type: <from handler>
 *         Content-Length: <body length>
 *         Cache-Control: no-store        (as preview.py's _send)
 *         Connection: close
 *       Returns 1 = request served, 0 = timeout (caller should run
 *       its watcher tick), -2 = SIGINT seen, -1 = hard error.
 *       One request per connection (Connection: close); Python's
 *       handler keeps connections alive, but every client of the
 *       preview page (browser fetch poll included) works fine with
 *       close-per-request -- a documented divergence.
 *
 *   void preview_http_close(int fd)
 *       Close the listening socket.
 *
 *   int preview_http_mtime_ns(const char *path, long long *out_ns)
 *       stat() mtime in nanoseconds (st_mtim), mirroring Python's
 *       Path.stat().st_mtime_ns used by preview.py's watcher.
 *       Returns 0 on success, -1 when the file cannot be stat'ed.
 *
 *   void preview_http_sleep_ms(int ms)
 *       nanosleep() -- the watcher's debounce delay.
 *
 *   int f3dc_isatty_stderr(void)
 *       isatty(2) -- 1 when stderr is a terminal, else 0.  Used by
 *       f3dc_errors' error_bag_use_color() (v2.0 P4) to decide
 *       whether diagnostics get ANSI colour.
 *
 *   int preview_http_self_exe(char *buf, int cap)
 *       readlink("/proc/self/exe") into buf (not NUL-terminated);
 *       returns the byte count or -1.  The Fortran side derives
 *       the repo root from it exactly like driver_repo_root()
 *       (parent of the directory holding the binary).
 *
 * No Python anywhere; libc + POSIX sockets only.
 */

#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

typedef void (*f3d_preview_handler_fn)(
    const char *method, int method_len,
    const char *path,   int path_len,
    char *body_buf,  int body_cap,  int *body_len,
    int *status,
    char *ctype_buf, int ctype_cap, int *ctype_len);

static volatile sig_atomic_t g_got_sigint = 0;

static void on_sigint(int sig) {
    (void)sig;
    g_got_sigint = 1;
}

static int is_loopback_v4(struct in_addr a) {
    return (ntohl(a.s_addr) >> 24) == 127; /* 127.0.0.0/8 */
}

/* Resolve `host` into the address to bind, enforcing the policy
 * documented above preview_http_open.  Returns 0 on success, -1
 * with errno set on failure (refusals use EADDRNOTAVAIL). */
static int resolve_bind_addr(const char *host, struct in_addr *out) {
    int external = 0;
    if (host && strncmp(host, "ext:", 4) == 0) {
        external = 1; /* explicit opt-in to a non-loopback bind */
        host += 4;
    }
    if (!host || host[0] == '\0') {
        if (external) { out->s_addr = htonl(INADDR_ANY); return 0; }
        out->s_addr = htonl(INADDR_LOOPBACK);
        return 0;
    }
    struct in_addr literal;
    if (inet_pton(AF_INET, host, &literal) == 1) {
        if (external || is_loopback_v4(literal)) { *out = literal; return 0; }
        errno = EADDRNOTAVAIL; /* non-loopback literal, no opt-in */
        return -1;
    }
    /* Hostname: resolve it; never guess, never widen. */
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) {
        if (res) freeaddrinfo(res);
        errno = EADDRNOTAVAIL;
        return -1;
    }
    int rc = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        struct in_addr a = ((struct sockaddr_in *)ai->ai_addr)->sin_addr;
        if (external) { *out = a; rc = 0; break; }
        if (is_loopback_v4(a)) { *out = a; rc = 0; break; }
    }
    freeaddrinfo(res);
    if (rc != 0) errno = EADDRNOTAVAIL; /* resolved, but not loopback */
    return rc;
}

int preview_http_open(const char *host, int port, int *actual_port,
                      char *errbuf, int errcap, int *errlen) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigint;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0; /* no SA_RESTART: poll/accept must wake up */
    sigaction(SIGINT, &sa, NULL);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    if (resolve_bind_addr(host, &addr.sin_addr) != 0) goto fail;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) goto fail;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) goto fail_close;
    if (listen(fd, 16) < 0) goto fail_close;

    struct sockaddr_in bound;
    socklen_t blen = sizeof(bound);
    if (getsockname(fd, (struct sockaddr *)&bound, &blen) == 0)
        *actual_port = ntohs(bound.sin_port);
    else
        *actual_port = port;
    return fd;

fail_close:
    {
        int saved = errno;
        close(fd);
        errno = saved;
    }
fail:
    if (errbuf && errcap > 0) {
        const char *msg = strerror(errno);
        int n = (int)strlen(msg);
        if (n > errcap) n = errcap;
        memcpy(errbuf, msg, (size_t)n);
        *errlen = n;
    } else if (errlen) {
        *errlen = 0;
    }
    return -1;
}

/* Bounded substring search over exactly `len` bytes (a
 * memmem-style scan that never reads past the given region). */
static int buf_contains(const char *buf, size_t len,
                        const char *pat, size_t plen) {
    if (plen == 0 || len < plen) return 0;
    for (size_t i = 0; i + plen <= len; i++)
        if (memcmp(buf + i, pat, plen) == 0) return 1;
    return 0;
}

static const char *reason_phrase(int status) {
    switch (status) {
        case 200: return "OK";
        case 400: return "Bad Request";
        case 404: return "Not Found";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        default:  return "OK";
    }
}

static int send_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, buf + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) {
                if (g_got_sigint) return -1;
                continue;
            }
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

int preview_http_serve_once(int fd, f3d_preview_handler_fn handler,
                            int timeout_ms) {
    if (g_got_sigint) return -2;

    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int pr;
    do {
        pr = poll(&pfd, 1, timeout_ms);
    } while (pr < 0 && errno == EINTR && !g_got_sigint);
    if (g_got_sigint) return -2;
    if (pr < 0) return -1;
    if (pr == 0) return 0;

    int conn = accept(fd, NULL, NULL);
    if (conn < 0) return g_got_sigint ? -2 : -1;

    /* Read the request head (request line + headers).
     * Per-request buffer (v3.0 X2): on this connection's stack,
     * never a static shared across connections.  One extra byte
     * is reserved so req[used] can always hold a NUL terminator;
     * header-completion is a bounded scan of exactly the `used`
     * bytes received for THIS request, so stale bytes from an
     * earlier, longer request can never be seen. */
    enum { REQ_CAP = 65536 };
    char req[REQ_CAP + 1];
    size_t used = 0;
    req[0] = '\0';
    int head_done = 0;
    struct timeval tv;
    tv.tv_sec = 5;
    tv.tv_usec = 0;
    setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    while (used < REQ_CAP) {
        ssize_t n = recv(conn, req + used, REQ_CAP - used, 0);
        if (n < 0) {
            if (errno == EINTR && !g_got_sigint) continue;
            break;
        }
        if (n == 0) break;
        used += (size_t)n;
        req[used] = '\0';
        if (buf_contains(req, used, "\r\n\r\n", 4)) {
            head_done = 1;
            break;
        }
        if (buf_contains(req, used, "\n\n", 2)) { head_done = 1; break; }
    }
    if (!head_done && used == 0) { close(conn); return 1; }

    /* Parse "METHOD SP PATH SP VERSION" from the first line. */
    size_t line_end = 0;
    while (line_end < used && req[line_end] != '\n') line_end++;
    size_t sp1 = 0;
    while (sp1 < line_end && req[sp1] != ' ') sp1++;
    size_t sp2 = sp1 + 1;
    while (sp2 < line_end && req[sp2] != ' ') sp2++;
    if (sp1 == 0 || sp1 >= line_end || sp2 <= sp1 + 1) {
        const char *bad = "bad request\n";
        char hdr[256];
        int hn = snprintf(hdr, sizeof(hdr),
            "HTTP/1.1 400 Bad Request\r\n"
            "Content-Type: text/plain\r\n"
            "Content-Length: %zu\r\n"
            "Cache-Control: no-store\r\n"
            "Connection: close\r\n\r\n", strlen(bad));
        if (hn > 0) send_all(conn, hdr, (size_t)hn);
        send_all(conn, bad, strlen(bad));
        close(conn);
        return 1;
    }
    const char *method = req;
    int method_len = (int)sp1;
    const char *path = req + sp1 + 1;
    int path_len = (int)(sp2 - sp1 - 1);

    /* Two-call handler protocol: query size, then fill. */
    int body_len = 0, status = 200, ctype_len = 0;
    char ctype[128];
    ctype[0] = '\0';
    handler(method, method_len, path, path_len,
            NULL, 0, &body_len, &status, ctype, (int)sizeof(ctype),
            &ctype_len);
    if (body_len < 0) body_len = 0;
    char *body = NULL;
    if (body_len > 0) {
        body = (char *)malloc((size_t)body_len);
        if (!body) { close(conn); return -1; }
        int filled = 0, status2 = status, ctype_len2 = 0;
        char ctype2[128];
        ctype2[0] = '\0';
        handler(method, method_len, path, path_len,
                body, body_len, &filled, &status2,
                ctype2, (int)sizeof(ctype2), &ctype_len2);
        if (filled < 0) filled = 0;
        if (filled > body_len) filled = body_len;
        body_len = filled;
        status = status2;
        memcpy(ctype, ctype2, sizeof(ctype));
        ctype_len = ctype_len2;
    }
    if (ctype_len < 0) ctype_len = 0;
    if (ctype_len >= (int)sizeof(ctype)) ctype_len = (int)sizeof(ctype) - 1;
    ctype[ctype_len] = '\0';
    if (ctype_len == 0) {
        memcpy(ctype, "text/plain", 11);
        ctype_len = 10;
        ctype[ctype_len] = '\0';
    }

    char hdr[512];
    int hn = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n",
        status, reason_phrase(status), ctype, body_len);
    if (hn > 0) send_all(conn, hdr, (size_t)hn);
    if (body && body_len > 0) send_all(conn, body, (size_t)body_len);
    free(body);
    close(conn);
    return 1;
}

void preview_http_close(int fd) {
    if (fd >= 0) close(fd);
}

int preview_http_mtime_ns(const char *path, long long *out_ns) {
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    *out_ns = (long long)st.st_mtim.tv_sec * 1000000000LL +
              (long long)st.st_mtim.tv_nsec;
    return 0;
}

void preview_http_sleep_ms(int ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

int f3dc_isatty_stderr(void) {
    return isatty(2);
}

int preview_http_self_exe(char *buf, int cap) {
    ssize_t n = readlink("/proc/self/exe", buf, (size_t)cap);
    if (n < 0) return -1;
    return (int)n;
}
