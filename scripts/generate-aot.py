#!/usr/bin/env python3
"""Compile captured ARM64 integer blocks to C functions for the signed app.

Input: JSONL {"words": ["91000400", ...]} records from PINECONE_AOT_CAPTURE,
or a JSON array of such records. No guest address or host pointer is persisted.
Unsupported blocks are rejected as a whole, never partially mistranslated.
"""
import argparse
import json
from collections import Counter
from pathlib import Path


def reg(n, bits=64, sp=False):
    value = ("c->sp" if sp else "UINT64_C(0)") if n == 31 else f"c->x[{n}]"
    return f"(uint{bits}_t)({value})"


def store(n, value, bits=64, sp=False):
    if n == 31 and not sp:
        return f"(void)({value}); /* discarded XZR/WZR result */"
    target = "c->sp" if n == 31 else f"c->x[{n}]"
    return f"{target} = (uint{bits}_t)({value});"


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def shifted(value, kind, amount, bits):
    if not amount:
        return value
    if kind == 0:
        return f"(uint{bits}_t)((uint64_t)({value}) << {amount})"
    if kind == 1:
        return f"(({value}) >> {amount})"
    if kind == 2:
        return f"(uint{bits}_t)((({value}) >> {amount}) | ((UINT64_C(0) - (({value}) >> {bits - 1})) << {bits - amount}))"
    return f"(uint{bits}_t)((({value}) >> {amount}) | ((uint64_t)({value}) << {bits - amount}))"


def condition(code):
    n, z, c, v = [f"((c->pstate >> {bit}) & 1u)" for bit in (31, 30, 29, 28)]
    expr = [z, c, n, v, f"({c} && !{z})", f"({n} == {v})", f"(!{z} && {n} == {v})", "1"][code >> 1]
    return f"!({expr})" if code & 1 and code != 15 else expr


def arithmetic(rd, lhs, rhs, bits, subtract, flags, sp=False):
    op = "-" if subtract else "+"
    if not flags:
        return store(rd, f"({lhs}) {op} ({rhs})", bits, sp)
    helper = f"ag_aot_{'subs' if subtract else 'adds'}{bits}"
    return (f"{{ uint64_t value = {helper}({lhs}, {rhs}, &c->pstate); "
            f"{store(rd, 'value', bits)} }}")


def logical(rd, lhs, rhs, bits, opcode, sp=False):
    op = ["&", "|", "^", "&"][opcode]
    value = f"({lhs}) {op} ({rhs})"
    if opcode != 3:
        return store(rd, value, bits, sp)
    return (f"{{ uint64_t value = ag_aot_ands{bits}({lhs}, {rhs}, &c->pstate); "
            f"{store(rd, 'value', bits)} }}")


def flag_helpers():
    """Use real host NZCV for AArch64 while retaining independently testable C.

    Both outputs are early-clobber: neither can overlap an input or the other
    output between the flag-setting instruction and MRS. The cc clobber tells
    the optimizer that host flags are changed; guest non-NZCV bits are retained.
    """
    out = []
    for bits in (32, 64):
        for operation, symbol in (("adds", "+"), ("subs", "-"), ("ands", "&")):
            operands = "%w0, %w2, %w3" if bits == 32 else "%0, %2, %3"
            out += [f"static inline uint64_t ag_aot_{operation}{bits}(uint64_t a, uint64_t b, uint64_t *pstate) {{",
                    "    uint64_t value, flags;",
                    "#if defined(__aarch64__) && !defined(AG_AOT_FORCE_PORTABLE_FLAGS)",
                    f'    __asm__ volatile("{operation} {operands}\\n\\tmrs %1, nzcv"',
                    '        : "=&r"(value), "=&r"(flags) : "r"(a), "r"(b) : "cc");',
                    "#else",
                    f"    a = (uint{bits}_t)a; b = (uint{bits}_t)b;",
                    f"    value = (uint{bits}_t)(a {symbol} b);",
                    f"    flags = ((value >> {bits - 1}) << 31) | ((uint64_t)(value == 0) << 30);"]
            if operation != "ands":
                carry = "(a >= b)" if operation == "subs" else "(value < a)" if bits == 64 else "((a + b) >> 32)"
                overflow = "((a ^ b) & (a ^ value))" if operation == "subs" else "(~(a ^ b) & (a ^ value))"
                out += [f"    flags |= ((uint64_t){carry} << 29) | ((({overflow} >> {bits - 1}) & 1u) << 28);"]
            out += ["#endif",
                    "    *pstate = (*pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));",
                    "    return value;", "}"]
    return out


def bitmasks(n, immr, imms, bits, immediate):
    length = ((n << 6) | ((~imms) & 63)).bit_length() - 1
    if length < 1 or (bits == 32 and n):
        raise ValueError("reserved bitmask encoding")
    size = 1 << length
    if size > bits:
        raise ValueError("invalid bitmask width")
    levels = size - 1
    s, r = imms & levels, immr & levels
    if immediate and s == levels:
        raise ValueError("reserved logical immediate")
    ones = (1 << (s + 1)) - 1
    rotated = ((ones >> r) | (ones << ((size - r) % size))) & ((1 << size) - 1)
    top = (1 << (((s - r) & levels) + 1)) - 1
    return tuple(sum(value << offset for offset in range(0, bits, size)) for value in (rotated, top))


def branch_destination(offset, index, count, test=None):
    if index != count - 1:
        raise ValueError("branch must terminate block")
    target = index * 4 + offset
    if 0 <= target < count * 4:
        raise ValueError("intra-block branch requires interpreter")
    destination = f"base + UINT64_C({target & ((1 << 64) - 1)})"
    return f"({test} ? {destination} : base + {count * 4}u)" if test is not None else destination


def translate(w, index, count):
    bits = 64 if w >> 31 else 32
    rd, rn, rm = w & 31, (w >> 5) & 31, (w >> 16) & 31
    if w == 0xd503201f:
        return "/* nop */", None
    if w & 0x1f800000 == 0x11000000:
        imm = ((w >> 10) & 4095) << (12 if w & (1 << 22) else 0)
        flags = bool(w & (1 << 29))
        return arithmetic(rd, reg(rn, bits, True), f"UINT64_C({imm})", bits, bool(w & (1 << 30)), flags, not flags), None
    if w & 0x1f200000 == 0x0b000000:
        kind, amount = (w >> 22) & 3, (w >> 10) & 63
        if kind == 3 or amount >= bits:
            raise ValueError("reserved shifted arithmetic")
        return arithmetic(rd, reg(rn, bits), shifted(reg(rm, bits), kind, amount, bits), bits, bool(w & (1 << 30)), bool(w & (1 << 29))), None
    if w & 0x1fe00000 == 0x0b200000:
        extension, amount = (w >> 13) & 7, (w >> 10) & 7
        if amount > 4:
            raise ValueError("reserved extended arithmetic")
        source_bits = 8 << (extension & 3)
        source = f"(uint64_t)({reg(rm)} & UINT64_C({(1 << source_bits) - 1}))"
        if extension & 4:
            source = f"(({source} ^ UINT64_C({1 << (source_bits - 1)})) - UINT64_C({1 << (source_bits - 1)}))"
        rhs = f"(uint{bits}_t)({source} << {amount})"
        flags = bool(w & (1 << 29))
        return arithmetic(rd, reg(rn, bits, True), rhs, bits, bool(w & (1 << 30)), flags, not flags), None
    if w & 0x1f000000 == 0x0a000000:
        kind, amount = (w >> 22) & 3, (w >> 10) & 63
        if amount >= bits:
            raise ValueError("reserved shifted logical")
        rhs = shifted(reg(rm, bits), kind, amount, bits)
        if w & (1 << 21):
            rhs = f"(uint{bits}_t)~({rhs})"
        return logical(rd, reg(rn, bits), rhs, bits, (w >> 29) & 3), None
    if w & 0x1f800000 == 0x12000000:
        immediate, _ = bitmasks((w >> 22) & 1, (w >> 16) & 63, (w >> 10) & 63, bits, True)
        opcode = (w >> 29) & 3
        return logical(rd, reg(rn, bits), f"UINT64_C({immediate})", bits, opcode, opcode != 3), None
    if w & 0x3fe00800 == 0x1a800000:
        fallback = reg(rm, bits)
        invert, increment = bool(w & (1 << 30)), bool(w & (1 << 10))
        if invert:
            fallback = f"(UINT64_C(0) - ({fallback}))" if increment else f"~({fallback})"
        elif increment:
            fallback = f"(({fallback}) + UINT64_C(1))"
        return store(rd, f"({condition((w >> 12) & 15)} ? {reg(rn, bits)} : {fallback})", bits), None
    if w & 0x9f000000 in (0x10000000, 0x90000000):
        page = bool(w & (1 << 31))
        offset = signed((((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3), 21) * (4096 if page else 1)
        pc = f"((base + {index * 4}u) & ~UINT64_C(4095))" if page else f"(base + {index * 4}u)"
        return store(rd, f"{pc} + UINT64_C({offset & ((1 << 64) - 1)})"), None
    if w & 0x7fa00000 == 0x13800000:
        amount = (w >> 10) & 63
        if ((w >> 22) & 1) != bits // 64 or amount >= bits:
            raise ValueError("reserved extract encoding")
        value = reg(rm, bits) if not amount else f"({reg(rm, bits)} >> {amount}) | ((uint64_t){reg(rn, bits)} << {bits - amount})"
        return store(rd, value, bits), None
    if w & 0x1f800000 == 0x13000000:
        opcode, r, s = (w >> 29) & 3, (w >> 16) & 63, (w >> 10) & 63
        if opcode == 3 or ((w >> 22) & 1) != bits // 64 or r >= bits or s >= bits:
            raise ValueError("reserved bitfield encoding")
        mask, top = bitmasks((w >> 22) & 1, r, s, bits, False)
        value = f"({shifted(reg(rn, bits), 3, r, bits)} & UINT64_C({mask & top}))"
        if opcode == 0:
            value = f"{value} | ((UINT64_C(0) - (({reg(rn, bits)} >> {s}) & 1u)) & UINT64_C({((1 << bits) - 1) ^ top}))"
        elif opcode == 1:
            insert_mask = mask & top
            value = f"({reg(rd, bits)} & UINT64_C({((1 << bits) - 1) ^ insert_mask})) | {value}"
        return store(rd, value, bits), None
    if w & 0x1f800000 == 0x12800000:
        opc, shift = (w >> 29) & 3, ((w >> 21) & 3) * 16
        if opc == 1 or shift >= bits:
            raise ValueError("reserved move-wide encoding")
        imm = ((w >> 5) & 65535) << shift
        value = f"UINT64_C({imm})"
        if opc == 0:
            value = f"~{value}"
        if opc == 3:
            mask = ((1 << bits) - 1) ^ (65535 << shift)
            value = f"({reg(rd, bits)} & UINT64_C({mask})) | {value}"
        return store(rd, value, bits), None
    if w & 0x7e000000 == 0x34000000 or w & 0xfc000000 == 0x14000000:
        conditional = w & 0x7e000000 == 0x34000000
        offset = signed((w >> 5) & 0x7ffff, 19) * 4 if conditional else signed(w & 0x3ffffff, 26) * 4
        test = None
        if conditional:
            test = f"{reg(rd, bits)} {'!=' if w & (1 << 24) else '=='} 0"
        return "", branch_destination(offset, index, count, test)
    if w & 0xff000010 == 0x54000000:
        return "", branch_destination(signed((w >> 5) & 0x7ffff, 19) * 4, index, count, condition(w & 15))
    if w & 0x7e000000 == 0x36000000:
        bit = ((w >> 31) << 5) | ((w >> 19) & 31)
        test = f"(({reg(rd)} >> {bit}) & 1u) {'!=' if w & (1 << 24) else '=='} 0"
        return "", branch_destination(signed((w >> 5) & 0x3fff, 14) * 4, index, count, test)
    raise ValueError(f"unsupported instruction {w:08x}")


def fingerprint(words):
    value = 14695981039346656037
    for word in words:
        value = ((value ^ word) * 1099511628211) & ((1 << 64) - 1)
    return value


def pure_span_instruction(word):
    """Independent opt-in gate for the weaker copied-span coherence window.

    Translation support alone never grants span eligibility. Adding memory,
    helper, system or potentially faulting translations must leave them out of
    this whitelist until their execution/observation contract is separately
    proven. Operand/encoding validity and bounded terminal branches are checked
    by translate() before this family-level gate is used.
    """
    families = (
        (0xffffffff, 0xd503201f),  # NOP only, not arbitrary HINT/system opcodes
        (0x1f800000, 0x11000000),  # ADD/SUB immediate
        (0x1f200000, 0x0b000000),  # ADD/SUB shifted register
        (0x1fe00000, 0x0b200000),  # ADD/SUB extended register
        (0x1f000000, 0x0a000000),  # logical shifted register
        (0x1f800000, 0x12000000),  # logical immediate
        (0x3fe00800, 0x1a800000),  # conditional select
        (0x9f000000, 0x10000000),  # ADR
        (0x9f000000, 0x90000000),  # ADRP
        (0x7fa00000, 0x13800000),  # EXTR
        (0x1f800000, 0x13000000),  # bitfield
        (0x1f800000, 0x12800000),  # MOVN/MOVZ/MOVK
        (0x7e000000, 0x34000000),  # CBZ/CBNZ
        (0xfc000000, 0x14000000),  # direct B, excludes BL
        (0xff000010, 0x54000000),  # B.cond
        (0x7e000000, 0x36000000),  # TBZ/TBNZ
    )
    return any(word & mask == value for mask, value in families)


def generate(records, max_blocks=256, seeds=(), manifest=None, min_instructions=1, prefixes=False):
    blocks, rejected = [], 0
    counts = Counter()
    empty_prefixes = set()
    for record in [*seeds, *records]:
        words = tuple(int(w, 16) if isinstance(w, str) else w for w in record["words"])
        if not words or len(words) > 16 or any(not 0 <= w <= 0xffffffff for w in words):
            raise ValueError("blocks must contain 1..16 uint32 instruction words")
        weight = record.get("weight", 1)
        if not isinstance(weight, int) or isinstance(weight, bool) or weight < 0:
            raise ValueError("sample weight must be a nonnegative integer")
        if prefixes:
            supported = 0
            for i, word in enumerate(words):
                try:
                    translate(word, i, len(words))
                except ValueError:
                    break
                supported += 1
            if not supported:
                empty_prefixes.add(words)
                continue
            words = words[:supported]
        # Explicit profiler weights are conservative sampled block visits.
        # Rank their translated instruction mass, not the original mixed
        # block's length; preparation-only captures retain visit-count ranking.
        counts[words] += weight * len(words) if "weight" in record else weight
    rejected += len(empty_prefixes)
    mandatory = {tuple(int(w, 16) if isinstance(w, str) else w for w in r["words"]) for r in seeds}
    for words in sorted(counts, key=lambda w: (w not in mandatory, -counts[w], w)):
        if len(words) < min_instructions and words not in mandatory:
            continue
        try:
            body = [translate(w, i, len(words)) for i, w in enumerate(words)]
        except ValueError:
            rejected += 1
            continue
        if len(blocks) < max_blocks:
            blocks.append((words, body))
    blocks.sort(key=lambda block: (fingerprint(block[0]), block[0]))
    if manifest is not None:
        manifest.extend({"words": [f"{w:08x}" for w in words]} for words, _ in blocks)
    out = ["/* Generated by scripts/generate-aot.py. Do not edit. */", *flag_helpers()]
    for n, (words, body) in enumerate(blocks):
        out += [f"static const uint32_t ag_aot_words_{n}[] = {{" + ", ".join(f"0x{w:08x}u" for w in words) + "};"]
        for span in (False, True):
            if span and not all(pure_span_instruction(word) for word in words):
                continue
            suffix = "_span" if span else ""
            out += [f"static void ag_aot_block_{n}{suffix}(AGRun *r, uint64_t base) {{",
                    "    AVZNativeCPU *c = r->cpu;",
                    "    uint64_t remaining = r->budget, retired = 0;",
                    "    if (!ag_aot_boundary_budget(r, remaining)) goto finish;"]
            for i, (statement, target) in enumerate(body):
                out += [f"    {statement}", f"    c->pc = {target or f'base + {(i + 1) * 4}u'};",
                        "    retired++; remaining--;",
                        "    if (!remaining) goto finish;" if span else
                        "    if (!ag_aot_boundary_budget(r, remaining)) goto finish;"]
            out += ["    r->result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;", "finish:"]
            if span:
                # Copied mapped spans already permit completing a pure block
                # between coherence checks. Never use this entry for helpers,
                # memory operations, resident assembly programs or native faults.
                out += ["    if (retired) (void)ag_aot_boundary_budget(r, remaining);"]
            out += ["    r->budget = remaining;",
                    "    r->result.steps += retired;",
                    "    r->result.generic_dispatches += retired;", "}"]
    out += ["static const AGAOTBlock ag_aot_blocks[] = {"]
    for n, (words, _) in enumerate(blocks):
        span_entry = f"ag_aot_block_{n}_span" if all(pure_span_instruction(word) for word in words) else "NULL"
        out += [f"    {{ag_aot_words_{n}, {len(words)}, ag_aot_block_{n}, UINT64_C({fingerprint(words)}), {span_entry}}},"]
    out += ["    {NULL, 0, NULL, 0, NULL}", "};", f"#define AG_AOT_BLOCK_COUNT {len(blocks)}u", ""]
    return "\n".join(out), len(blocks), rejected


def read_records(path):
    raw = path.read_text()
    if raw.lstrip().startswith("["):
        return json.loads(raw)
    records = []
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise ValueError(f"invalid capture record at line {number}: {error}") from error
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--max-blocks", type=int, default=256)
    parser.add_argument("--min-instructions", type=int, default=1)
    parser.add_argument("--prefixes", action="store_true", help="Compile maximal supported prefixes before unsupported instructions")
    parser.add_argument("--seed", type=Path, help="Always include these supported regression blocks first")
    parser.add_argument("--manifest", type=Path, help="Save the selected portable instruction corpus for reproducible builds")
    args = parser.parse_args()
    if args.max_blocks < 1 or not 1 <= args.min_instructions <= 16:
        parser.error("--max-blocks must be positive; --min-instructions must be 1..16")
    seeds = read_records(args.seed) if args.seed else []
    if len(seeds) > args.max_blocks:
        parser.error("--max-blocks must accommodate seeds")
    manifest = []
    text, compiled, rejected = generate(read_records(args.input), args.max_blocks, seeds, manifest, args.min_instructions, args.prefixes)
    args.output.write_text(text)
    if args.manifest:
        args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"AOT: {compiled} unique blocks compiled; {rejected} rejected (interpreter fallback)")


if __name__ == "__main__":
    main()
