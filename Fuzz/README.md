# Fuzzing

Coverage-guided fuzzing of Circles' parsers and handlers with libFuzzer
(docs/DESIGN.md §12). The targets live in `Sources/CirclesFuzz`; the
regular test suite also runs them under seeded mutation on every platform.

Linux only (libFuzzer ships with the Linux Swift toolchain):

    ./run.sh cbor 300        # fuzz one target for 300 seconds
    ./run.sh all 120         # every target, 120 seconds each

Targets: `cbor`, `types`, `verify`, `noise`, `texts`, `dht`, `push`, `sync`, `mls`.
Corpora are kept in `Fuzz/corpus/<target>` (seeded from valid encodings);
crashes are written to `Fuzz/crashes/`. To reproduce one:

    CIRCLES_FUZZ_TARGET=<target> .build/release/circles-fuzz Fuzz/crashes/<file>
