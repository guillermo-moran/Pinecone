# Startup Index Evaluation

The eager startup index remains enabled. The only lookup optimization is to
retain all 32 GNU hash bits in its private open-addressed table. GNU chain
terminator masking is still used by musl's actual GNU hash lookup; it is not
needed by this table, which has a separate valid flag. Both insertion and lookup
use the full hash. String equality, duplicate-name selection, binding/type/version
filters, `need_def`, scope gates, fallback lookup, and startup teardown are
unchanged. The reverted r7 eager-index removal is not repeated.

## Statistics

Build packages with `PINECONE_MUSL_STARTUP_STATS_BUILD=1` using
`scripts/build-pinecone-musl.sh`. Instrumented packages go to
`artifacts/alpine-packages/pinecone-musl-stats/aarch64`; normal packages go to
`artifacts/alpine-packages/pinecone-musl/aarch64`. Both use release r8 and must not
be confused. Package output in the builder is also separated by variant.

Only the instrumented build recognizes `PINECONE_MUSL_STARTUP_STATS=1` at runtime.
Unset, `0`, or any other value is silent. Secure execution ignores the setting.
Production builds compile out all counters, timing, environment parsing, and
reporting. No per-symbol output, allocations, locks, or atomics are added.
Counters run only during the existing single-threaded startup window. Enabled
reporting uses three raw monotonic-clock syscalls and one best-effort stderr write
before the cache is destroyed, without calling interposed application functions.

Each successful startup emits one `pinecone-musl-startup` key/value line:

- `build_ns`: candidate counting, index mmap, and index population; excludes the
  separate four-way cache allocation.
- `reloc_ns`: interval after index preparation through reporting, including final
  relocations, TLS setup, and allocator-symbol checks. It is not total startup or
  pure symbol lookup time; dependency loading, teardown, and constructors are excluded.
- `clock_ok`: zero means timing is unavailable and both durations are zero.
- `candidates`: sizing estimate, capped at the existing maximum slot count.
- `visited`, `selected`, `entries`: symbols visited, DSO lookup winners considered,
  and distinct names inserted. Selected symbols can still fail acceptability checks.
- `slots`, `index_bytes`, `cache_bytes`: table capacity and mapped memory.
- `build_calls`, `build_probes`, `build_max`: insertion/find calls, slots examined,
  and maximum slots examined by one call, including duplicate names.
- `index_lookups`, `index_hits`, `index_probes`, `index_max`: eligible lookups only;
  probes include the empty slot terminating a miss.
- `cache_lookups`, `cache_hits`, `cache_probes`: four-way lookup work after index
  misses, not cache-store work. Negative results can be cache hits.

Startup failure and `ldd --list` exit before the existing teardown point, so do
not expect reports from those paths. Write errors and short writes are not
retried; collect statistics with writable stderr. As with other diagnostics,
a blocking pipe or SIGPIPE can affect an explicitly instrumented run.

## Isolated Builds And Tests

Run on native Alpine/aarch64 with an existing compiler and cached source/patches.
No package-manager operations, installation, rootfs staging, or shared build-tree
writes are performed by this helper:

```sh
bash scripts/musl-loader-regression/build-isolated.sh \
  /var/cache/distfiles/musl-1.2.6.tar.gz /path/to/alpine-musl-patches /tmp/new-musl-build
PINECONE_MUSL_EXPECT_STATS=0 PINECONE_MUSL_STARTUP_STATS=1 \
  bash scripts/run-musl-loader-regressions.sh /tmp/new-musl-build/ld-musl-aarch64.so.1
```

Set `PINECONE_MUSL_STARTUP_STATS_BUILD=1` for a second isolated build. Run its
matrix with reporting off (`EXPECT_STATS=0`) and on (`EXPECT_STATS=1`), setting
`PINECONE_MUSL_STARTUP_STATS` accordingly. The expectation variable's full name is
`PINECONE_MUSL_EXPECT_STATS`. Stats validation requires Python 3.

The matrix covers GNU/SysV/both hash tables, PIE/non-PIE, and preload/no-preload.
It asserts actual aarch64 COPY relocations for non-PIE, repeated symbol and weak
miss relocations, hidden/default symbol versions, first weak versus later strong
binding, static and dynamic TLS across threads, repeated local `dlopen`/`dlclose`,
promotion to global scope, and resolution of a symbol that was absent at startup.
Musl does not actually unmap libraries on `dlclose`; this is not an unload test.

Compare two instrumented loaders without installing either:

```sh
python3 scripts/musl-loader-regression/measure.py /path/to/baseline /path/to/candidate
python3 scripts/musl-loader-regression/measure.py /path/to/baseline /path/to/candidate \
  --hash sysv --references 64 --repeat 32
```

Fixtures have 4,096 exports by default. Execution checks every referenced function
result. Measurements warm both loaders, alternate invocation order, take 31
samples, verify exact runtime opt-in, and report JSON with median/min/max timings
and probe counters. The baseline for this experiment has the same instrumentation
but retains `hash |= 1` in both private-index entry points.

## Measured Results

Native aarch64 `pinecone-builder`, GCC `-O2`, musl 1.2.6, 31 alternating samples:

| Workload / metric | Masked baseline | Full-hash candidate |
| --- | ---: | ---: |
| GNU dense, build mean probes | 1.7388 | 1.4660 |
| GNU dense, lookup mean probes | 1.7618 | 1.4337 |
| GNU dense, max build / lookup probes | 12 / 8 | 10 / 6 |
| GNU dense, median build ns | 458060 | 420530 |
| GNU dense, median relocation interval ns | 770146 | 553851 |
| SysV sparse, build mean probes | 1.7305 | 1.4603 |
| SysV sparse, lookup mean probes | 1.0084 | 1.0116 |
| SysV sparse, max build / lookup probes | 12 / 7 | 10 / 6 |

Dense uses 4,096 referenced exports repeated four times; sparse uses 64 exports
spread across the 4,096-name table, repeated 32 times. Dense index hits stayed
20,509/20,521; sparse hits stayed 2,141/2,153. Both variants used 16,384 slots,
786,432 index bytes, and 524,288 cache bytes. Dense build time ranges were
408429-942267 ns versus 360659-744124 ns; relocation ranges were 701305-1342360 ns
versus 516576-753644 ns. Sparse timings were highly variable under concurrent
builder load and are not a reliable speedup estimate.

The dense probe reduction supports the small full-hash change. It is not a
universal probe-count improvement: sparse lookup probes increased slightly.
Timing includes counter overhead and native VM scheduling; no Phosh, application,
guest-interpreter, device, or simulator speedup has been demonstrated.

## Integration Handoff

Final production and diagnostic libraries include the five Alpine patches from
the existing musl recipe, including CVE-2026-6042 and CVE-2026-40200. All applied
with zero fuzz. Both retain SONAME `libc.musl-aarch64.so.1`.

- Production: `/private/tmp/musl-item7-integration.ZQTyiy/ld-musl-aarch64.so.1`
- Diagnostic: `/private/tmp/musl-item7-integration.ZQTyiy/ld-musl-aarch64-stats.so.1`
- Linux build trees: `/tmp/musl-item7.NBdpio/production` and
  `/tmp/musl-item7.NBdpio/diagnostic` on `pinecone-builder`.
- Production SHA-256: `a736e343d7dc636c9db6fa3a6158529489bed5e14ecbe73904190ca20a89c29e`
- Diagnostic SHA-256: `3eaee052126390e097e9830fae4b92613316f346c128ae190882431ab5113cb7`

These initial standalone libraries are unstripped and not exact abuild-flag
reproductions. For rootfs integration use the signed production APK below, not
direct loader replacement. The diagnostic library is an alternative loader, not
an additional libc to load alongside it.

Final verification: 36 matrix cases passed (production, diagnostic off, diagnostic
on), including counter invariants and one report per successful process. Production
contains no `startup_stats` symbols and ignores the runtime opt-in. Shell syntax
and patch whitespace checks passed. Actual secure-execution, forced mmap/clock
failure, maximum-capacity saturation, shared rootfs staging, and simulator checks
remain untested. Existing dirty changes outside this ownership were untouched.

### Signed Production Package

After the Phoc build completed, `scripts/build-pinecone-musl.sh` successfully built
the stats-off aarch64 package at the pinned aports commit
`11bd4e3a5442ee6c0156c1a9fd290fb49b2f561a`:

- Revision: `musl-1.2.6-r8`
- APK: `artifacts/alpine-packages/pinecone-musl/aarch64/musl-1.2.6-r8.apk`
- Public key: `artifacts/alpine-packages/pinecone-musl/aarch64/gmoran-6a8b4bbe.rsa.pub`
- APK SHA-256: `ed9b4ebaa91b02b4b2303d124272c150a706b5bca11a3f7f53307847c926d89f`
- Build log: `/private/tmp/musl-item7-r8-package-build.log`

`apk verify` passed against the builder's trusted keyring. All five Alpine patch
inputs matched the pinned checkout byte-for-byte; abuild verified their checksums
and applied them, including CVE-2026-6042 and CVE-2026-40200. The startup patch
input matched the workspace patch byte-for-byte. The package has the expected
name/version/architecture and SONAME `libc.musl-aarch64.so.1`.

The loader extracted from this exact APK passed another 12 matrix cases with
`PINECONE_MUSL_STARTUP_STATS=1` and `PINECONE_MUSL_EXPECT_STATS=0`; neither diagnostic
string is present in the binary. This package supersedes the standalone production
library for integration. Parent owns staging-reference updates; no shared image
build, rootfs installation, or simulator operation was performed here.
