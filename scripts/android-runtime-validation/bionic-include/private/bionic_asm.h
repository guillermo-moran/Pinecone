/* Only the symbol/linker adapter for the pinned optional upstream strlen.S.
 * Instruction text and upstream licensing remain in the caller-supplied file. */
#ifdef __APPLE__
#define AVZ_BIONIC_SYMBOL _av_bionic_strlen
#define AVZ_BIONIC_END _av_bionic_strlen_end
#else
#define AVZ_BIONIC_SYMBOL av_bionic_strlen
#define AVZ_BIONIC_END av_bionic_strlen_end
#endif
.macro AVZ_BIONIC_ENTRY
    .text
    .p2align 4
    .globl AVZ_BIONIC_SYMBOL
AVZ_BIONIC_SYMBOL:
.endm
.macro AVZ_BIONIC_FINISH
    .globl AVZ_BIONIC_END
AVZ_BIONIC_END:
.endm
#define ENTRY(name) AVZ_BIONIC_ENTRY
#define END(name) AVZ_BIONIC_FINISH
