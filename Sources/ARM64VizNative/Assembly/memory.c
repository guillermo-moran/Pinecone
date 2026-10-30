#include "gadget_internal.h"
/* Terminal memory exits shared by the VM adapter and adversarial harness. */
#include <string.h>

/* Keep the chain/helper entry layout unchanged; only standalone short entries
 * have a measured benefit from inlining this preparation. */
void ag_memory_prepare(AGMemory *view, AVZNativeMemoryFastPath *path) {
    ag_memory_prepare_inline(view, path);
}

static uint64_t read_register(const AVZNativeCPU *cpu, uint16_t offset) {
    uint64_t value = 0;
    if (offset != UINT16_MAX) memcpy(&value, (const unsigned char *)cpu + offset, sizeof(value));
    return value;
}
static void write_register(AVZNativeCPU *cpu, uint16_t offset, uint64_t value) {
    if (offset != UINT16_MAX) memcpy((unsigned char *)cpu + offset, &value, sizeof(value));
}
static uint64_t writeback_address(const AVZNativeCPU *cpu, const AGOperation *op) {
    return read_register(cpu, op->source) +
        (uint64_t)(int64_t)(int16_t)(op->auxiliary >> AG_MEM_OPERAND_SHIFT);
}
static void finish_memory(AVZNativeCPU *cpu, const AGOperation *op, uint64_t writeback) {
    if (!(op->auxiliary & AG_MEM_LOAD)) {
        cpu->exclusive_address = 0;
        cpu->exclusive_generation = 0;
        cpu->exclusive_size = 0;
        cpu->exclusive_valid = 0;
    }
    if (op->auxiliary & AG_MEM_WRITEBACK) write_register(cpu, op->source, writeback);
    cpu->pc = op->next_pc;
}

/* A page may become executable between the preflight and store. Finish its
 * accounting through C without repeating the already performed write. */
void ag_memory_commit(AGRun *run, const AGOperation *op, uint64_t physical_address) {
    uint64_t writeback = writeback_address(run->cpu, op);
    size_t span = (op->auxiliary & 0xff) * (op->auxiliary & AG_MEM_PAIR ? 2u : 1u);
    avz_native_fast_memory_commit_write_span(run->memory.path, physical_address, span);
    finish_memory(run->cpu, op, writeback);
}

static uint32_t pair_slow(AGRun *run, const AGOperation *op, uint64_t address,
    uint64_t writeback) {
    AVZNativeMemoryFastPath *path = run->memory.path;
    AVZNativeCPU *cpu = run->cpu;
    const uint8_t width = op->auxiliary & 0xff;
    const uint16_t second_register = (uint16_t)(op->auxiliary >> AG_MEM_SECOND_SHIFT);
    const int load = (op->auxiliary & AG_MEM_LOAD) != 0;
    const uint64_t mask = width == 4 ? UINT32_MAX : UINT64_MAX;
    uint64_t first = load ? 0 : read_register(cpu, op->destination) & mask;
    uint64_t second = load ? 0 : read_register(cpu, second_register) & mask;
    // Check separately before the paired RAM helper: retrying its failed
    // translation through callbacks could report the same guest fault twice.
    if (!avz_native_fast_memory_can_access(path, address, width, !load) ||
        !avz_native_fast_memory_can_access(path, address + width, width, !load))
        return AVZ_TP_STATUS_MEMORY_FAULT;
    int ok = load ? avz_native_fast_memory_read_pair(path, address, width, &first, &second) :
        avz_native_fast_memory_write_pair(path, address, width, first, second);
    if (!ok) {
        if (path->translation_fault_pending) return AVZ_TP_STATUS_MEMORY_FAULT;
        // A failing second store callback may leave the first write completed.
        ok = load ? (avz_native_fast_memory_read(path, address, width, &first) &&
                     avz_native_fast_memory_read(path, address + width, width, &second)) :
                    (avz_native_fast_memory_write(path, address, width, first) &&
                     avz_native_fast_memory_write(path, address + width, width, second));
        if (!ok) return AVZ_TP_STATUS_MEMORY_FAULT;
    }
    if (load) {
        if (op->auxiliary & AG_MEM_SIGN) {
            first = (uint64_t)(int64_t)(int32_t)first;
            second = (uint64_t)(int64_t)(int32_t)second;
        }
        write_register(cpu, op->destination, first);
        write_register(cpu, second_register, second);
    }
    finish_memory(cpu, op, writeback);
    return AVZ_TP_STATUS_REVALIDATE;
}

/* Terminal assembly-to-C access. Never continue dispatch after this function:
 * translation, MMIO and observation callbacks can invalidate any saved proof.
 * The caller pins the program, so callback retirement cannot free op. */
uint32_t ag_memory_slow(AGRun *run, const AGOperation *op) {
    AVZNativeCPU *cpu = run->cpu;
    uint64_t offset = op->immediate;
    if (op->auxiliary & AG_MEM_REGISTER) {
        offset = read_register(cpu, (uint16_t)(op->auxiliary >> AG_MEM_OPERAND_SHIFT));
        unsigned extend = (unsigned)(op->auxiliary >> AG_MEM_EXTEND_SHIFT) & 7;
        if (extend == 2) offset = (uint32_t)offset;
        else if (extend == 6) offset = (uint64_t)(int64_t)(int32_t)offset;
        offset <<= (op->auxiliary >> AG_MEM_SCALE_SHIFT) & 7;
    }
    const uint64_t address = read_register(cpu, op->source) + offset;
    const uint64_t writeback = writeback_address(cpu, op);
    if (op->auxiliary & AG_MEM_PAIR) return pair_slow(run, op, address, writeback);
    const uint8_t width = op->auxiliary & 0xff;
    const int load = (op->auxiliary & AG_MEM_LOAD) != 0;
    uint64_t value = load ? 0 : read_register(cpu, op->destination);
    if (!load && width < 8) value &= (UINT64_C(1) << (width * 8)) - 1;
    int ok = load ? avz_native_fast_memory_read(run->memory.path, address, width, &value) :
        avz_native_fast_memory_write(run->memory.path, address, width, value);
    if (!ok) return AVZ_TP_STATUS_MEMORY_FAULT;
    if (load) {
        if (op->auxiliary & AG_MEM_SIGN) {
            uint64_t sign = UINT64_C(1) << (width * 8 - 1);
            if (value & sign) value |= ~(sign | (sign - 1));
            if (op->auxiliary & AG_MEM_RESULT32) value &= UINT32_MAX;
        }
        write_register(cpu, op->destination, value);
    }
    finish_memory(cpu, op, writeback);
    return AVZ_TP_STATUS_REVALIDATE;
}
