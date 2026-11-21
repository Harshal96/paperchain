# Checks and simulator

From the repository root, run all checks with Swift 5.9 or later on Linux or macOS. The runner builds Swift executables, including the simulator. The checks use synthetic windows, a temporary recovery journal and a fake HTTP transport, so they run offline and leave desktop windows alone.

```sh
sh scripts/check
```

| Suite | What it checks |
| --- | --- |
| [WorkspaceChecks](WorkspaceChecks/) | Group membership, window order, display transfers, click selection and side-window dimming. |
| [LayoutChecks](LayoutChecks/) | Strip geometry, padding, stacks, scrolling, native resize staging and placement along shared display edges. |
| [JournalChecks](JournalChecks/) | Parking journal persistence, recovery after a restart and refusal to restore an ambiguous window. |
| [DecisionsChecks](DecisionsChecks/) | Provider requests and responses, Ollama model selection, settings and regrouping after the workspace changes. |
| [NativeMetadataChecks](NativeMetadataChecks/) | Batched Accessibility reads, partial results and fallback reads. The runner includes this suite on macOS. |

To run one suite, pass its name to the SwiftPM wrapper, for example `sh scripts/swiftpm run LayoutChecks`.

## Simulator

[chain-sim](../Sources/ChainSimulation/) exercises the production presentation code with landscape and portrait displays on a virtual 120 Hz clock. To inspect window positions and stacking frame by frame, generate the replay and open the resulting HTML file in a browser.

```sh
sh scripts/swiftpm run chain-sim --preview strip-preview.html
```

To measure a release build, run the benchmark.

```sh
sh scripts/swiftpm run -c release chain-sim --benchmark
```

The benchmark counts minimize and restore requests while revisiting three windows, then times animation ticks with 50 and 500 windows and checks the command count at rest. Measuring desktop frame delivery or live memory use requires running the macOS app.

## Isolated Linux run

With the `swift:6.1` Docker image available locally, run the suite with a read-only checkout and a temporary build directory.

```sh
docker run --rm --network none -v "$PWD:/src:ro" -w /src swift:6.1 \
  sh scripts/check --scratch-path /tmp/paperchain-build
```
