#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

extern int provider(void);
extern int provider_value;
extern __thread int provider_tls;
extern int versioned(void);
extern int binding_order(void);
extern int absent_weak(void) __attribute__((weak));

/* Distinct relocation sites must agree even when the startup cache hits. */
static int (*volatile references[512])(void) = { [0 ... 511] = provider };
static int (*volatile missing[512])(void) = { [0 ... 511] = absent_weak };

static int *(*tls_address)(void);

static void *check_dynamic_tls(void *unused)
{
    (void)unused;
    assert(*tls_address() == 37);
    *tls_address() = 41;
    return NULL;
}

static void *check_tls(void *unused)
{
    (void)unused;
    assert(provider_tls == 11);
    provider_tls = 29;
    assert(provider_tls == 29);
    return NULL;
}

int main(int argc, char **argv)
{
    assert(argc == 4);
    int expected = atoi(argv[2]);
    assert(absent_weak == NULL);
    assert(provider_value == 17);
    assert(versioned() == atoi(argv[3]));
    assert(binding_order() == 71);
    for (size_t i = 0; i < sizeof(references) / sizeof(references[0]); i++)
    {
        assert(references[i]() == expected);
        assert(missing[i] == NULL);
    }
    pthread_t thread;
    assert(pthread_create(&thread, NULL, check_tls, NULL) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(provider_tls == 11);

    /* Runtime lookup must not reuse startup misses or cross a local scope. */
    assert(dlsym(RTLD_DEFAULT, "plugin") == NULL);
    for (int i = 0; i < 20; i++) {
        void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        assert(handle != NULL);
        int (*call)(void) = (int (*)(void))dlsym(handle, "plugin");
        assert(call != NULL && call() == expected + 3);
        tls_address = (int *(*)(void))dlsym(handle, "plugin_tls_address");
        assert(tls_address != NULL && *tls_address() == 37);
        assert(pthread_create(&thread, NULL, check_dynamic_tls, NULL) == 0);
        assert(pthread_join(thread, NULL) == 0);
        assert(*tls_address() == 37);
        assert(dlsym(RTLD_DEFAULT, "absent_weak") == NULL);
        assert(dlsym(RTLD_DEFAULT, "plugin") == NULL);
        assert(dlsym(handle, "absent_symbol") == NULL);
        assert(dlerror() != NULL);
        assert(dlclose(handle) == 0);
    }
    void *global = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    assert(global != NULL);
    assert(dlsym(RTLD_DEFAULT, "plugin") != NULL);
    int (*late_weak)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "absent_weak");
    assert(late_weak != NULL && late_weak() == 89);
    assert(absent_weak == NULL && missing[0] == NULL);
    assert(dlclose(global) == 0);
    puts("loader relocation, versions, binding, weak, TLS, preload and runtime scopes: PASS");
    return 0;
}
