#include "ARM64VizVirGL.h"
#import <Foundation/Foundation.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <dlfcn.h>
#include <sys/uio.h>

/* Public EGL / virglrenderer embedding ABI, deliberately independent of
 * build-time third-party headers. See scripts/graphics/ for pinned sources.
 * Libraries are loaded only from an explicit application/dependency directory.
 * libepoxy caches function pointers, so library handles remain process-lived. */
typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface;
typedef unsigned EGLBoolean;
typedef int EGLint;
typedef struct { int version; _Bool shared; int major, minor, compat; } ContextParameters;
typedef struct { uint32_t x, y, z, w, h, d; } Box;
typedef struct {
    int version;
    void (*fence)(void *, uint32_t);
    void *(*create)(void *, int, ContextParameters *);
    void (*destroy)(void *, void *);
    int (*current)(void *, int, void *);
} Callbacks;
#define API(ret, name, args) ret (*name) args
typedef struct {
    API(EGLDisplay, eglGetPlatformDisplayEXT, (unsigned, void *, const EGLint *));
    API(EGLBoolean, eglInitialize, (EGLDisplay, EGLint *, EGLint *));
    API(EGLBoolean, eglBindAPI, (unsigned));
    API(EGLBoolean, eglChooseConfig, (EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *));
    API(EGLContext, eglCreateContext, (EGLDisplay, EGLConfig, EGLContext, const EGLint *));
    API(EGLBoolean, eglDestroyContext, (EGLDisplay, EGLContext));
    API(EGLBoolean, eglMakeCurrent, (EGLDisplay, EGLSurface, EGLSurface, EGLContext));
    API(EGLContext, eglGetCurrentContext, (void));
    API(EGLBoolean, eglTerminate, (EGLDisplay));
    API(void *, eglGetProcAddress, (const char *));
    API(const unsigned char *, glGetString, (unsigned));
    API(void, glFinish, (void));
    API(int, virgl_renderer_init, (void *, int, Callbacks *));
    API(void, virgl_renderer_cleanup, (void *));
    API(void, virgl_renderer_reset, (void));
    API(void, virgl_renderer_get_cap_set, (uint32_t, uint32_t *, uint32_t *));
    API(void, virgl_renderer_fill_caps, (uint32_t, uint32_t, void *));
    API(int, virgl_renderer_context_create, (uint32_t, uint32_t, const char *));
    API(void, virgl_renderer_context_destroy, (uint32_t));
    API(int, virgl_renderer_resource_create, (const AVZVirGLResource *, struct iovec *, uint32_t));
    API(void, virgl_renderer_resource_unref, (uint32_t));
    API(void, virgl_renderer_ctx_attach_resource, (int, int));
    API(void, virgl_renderer_ctx_detach_resource, (int, int));
    API(int, virgl_renderer_resource_attach_iov, (int, struct iovec *, int));
    API(void, virgl_renderer_resource_detach_iov, (int, struct iovec **, int *));
    API(int, virgl_renderer_transfer_write_iov, (uint32_t, uint32_t, int, uint32_t, uint32_t, Box *, uint64_t, struct iovec *, unsigned));
    API(int, virgl_renderer_transfer_read_iov, (uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, Box *, uint64_t, struct iovec *, int));
    API(int, virgl_renderer_submit_cmd, (void *, int, int));
} Functions;
#undef API
typedef struct Backing {
    uint32_t id;
    struct iovec iov;
    struct Backing *next;
} Backing;
typedef struct Job Job;
struct AVZVirGL {
    Functions api;
    pthread_t thread;
    pthread_mutex_t caller, mutex;
    pthread_cond_t condition;
    Job *job;
    int ready, success, stop;
    EGLDisplay display;
    EGLConfig config;
    EGLContext root;
    Callbacks callbacks;
    Backing *backings;
    size_t backing_bytes;
    char status[256];
};
enum { RESET, CAPSET, CAPS, CONTEXT_CREATE, CONTEXT_DESTROY, RESOURCE_CREATE,
       RESOURCE_UNREF, CONTEXT_RESOURCE, ATTACH, DETACH, COPY, TRANSFER, SUBMIT, READ_PIXELS, FINISH };
struct Job {
    unsigned op;
    uint32_t a, b, c;
    size_t offset, size;
    void *data;
    int result, done;
};
static pthread_mutex_t owner_mutex = PTHREAD_MUTEX_INITIALIZER;
static AVZVirGL *owner;

static int load(AVZVirGL *r, const char *directory) {
    if (!directory || !*directory) return 0;
    const char *frameworks[] = {"GLESv2", "EGL", "epoxy.0", "virglrenderer.1"};
    void *handles[4];
    for (unsigned i = 0; i < 4; i++) {
        char path[4096];
        if (snprintf(path, sizeof(path), "%s/%s.framework/%s", directory, frameworks[i], frameworks[i]) >= (int)sizeof(path)) return 0;
        handles[i] = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        if (!handles[i]) { snprintf(r->status, sizeof(r->status), "Cannot load %s: %.180s", frameworks[i], dlerror()); return 0; }
    }
#define LOAD(name, handle) do { *(void **)(&r->api.name) = dlsym(handles[handle], #name); \
    if (!r->api.name) { snprintf(r->status, sizeof(r->status), "Missing symbol %s", #name); return 0; } } while (0)
    LOAD(eglInitialize, 1); LOAD(eglBindAPI, 1); LOAD(eglChooseConfig, 1);
    LOAD(eglCreateContext, 1); LOAD(eglDestroyContext, 1); LOAD(eglMakeCurrent, 1);
    LOAD(eglGetCurrentContext, 1); LOAD(eglTerminate, 1); LOAD(eglGetProcAddress, 1);
    *(void **)(&r->api.eglGetPlatformDisplayEXT) = r->api.eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!r->api.eglGetPlatformDisplayEXT) return 0;
    LOAD(glGetString, 0); LOAD(glFinish, 0);
    LOAD(virgl_renderer_init, 3); LOAD(virgl_renderer_cleanup, 3); LOAD(virgl_renderer_reset, 3);
    LOAD(virgl_renderer_get_cap_set, 3); LOAD(virgl_renderer_fill_caps, 3);
    LOAD(virgl_renderer_context_create, 3); LOAD(virgl_renderer_context_destroy, 3);
    LOAD(virgl_renderer_resource_create, 3); LOAD(virgl_renderer_resource_unref, 3);
    LOAD(virgl_renderer_ctx_attach_resource, 3); LOAD(virgl_renderer_ctx_detach_resource, 3);
    LOAD(virgl_renderer_resource_attach_iov, 3); LOAD(virgl_renderer_resource_detach_iov, 3);
    LOAD(virgl_renderer_transfer_write_iov, 3); LOAD(virgl_renderer_transfer_read_iov, 3);
    LOAD(virgl_renderer_submit_cmd, 3);
#undef LOAD
    return 1;
}
static void fence(void *cookie, uint32_t id) { (void)cookie; (void)id; }
static void *context(void *cookie, int scanout, ContextParameters *p) {
    (void)scanout;
    AVZVirGL *r = cookie;
    EGLContext share = r->api.eglGetCurrentContext();
    EGLint attrs[] = {0x3098, p->major, 0x30fb, p->minor, 0x3038};
    return r->api.eglCreateContext(r->display, r->config, share ? share : r->root, attrs);
}
static void destroy_context(void *cookie, void *ctx) {
    AVZVirGL *r = cookie; r->api.eglDestroyContext(r->display, ctx);
}
static int current(void *cookie, int scanout, void *ctx) {
    (void)scanout; AVZVirGL *r = cookie;
    return r->api.eglMakeCurrent(r->display, NULL, NULL, ctx) ? 0 : -EIO;
}
static int initialize(AVZVirGL *r) {
    // Explicit Metal selection; never silently fall back to another renderer.
    EGLint platform[] = {0x3203, 0x3489, 0x3038};
    r->display = r->api.eglGetPlatformDisplayEXT(0x3202, NULL, platform);
    EGLint major = 0, minor = 0, count = 0;
    EGLint attrs[] = {0x3040, 0x40, 0x3033, 1, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038};
    EGLint ctx[] = {0x3098, 3, 0x3038};
    if (!r->display || !r->api.eglInitialize(r->display, &major, &minor) ||
        !r->api.eglBindAPI(0x30a0) ||
        !r->api.eglChooseConfig(r->display, attrs, &r->config, 1, &count) || count != 1 ||
        !(r->root = r->api.eglCreateContext(r->display, r->config, NULL, ctx)) ||
        !r->api.eglMakeCurrent(r->display, NULL, NULL, r->root)) {
        snprintf(r->status, sizeof(r->status), "ANGLE Metal EGL initialization failed"); return 0;
    }
    const char *name = (const char *)r->api.glGetString(0x1f01);
    if (!name || !strstr(name, "Metal")) {
        snprintf(r->status, sizeof(r->status), "Host renderer did not select Metal"); return 0;
    }
    r->callbacks = (Callbacks){1, fence, context, destroy_context, current};
    if (r->api.virgl_renderer_init(r, 1 << 4, &r->callbacks)) {
        snprintf(r->status, sizeof(r->status), "VirGL GLES initialization failed"); return 0;
    }
    snprintf(r->status, sizeof(r->status), "%s", name);
    return 1;
}
static Backing *backing(AVZVirGL *r, uint32_t id) {
    for (Backing *b = r->backings; b; b = b->next) if (b->id == id) return b;
    return NULL;
}
static void release_backings(AVZVirGL *r) {
    while (r->backings) {
        Backing *b = r->backings; r->backings = b->next; free(b->iov.iov_base); free(b);
    }
    r->backing_bytes = 0;
}
static int execute(AVZVirGL *r, Job *j) {
    Functions *f = &r->api;
    switch (j->op) {
    case FINISH: f->glFinish(); return 0;
    case RESET: f->glFinish(); f->virgl_renderer_reset(); release_backings(r); return 0;
    case CAPSET: f->virgl_renderer_get_cap_set(j->a, j->data, (uint32_t *)j->data + 1); return 0;
    case CAPS: f->virgl_renderer_fill_caps(j->a, j->b, j->data); return 0;
    case CONTEXT_CREATE: return f->virgl_renderer_context_create(j->a, (uint32_t)j->size, j->data);
    case CONTEXT_DESTROY: f->glFinish(); f->virgl_renderer_context_destroy(j->a); return 0;
    case RESOURCE_CREATE: return f->virgl_renderer_resource_create(j->data, NULL, 0);
    case RESOURCE_UNREF: {
        f->glFinish();
        Backing **previous = &r->backings;
        while (*previous && (*previous)->id != j->a) previous = &(*previous)->next;
        if (*previous) {
            Backing *b = *previous;
            f->virgl_renderer_resource_detach_iov((int)j->a, NULL, NULL);
            *previous = b->next; r->backing_bytes -= b->iov.iov_len;
            free(b->iov.iov_base); free(b);
        }
        f->virgl_renderer_resource_unref(j->a); return 0;
    }
    case CONTEXT_RESOURCE:
        if (j->c) f->virgl_renderer_ctx_attach_resource((int)j->a, (int)j->b);
        else f->virgl_renderer_ctx_detach_resource((int)j->a, (int)j->b);
        return 0;
    case ATTACH: {
        if (!j->size || j->size > 256u * 1024u * 1024u ||
            r->backing_bytes > 512u * 1024u * 1024u - j->size || backing(r, j->a)) return -EINVAL;
        Backing *b = calloc(1, sizeof(*b));
        if (!b) return -ENOMEM;
        b->iov.iov_base = calloc(1, j->size); b->iov.iov_len = j->size; b->id = j->a;
        if (!b->iov.iov_base) { free(b); return -ENOMEM; }
        int error = f->virgl_renderer_resource_attach_iov((int)j->a, &b->iov, 1);
        if (error) { free(b->iov.iov_base); free(b); return error; }
        b->next = r->backings; r->backings = b; r->backing_bytes += j->size; return 0;
    }
    case DETACH: {
        Backing **previous = &r->backings;
        while (*previous && (*previous)->id != j->a) previous = &(*previous)->next;
        if (!*previous) return 0;
        f->glFinish(); f->virgl_renderer_resource_detach_iov((int)j->a, NULL, NULL);
        Backing *b = *previous; *previous = b->next; r->backing_bytes -= b->iov.iov_len;
        free(b->iov.iov_base); free(b); return 0;
    }
    case COPY: {
        Backing *b = backing(r, j->a);
        if (!b || j->offset > b->iov.iov_len || j->size > b->iov.iov_len - j->offset) return -EINVAL;
        if (j->c) memcpy((char *)b->iov.iov_base + j->offset, j->data, j->size);
        else memcpy(j->data, (char *)b->iov.iov_base + j->offset, j->size);
        return 0;
    }
    case TRANSFER: {
        AVZVirGLTransfer *t = j->data;
        Box box = {t->x, t->y, t->z, t->width, t->height, t->depth};
        if (!backing(r, t->handle)) return -EINVAL;
        if (j->c) return f->virgl_renderer_transfer_write_iov(t->handle, t->context,
            (int)t->level, t->stride, t->layer_stride, &box, t->offset, NULL, 0);
        f->glFinish();
        return f->virgl_renderer_transfer_read_iov(t->handle, t->context, t->level,
            t->stride, t->layer_stride, &box, t->offset, NULL, 0);
    }
    case SUBMIT: {
        int error = f->virgl_renderer_submit_cmd(j->data, (int)j->a, (int)j->size);
        // Complete actual GPU writes before acknowledging the virtqueue fence.
        f->glFinish(); return error;
    }
    case READ_PIXELS: {
        if (!j->b || !j->c || j->b > 16384 || j->c > 16384 ||
            (uint64_t)j->b * j->c * 4 != j->size) return -EINVAL;
        Box box = {0, 0, 0, j->b, j->c, 1};
        struct iovec iov = {j->data, j->size};
        f->glFinish();
        return f->virgl_renderer_transfer_read_iov(j->a, 0, 0, j->b * 4, 0, &box, 0, &iov, 1);
    }
    }
    return -EINVAL;
}
static void *worker(void *opaque) {
    AVZVirGL *r = opaque;
    @autoreleasepool { r->success = initialize(r); }
    pthread_mutex_lock(&r->mutex); r->ready = 1; pthread_cond_broadcast(&r->condition);
    while (r->success && !r->stop) {
        while (!r->job && !r->stop) pthread_cond_wait(&r->condition, &r->mutex);
        if (r->stop) break;
        Job *j = r->job; pthread_mutex_unlock(&r->mutex);
        @autoreleasepool { j->result = execute(r, j); }
        pthread_mutex_lock(&r->mutex); j->done = 1; r->job = NULL; pthread_cond_broadcast(&r->condition);
    }
    pthread_mutex_unlock(&r->mutex);
    @autoreleasepool {
        if (r->success) { r->api.glFinish(); r->api.virgl_renderer_cleanup(r); }
        release_backings(r);
        if (r->display) {
            r->api.eglMakeCurrent(r->display, NULL, NULL, NULL);
            if (r->root) r->api.eglDestroyContext(r->display, r->root);
            r->api.eglTerminate(r->display);
        }
    }
    return NULL;
}
AVZVirGL *avz_virgl_create(const char *directory, char *status, size_t size) {
    pthread_mutex_lock(&owner_mutex);
    AVZVirGL *r = NULL;
    if (owner) { if (size) snprintf(status, size, "VirGL is already owned by another device"); goto done; }
    r = calloc(1, sizeof(*r));
    if (!r) goto done;
    if (!load(r, directory)) { if (size) snprintf(status, size, "%s", r->status); free(r); r = NULL; goto done; }
    pthread_mutex_init(&r->caller, NULL); pthread_mutex_init(&r->mutex, NULL); pthread_cond_init(&r->condition, NULL);
    if (pthread_create(&r->thread, NULL, worker, r)) {
        if (size) snprintf(status, size, "Cannot create VirGL GPU thread");
        pthread_mutex_destroy(&r->caller); pthread_mutex_destroy(&r->mutex); pthread_cond_destroy(&r->condition);
        free(r); r = NULL; goto done;
    }
    pthread_mutex_lock(&r->mutex);
    while (!r->ready) pthread_cond_wait(&r->condition, &r->mutex);
    pthread_mutex_unlock(&r->mutex);
    if (size) snprintf(status, size, "%s", r->status);
    if (!r->success) {
        pthread_join(r->thread, NULL);
        pthread_mutex_destroy(&r->caller); pthread_mutex_destroy(&r->mutex); pthread_cond_destroy(&r->condition);
        free(r); r = NULL;
    } else owner = r;
done: pthread_mutex_unlock(&owner_mutex); return r;
}
void avz_virgl_destroy(AVZVirGL *r) {
    if (!r) return;
    pthread_mutex_lock(&owner_mutex); pthread_mutex_lock(&r->caller); pthread_mutex_lock(&r->mutex);
    r->stop = 1; pthread_cond_broadcast(&r->condition); pthread_mutex_unlock(&r->mutex);
    pthread_join(r->thread, NULL); pthread_mutex_unlock(&r->caller);
    pthread_mutex_destroy(&r->caller); pthread_mutex_destroy(&r->mutex); pthread_cond_destroy(&r->condition);
    owner = NULL; free(r); pthread_mutex_unlock(&owner_mutex);
}
static int call(AVZVirGL *r, Job job) {
    if (!r) return -ENODEV;
    pthread_mutex_lock(&r->caller); pthread_mutex_lock(&r->mutex);
    r->job = &job; pthread_cond_broadcast(&r->condition);
    while (!job.done) pthread_cond_wait(&r->condition, &r->mutex);
    pthread_mutex_unlock(&r->mutex); pthread_mutex_unlock(&r->caller); return job.result;
}
int avz_virgl_reset(AVZVirGL *r) { return call(r, (Job){.op = RESET}); }
int avz_virgl_finish(AVZVirGL *r) { return call(r, (Job){.op = FINISH}); }
int avz_virgl_capset(AVZVirGL *r, uint32_t id, uint32_t *version, uint32_t *size) {
    uint32_t values[2] = {0}; int error = call(r, (Job){.op = CAPSET, .a = id, .data = values});
    *version = values[0]; *size = values[1]; return error;
}
int avz_virgl_caps(AVZVirGL *r, uint32_t id, uint32_t version, void *data, size_t size) {
    uint32_t max_version, required;
    int error = avz_virgl_capset(r, id, &max_version, &required);
    if (error || !required || version > max_version || size < required) return -EINVAL;
    return call(r, (Job){.op = CAPS, .a = id, .b = version, .data = data});
}
int avz_virgl_context_create(AVZVirGL *r, uint32_t id, const char *name, uint32_t size) {
    return call(r, (Job){.op = CONTEXT_CREATE, .a = id, .data = (void *)name, .size = size});
}
int avz_virgl_context_destroy(AVZVirGL *r, uint32_t id) { return call(r, (Job){.op = CONTEXT_DESTROY, .a = id}); }
int avz_virgl_resource_create(AVZVirGL *r, const AVZVirGLResource *resource) {
    return call(r, (Job){.op = RESOURCE_CREATE, .data = (void *)resource});
}
int avz_virgl_resource_unref(AVZVirGL *r, uint32_t id) { return call(r, (Job){.op = RESOURCE_UNREF, .a = id}); }
int avz_virgl_context_resource(AVZVirGL *r, uint32_t ctx, uint32_t id, int attach) {
    return call(r, (Job){.op = CONTEXT_RESOURCE, .a = ctx, .b = id, .c = !!attach});
}
int avz_virgl_backing_attach(AVZVirGL *r, uint32_t id, size_t size) { return call(r, (Job){.op = ATTACH, .a = id, .size = size}); }
int avz_virgl_backing_detach(AVZVirGL *r, uint32_t id) { return call(r, (Job){.op = DETACH, .a = id}); }
int avz_virgl_backing_copy(AVZVirGL *r, uint32_t id, size_t offset, void *bytes, size_t size, int to_host) {
    return call(r, (Job){.op = COPY, .a = id, .c = !!to_host, .offset = offset, .data = bytes, .size = size});
}
int avz_virgl_transfer(AVZVirGL *r, const AVZVirGLTransfer *transfer, int to_host) {
    return call(r, (Job){.op = TRANSFER, .c = !!to_host, .data = (void *)transfer});
}
int avz_virgl_submit(AVZVirGL *r, uint32_t ctx, const uint32_t *words, size_t count) {
    if (!count || count > 262144) return -EINVAL;
    return call(r, (Job){.op = SUBMIT, .a = ctx, .data = (void *)words, .size = count});
}
int avz_virgl_read_pixels(AVZVirGL *r, uint32_t id, uint32_t width, uint32_t height, void *bytes, size_t size) {
    return call(r, (Job){.op = READ_PIXELS, .a = id, .b = width, .c = height, .data = bytes, .size = size});
}
