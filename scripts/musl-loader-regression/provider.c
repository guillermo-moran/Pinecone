__thread int provider_tls = 11;
int provider_value = 17;
int provider(void) { return provider_value + provider_tls; }

int version_old(void) { return -1; }
int version_default(void) { return 61; }
__asm__(".symver version_old,versioned@OLD");
__asm__(".symver version_default,versioned@@CURRENT");

__attribute__((weak)) int binding_order(void) { return 71; }
