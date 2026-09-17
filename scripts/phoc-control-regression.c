#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include "pinecone-trace.c"

int main(void) {
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    assert(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0);
    initialized = 1;
    trace_fd = -1;
    control_fd = descriptors[1];
    int output;
    pinecone_trace_begin(&output, 1);
    pinecone_trace_app(&output, "org.gnome.Settings");
    pinecone_trace_present(&output, 1, 1);
    char result[256] = {0};
    ssize_t count = read(descriptors[0], result, sizeof(result) - 1);
    assert(count > 0);
    assert(strcmp(result, "\036PINECONE_APP_PRESENTED org.gnome.Settings\n") == 0);
    /* Exhausted diagnostics must not disable scheduling control. */
    trace_fd = descriptors[1];
    records = 8192;
    last_control = 0;
    pinecone_trace_begin(&output, 2);
    pinecone_trace_app(&output, "org.gnome.Settings");
    pinecone_trace_present(&output, 2, 1);
    assert(read(descriptors[0], result, sizeof(result)) > 0);
    pinecone_trace_begin(&output, 3);
    pinecone_trace_app(&output, "org.gnome.Settings");
    pinecone_trace_present(&output, 3, 0);
    assert(read(descriptors[0], result, sizeof(result)) == -1);
    pinecone_trace_begin(&output, 4);
    pinecone_trace_app(&output, "invalid\napp");
    pinecone_trace_present(&output, 4, 1);
    assert(read(descriptors[0], result, sizeof(result)) == -1);
    close(descriptors[0]);
    close(descriptors[1]);
    return 0;
}
