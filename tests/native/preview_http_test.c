/* preview_http_test.c -- standalone harness for compiler/preview_http.c
 * (v3.0 Phase 0 findings X1 + X2).  Not part of the compiler build.
 *
 * It #includes the real preview_http.c, so the code under test is
 * the shipped code, and drives it over real loopback TCP sockets:
 *
 *   X1 (bind policy): getsockname() + /proc/net/tcp inspection for
 *       "127.0.0.1" and "localhost" (loopback only), refusal of
 *       "0.0.0.0" / a non-loopback literal / an unresolvable name
 *       without opt-in, and success for the explicit "ext:" opt-in.
 *   X2 (request buffer): a handler stub + real clients exercising
 *       (a) a normal single-segment request,
 *       (b) a request split across two TCP segments mid-header,
 *       (c) the stale-byte case: a long request, then a connection
 *           whose first segment is a partial request line with NO
 *           header terminator, completed by a second segment.  The
 *           old static-buffer/strstr code mistook the previous
 *           request's terminator (still in the shared buffer past
 *           `used`) for this request's and answered for the partial
 *           path "/sta"; the fixed code must wait and answer for
 *           the full path "/stale".
 *
 * Build & run (from the repo root):
 *   gcc -fsanitize=address,undefined -g -pthread \
 *       -o /tmp/preview_http_test tests/native/preview_http_test.c
 *   /tmp/preview_http_test        # prints PASS/FAIL lines, exit != 0 on failure
 */
#define _GNU_SOURCE /* for the harness's own memmem-free helpers below */
#include "../../compiler/preview_http.c"

#include <pthread.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("PASS: %s\n", msg); } \
    else { printf("FAIL: %s\n", msg); failures++; } \
} while (0)

/* ---------------- X1: bind policy ---------------- */

static int bound_addr_is(int fd, const char *want) {
    struct sockaddr_in a; socklen_t n = sizeof(a);
    if (getsockname(fd, (struct sockaddr *)&a, &n) != 0) return 0;
    struct in_addr w;
    if (inet_pton(AF_INET, want, &w) != 1) return 0;
    return a.sin_addr.s_addr == w.s_addr;
}

/* Is there a LISTEN (state 0A) entry in /proc/net/tcp for `port`
 * whose local address is exactly `hex_addr` (network-order hex)? */
static int proc_net_tcp_listen_addr(int port, const char *hex_addr) {
    FILE *f = fopen("/proc/net/tcp", "r");
    if (!f) return -1;
    char line[512], hexport[8];
    snprintf(hexport, sizeof(hexport), "%04X", port);
    int found = 0;
    while (fgets(line, sizeof(line), f)) {
        char local[64], state[8];
        if (sscanf(line, "%*s %63s %*s %7s", local, state) == 2 &&
            strcmp(state, "0A") == 0) {
            char *colon = strrchr(local, ':');
            if (colon && strcmp(colon + 1, hexport) == 0) {
                *colon = '\0';
                if (strcmp(local, hex_addr) == 0) found = 1;
            }
        }
    }
    fclose(f);
    return found;
}

static void test_bind_policy(void) {
    char err[128]; int elen = 0, port = 0;

    int fd = preview_http_open("127.0.0.1", 0, &port, err, sizeof(err), &elen);
    CHECK(fd >= 0 && bound_addr_is(fd, "127.0.0.1"),
          "X1 literal 127.0.0.1 binds loopback");
    if (fd >= 0) preview_http_close(fd);

    fd = preview_http_open("localhost", 0, &port, err, sizeof(err), &elen);
    CHECK(fd >= 0 && bound_addr_is(fd, "127.0.0.1"),
          "X1 \"localhost\" resolves and binds 127.0.0.1 (not INADDR_ANY)");
    if (fd >= 0) {
        CHECK(proc_net_tcp_listen_addr(port, "0100007F") == 1,
              "X1 /proc/net/tcp shows LISTEN on 0100007F (127.0.0.1) for localhost");
        preview_http_close(fd);
    }

    fd = preview_http_open("0.0.0.0", 0, &port, err, sizeof(err), &elen);
    CHECK(fd == -1, "X1 literal 0.0.0.0 refused without opt-in");
    if (fd >= 0) preview_http_close(fd);

    fd = preview_http_open("192.0.2.1", 0, &port, err, sizeof(err), &elen);
    CHECK(fd == -1, "X1 non-loopback literal 192.0.2.1 (TEST-NET-1) refused");
    if (fd >= 0) preview_http_close(fd);

    fd = preview_http_open("nonexistent.invalid", 0, &port, err, sizeof(err), &elen);
    CHECK(fd == -1, "X1 unresolvable hostname refused (no INADDR_ANY fallback)");
    if (fd >= 0) preview_http_close(fd);

    fd = preview_http_open("ext:127.0.0.1", 0, &port, err, sizeof(err), &elen);
    CHECK(fd >= 0 && bound_addr_is(fd, "127.0.0.1"),
          "X1 explicit \"ext:\" opt-in prefix is honoured");
    if (fd >= 0) preview_http_close(fd);
}

/* ---------------- X2: request parsing ---------------- */

static char last_path[512];
static int handler_calls = 0;

static void test_handler(const char *method, int method_len,
                         const char *path, int path_len,
                         char *body_buf, int body_cap, int *body_len,
                         int *status,
                         char *ctype_buf, int ctype_cap, int *ctype_len) {
    (void)method; (void)method_len;
    handler_calls++;
    int n = path_len < (int)sizeof(last_path) - 1 ? path_len
                                                  : (int)sizeof(last_path) - 1;
    memcpy(last_path, path, (size_t)n);
    last_path[n] = '\0';
    const char *body = "hello-body";
    int bl = (int)strlen(body);
    *status = 200;
    const char *ct = "text/plain";
    int cl = (int)strlen(ct);
    if (cl > ctype_cap) cl = ctype_cap;
    memcpy(ctype_buf, ct, (size_t)cl);
    *ctype_len = cl;
    if (body_buf && body_cap > 0) {
        int cp = bl < body_cap ? bl : body_cap;
        memcpy(body_buf, body, (size_t)cp);
        *body_len = cp;
    } else {
        *body_len = bl;
    }
}

struct client_job {
    int port;
    const char *part1; size_t len1;
    const char *part2; size_t len2; /* sent after a delay; may be NULL */
    char resp[8192]; ssize_t resp_len;
    int ok;
};

static void *client_main(void *arg) {
    struct client_job *j = (struct client_job *)arg;
    j->ok = 0; j->resp_len = 0;
    int c = socket(AF_INET, SOCK_STREAM, 0);
    if (c < 0) return NULL;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)j->port);
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (connect(c, (struct sockaddr *)&a, sizeof(a)) != 0) { close(c); return NULL; }
    if (send(c, j->part1, j->len1, 0) < 0) { close(c); return NULL; }
    if (j->part2) {
        struct timespec ts = {0, 300 * 1000 * 1000L}; /* 300 ms gap */
        nanosleep(&ts, NULL);
        if (send(c, j->part2, j->len2, 0) < 0) { close(c); return NULL; }
    }
    ssize_t n;
    while ((n = recv(c, j->resp + j->resp_len,
                     sizeof(j->resp) - 1 - (size_t)j->resp_len, 0)) > 0)
        j->resp_len += n;
    j->resp[j->resp_len] = '\0';
    j->ok = 1;
    close(c);
    return NULL;
}

/* Serve exactly one request on `lfd` while a client thread runs. */
static int serve_with_client(int lfd, int port,
                             const char *p1, const char *p2,
                             struct client_job *j) {
    memset(j, 0, sizeof(*j));
    j->port = port;
    j->part1 = p1; j->len1 = strlen(p1);
    j->part2 = p2; j->len2 = p2 ? strlen(p2) : 0;
    last_path[0] = '\0';
    pthread_t th;
    if (pthread_create(&th, NULL, client_main, j) != 0) return -1;
    int rc = preview_http_serve_once(lfd, test_handler, 5000);
    pthread_join(th, NULL);
    return rc;
}

static void test_parsing(void) {
    char err[128]; int elen = 0, port = 0;
    int lfd = preview_http_open("127.0.0.1", 0, &port, err, sizeof(err), &elen);
    CHECK(lfd >= 0, "X2 harness listening socket opens on loopback");
    if (lfd < 0) return;
    struct client_job j;

    /* (a) normal request, single segment */
    int rc = serve_with_client(lfd, port,
        "GET /normal HTTP/1.1\r\nHost: x\r\n\r\n", NULL, &j);
    CHECK(rc == 1 && j.ok && strcmp(last_path, "/normal") == 0 &&
          strstr(j.resp, "200") != NULL && strstr(j.resp, "hello-body") != NULL,
          "X2 normal request served, path=/normal, body returned");

    /* (b) split across two TCP segments, mid-header: the CRLFCRLF
     * terminator itself is completed only by the second segment */
    rc = serve_with_client(lfd, port,
        "GET /split HTTP/1.1\r\nHost: x\r\n", "\r\n", &j);
    CHECK(rc == 1 && j.ok && strcmp(last_path, "/split") == 0 &&
          strstr(j.resp, "hello-body") != NULL,
          "X2 split-segment request served, path=/split");

    /* prime the (formerly shared, static) buffer with a long request
     * whose terminator sits far into the buffer */
    char longreq[1024];
    int ln = snprintf(longreq, sizeof(longreq),
        "GET /long HTTP/1.1\r\nX-Pad: ");
    memset(longreq + ln, 'A', 400); ln += 400;
    ln += snprintf(longreq + ln, sizeof(longreq) - (size_t)ln, "\r\n\r\n");
    rc = serve_with_client(lfd, port, longreq, NULL, &j);
    CHECK(rc == 1 && strcmp(last_path, "/long") == 0,
          "X2 long priming request served, path=/long");

    /* (c) stale-byte case: first segment has NO terminator at all;
     * the fixed parser must wait for segment 2 and see "/stale",
     * not stop early on the previous request's stale terminator
     * and answer for the partial path "/sta" */
    rc = serve_with_client(lfd, port,
        "GET /sta", "le HTTP/1.1\r\n\r\n", &j);
    CHECK(rc == 1 && j.ok && strcmp(last_path, "/stale") == 0 &&
          strstr(j.resp, "hello-body") != NULL,
          "X2 stale-byte case: parser waited, path=/stale (not /sta)");

    preview_http_close(lfd);
}

int main(void) {
    test_bind_policy();
    test_parsing();
    if (failures) { printf("RESULT: %d FAILURE(S)\n", failures); return 1; }
    printf("RESULT: ALL PASS (%d handler calls)\n", handler_calls);
    return 0;
}
