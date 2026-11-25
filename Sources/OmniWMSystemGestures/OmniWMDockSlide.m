// SPDX-License-Identifier: GPL-2.0-only
#import "OmniWMDockSlide.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <libproc.h>
#import <math.h>
#import <poll.h>
#import <pwd.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

// yabai-sb 2.1.45, osax/common.h and SAPayload. Connect only to the logged-in user's Dock.
static int openDock(void) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    struct passwd *user = getpwuid(getuid());
    if (!user || snprintf(addr.sun_path, sizeof(addr.sun_path), "/tmp/yabai-sa_%s.socket",
                          user->pw_name) >= (int)sizeof(addr.sun_path)) return -1;
    struct stat st;
    if (lstat(addr.sun_path, &st) || !S_ISSOCK(st.st_mode) || st.st_uid != getuid()) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    pid_t peer = 0;
    socklen_t len = sizeof(peer);
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (fcntl(fd, F_SETFL, O_NONBLOCK) || setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))
        || connect(fd, (void *)&addr, sizeof(addr))
        || getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &len)
        || proc_pidpath(peer, path, sizeof(path)) <= 0
        || strcmp(path, "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool reply(int fd, void *buf, size_t bytes) {
    while (bytes) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        if (poll(&p, 1, 30) <= 0) return false;
        ssize_t n = read(fd, buf, bytes);
        if (n <= 0) return false;
        buf = (char *)buf + n;
        bytes -= (size_t)n;
    }
    return true;
}

bool omniwm_dock_slide_available(void) {
    int fd = openDock();
    if (fd < 0) return false;
    const uint8_t query[] = {1, 0, 1};
    uint8_t answer[12];
    bool ok = write(fd, query, sizeof(query)) == sizeof(query)
        && reply(fd, answer, sizeof(answer)) && !memcmp(answer, "2.1.45", 7) && answer[11] == '\n';
    close(fd);
    return ok;
}

bool omniwm_dock_slide_geometry(uint32_t wid, CGRect *base, CGAffineTransform *transform) {
    static int (*connection)(void);
    static CGError (*bounds)(int, uint32_t, CGRect *);
    static CGError (*matrix)(int, uint32_t, CGAffineTransform *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (lib) {
            connection = dlsym(lib, "SLSMainConnectionID");
            bounds = dlsym(lib, "SLSGetWindowBounds");
            matrix = dlsym(lib, "SLSGetWindowTransform");
        }
    });
    if (!connection || !bounds || !matrix) return false;
    int cid = connection();
    // Bounds and transform are separate WindowServer reads. A move between them
    // can make a normal window appear translated by its entire parking distance.
    for (int attempt = 0; attempt < 3; ++attempt) {
        CGRect after;
        if (bounds(cid, wid, base) || matrix(cid, wid, transform) || bounds(cid, wid, &after)) return false;
        if (CGRectEqualToRect(*base, after)) return true;
    }
    return false;
}

static int queueRequest(const void *request, size_t size) {
    int fd = openDock();
    if (fd >= 0 && write(fd, request, size) != (ssize_t)size) {
        close(fd);
        return -1;
    }
    return fd;
}

static int queueMove(OmniWMDockSlideMove move) {
    // Choose scale 1 in do_window_scale, then translate to the requested top-left.
    struct __attribute__((packed)) {
        uint16_t length;
        uint8_t opcode;
        uint32_t wid;
        float x, y, width, height;
    } req = {21, 13, move.window, move.target.x - 3 * move.baseWidth,
             move.target.y, 4 * move.baseWidth, move.baseHeight};
    return queueRequest(&req, sizeof(req));
}

bool omniwm_dock_slide_submit(const OmniWMDockSlideMove *moves, size_t count) {
    if (!count) return true;
    int *fds = calloc(count, 2 * sizeof(*fds));
    if (!fds) return false;
    size_t queued = 0;
    bool ok = true;
    // The service accepts in connection order. Submit each reset/set pair back-to-back,
    // then collect replies after all windows are queued, avoiding a round trip per toggle.
    for (size_t i = 0; i < count && ok; ++i) {
        unsigned requests = (unsigned)moves[i].resetFirst + (unsigned)moves[i].apply;
        for (unsigned j = 0; j < requests; ++j) {
            int fd = queueMove(moves[i]);
            if (fd < 0) { ok = false; break; }
            fds[queued++] = fd;
        }
    }
    for (size_t i = 0; i < queued; ++i) {
        uint8_t ack;
        if (!reply(fds[i], &ack, 1) || ack) ok = false;
        close(fds[i]);
    }
    free(fds);
    return ok;
}


bool omniwm_dock_slide_at_position(CGAffineTransform transform, CGPoint position) {
    // Window bounds can be rounded to points while the drawing origin is on a Retina half-point.
    return transform.a == 1 && transform.b == 0 && transform.c == 0 && transform.d == 1
        && fabs(transform.tx + position.x) <= 0.5 && fabs(transform.ty + position.y) <= 0.5;
}

// Only for windows whose baseline was verified before this slide took ownership.
bool omniwm_dock_slide_restore_translation(uint32_t window) {
    for (int attempt = 0; attempt <= 5; ++attempt) {
        if (attempt > 1) usleep(1000);
        CGRect base;
        CGAffineTransform transform;
        if (!omniwm_dock_slide_geometry(window, &base, &transform)) return false;
        if (omniwm_dock_slide_at_position(transform, base.origin)) return true;
        if (transform.a != 1 || transform.b != 0 || transform.c != 0 || transform.d != 1 || attempt == 5)
            return false;
        OmniWMDockSlideMove reset = {window, base.size.width, base.size.height, base.origin, true, false};
        omniwm_dock_slide_submit(&reset, 1);
    }
    return false;
}
