#ifndef PINECONE_TEXT_INSERTION_TRACE_H
#define PINECONE_TEXT_INSERTION_TRACE_H

/* One shared runtime must be linked by both instrumented packages. */
typedef struct { unsigned id, parent; } PineconeTextScope;
__attribute__((visibility("default")))
PineconeTextScope pinecone_text_begin(const char *name, int edit_root);
__attribute__((visibility("default")))
void pinecone_text_end(PineconeTextScope *scope);

#define PC_TEXT_JOIN_(a, b) a##b
#define PC_TEXT_JOIN(a, b) PC_TEXT_JOIN_(a, b)
#define PC_TEXT_SCOPE(name, root) \
  PineconeTextScope PC_TEXT_JOIN(pc_text_scope_, __COUNTER__) \
    __attribute__((cleanup(pinecone_text_end))) = \
    pinecone_text_begin((name), (root))
#define PC_TEXT_CALL(name, call) do { PC_TEXT_SCOPE((name), 0); call; } while (0)

#endif
