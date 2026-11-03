/* Reuse isolated memory/cache spies and memory correctness scenarios. */
#define main avz_existing_memory_harness_main
#include "native-memory-fastpath-harness.c"
#undef main

static void instruction_checks(void) {
    Context context = {.memory = avz_guest_memory_create(RAM_SIZE)};
    CHECK(context.memory);
    AVZNativeMemoryFastPath *path = make_path(&context);
    avz_native_memory_fast_path_set_instruction_translator(path, translate);
    for (unsigned page = 0; page < 64; page++) {
        avz_fast_store_value(context.memory->bytes + page * 4096, 4, 0xd503201f + page);
    }
    uint32_t instruction;
    uint64_t physical;
    for (unsigned pass = 0; pass < 4; pass++)
    for (unsigned page = 0; page < 64; page++) {
        CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE + page * 4096, &physical, &instruction));
        CHECK(physical == RAM_BASE + page * 4096 && instruction == 0xd503201f + page);
    }
    avz_native_memory_fast_path_invalidate_translation(path);
    for (unsigned page = 0; page < 16; page++)
        CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE + page * 4096, &physical, &instruction));
    CHECK(path->instruction_hot[15].virtual_page == (RAM_BASE >> 12) + 15);
    for (unsigned reuse = 0; reuse < 2; reuse++)
        CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE + 15 * 4096, &physical, &instruction));
#if AVZ_INSTRUCTION_TLB_MRU
    CHECK(path->instruction_hot[0].virtual_page == (RAM_BASE >> 12) + 15);
#endif
    // Promoted mappings cache no instruction bytes: guest/host code updates
    // still become visible through the ordinary acquire instruction fetch.
    avz_fast_store_value(context.memory->bytes + 15 * 4096, 4, 0x14000000);
    avz_guest_memory_note_write(context.memory, 15 * 4096, 4);
    CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE + 15 * 4096, &physical, &instruction));
    CHECK(instruction == 0x14000000);
    // Every local/shared scope must clear or reprove the hot hint; callback
    // translations have unknown extents and are conservatively invalidated.
    for (unsigned shared = 0; shared < 2; shared++)
    for (unsigned kind = 0; kind <= AVZ_TLBI_VA_ALL_ASIDS; kind++) {
        context.bias = 0;
        avz_native_memory_fast_path_invalidate_translation(path);
        CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE, &physical, &instruction));
        CHECK(instruction == 0xd503201f);
        context.bias = 4096;
        AVZNativeTLBI invalidation = {.kind = kind, .virtual_address = RAM_BASE};
        if (shared) avz_guest_memory_publish_tlbi(context.memory, invalidation);
        else avz_native_memory_fast_path_apply_tlbi(path, invalidation);
        CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE, &physical, &instruction));
        CHECK(physical == RAM_BASE + 4096 && instruction == 0xd5032020);
    }
    context.bias = 0;
    avz_native_memory_fast_path_invalidate_translation(path);
    CHECK(!avz_native_fast_fetch_instruction(path, RAM_BASE + 1, &physical, &instruction));
    CHECK(!avz_native_fast_fetch_instruction(path, RAM_BASE + RAM_SIZE, &physical, &instruction));
    // Translator replacement must retire the hinted translation as well.
    CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE, &physical, &instruction));
    context.bias = 4096;
    avz_native_memory_fast_path_set_instruction_translator(path, translate);
    CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE, &physical, &instruction));
    CHECK(physical == RAM_BASE + 4096);

    // Native 2-MiB block mappings: address-space change, targeted peer remap,
    // and execute-never permission faults after a previously successful hint.
    size_t tables = RAM_SIZE - 16384;
    avz_fast_store_value(path->ram + tables, 8, RAM_BASE + tables + 4096 + 3);
    avz_fast_store_value(path->ram + tables + 4096 + 8, 8, RAM_BASE + tables + 8192 + 3);
    uint8_t *leaf = path->ram + tables + 8192;
    uint64_t descriptor = RAM_BASE | AVZ_STAGE1_ACCESS_FLAG_BIT | (UINT64_C(1) << 11) | 1;
    avz_fast_store_value(leaf, 8, descriptor);
    AVZNativeStage1TranslationState state = {.sctlr_el1 = 1, .tcr_el1 = 16,
        .ttbr0_el1 = RAM_BASE + tables, .current_el = 1};
    avz_native_memory_fast_path_set_stage1_translation(path, &state, NULL);
    CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE, &physical, &instruction));
    avz_fast_store_value(path->ram + 2 * 1024 * 1024, 4, 0x14000000);
    avz_fast_store_value(leaf, 8, descriptor + 2 * 1024 * 1024);
    state.ttbr0_el1 |= UINT64_C(1) << 48;
    avz_native_memory_fast_path_set_stage1_translation(path, &state, NULL);
    CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE, &physical, &instruction));
    CHECK(physical == RAM_BASE + 2 * 1024 * 1024 && instruction == 0x14000000);
    avz_fast_store_value(leaf, 8, descriptor | AVZ_STAGE1_PRIVILEGED_EXECUTE_NEVER_BIT);
    avz_guest_memory_publish_tlbi(context.memory, (AVZNativeTLBI){
        .kind = AVZ_TLBI_VA_ASID, .asid = 1, .virtual_address = RAM_BASE});
    CHECK(!avz_native_fast_fetch_instruction(path, RAM_BASE, &physical, &instruction));
    CHECK(path->translation_fault_pending);
    avz_native_memory_fast_path_clear_translation_fault(path);
    avz_fast_store_value(leaf, 8, descriptor);
    avz_guest_memory_publish_tlbi(context.memory, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL});
    CHECK(avz_native_fast_fetch_instruction(path, RAM_BASE, &physical, &instruction));
    CHECK(physical == RAM_BASE);
    avz_native_memory_fast_path_destroy(path);
    avz_guest_memory_destroy(context.memory);
    printf("PASS instruction hot TLB: associative fallback, scope/remap, ASID, PXN, replacement\n");
}

__attribute__((noinline)) static uint64_t translate_probe(AVZNativeMemoryFastPath *path, uint64_t address) {
    uint64_t physical = 0;
    uint8_t *host = NULL;
    CHECK(avz_fast_translate_instruction(path, address, &physical, &host));
    return physical;
}

int main(int argc, char **argv) {
    if (argc < 2 || strcmp(argv[1], "--benchmark")) {
        instruction_checks();
        return 0;
    }
    size_t iterations = argc > 2 ? strtoull(argv[2], NULL, 10) : 2000000;
    for (unsigned native = 0; native < 2; native++)
    for (unsigned pattern = 0; pattern < 5; pattern++) {
        Context context = {.memory = avz_guest_memory_create(RAM_SIZE)};
        CHECK(context.memory);
        AVZNativeMemoryFastPath *path = make_path(&context);
        avz_native_memory_fast_path_set_instruction_translator(path, translate);
        if (native) enable_block_translation(path);
        for (unsigned page = 0; page < 16; page++)
            (void)translate_probe(path, RAM_BASE + page * 4096);
        uint64_t checksum = 0, start = now_ns();
        for (size_t i = 0; i < iterations; i++) {
            unsigned page = pattern == 0 ? 0 : pattern == 1 ? 15 :
                pattern == 2 ? ((i >> 6) & 15) : pattern == 3 ? (i & 15) : (i & 63);
            checksum += translate_probe(path, RAM_BASE + page * 4096);
        }
        uint64_t elapsed = now_ns() - start;
        uint64_t expected = 0;
        for (size_t i = 0; i < iterations; i++) {
            unsigned page = pattern == 0 ? 0 : pattern == 1 ? 15 :
                pattern == 2 ? ((i >> 6) & 15) : pattern == 3 ? (i & 15) : (i & 63);
            expected += RAM_BASE + page * 4096;
        }
        CHECK(checksum == expected);
        printf("native=%u pattern=%u ns=%.3f checksum=%" PRIu64 "\n", native, pattern,
            (double)elapsed / iterations, checksum);
        avz_native_memory_fast_path_destroy(path);
        avz_guest_memory_destroy(context.memory);
    }
    return 0;
}
