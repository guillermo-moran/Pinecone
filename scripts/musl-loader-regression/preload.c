int provider(void) { return 43; }
/* musl chooses the first acceptable binding, even when it is weak. */
__attribute__((weak)) int versioned(void) { return 81; }
