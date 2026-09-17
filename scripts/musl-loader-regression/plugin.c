extern int provider(void);
int plugin(void) { return provider() + 3; }
__thread int plugin_tls = 37;
int *plugin_tls_address(void) { return &plugin_tls; }
int absent_weak(void) { return 89; }
