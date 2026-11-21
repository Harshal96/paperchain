import ChainCore
import Dispatch
import Foundation

/// Runs the production presentation code on a deterministic virtual 120 Hz clock.
/// Wall-clock samples cover only tick(), including its generated command array.
func runBenchmark() {
    #if DEBUG
    let configuration = "debug"
    #else
    let configuration = "release"
    #endif
    print("Headless projection benchmark (\(configuration), virtual 120 Hz)")
    for count in [50, 500] {
        benchmark(stripLength: count)
    }
}

private func benchmark(stripLength: Int) {
    let screen = ScreenInfo(id: "bench", name: "Virtual landscape",
                            bounds: Box(x: -1_920, y: 24, width: 1_920, height: 1_056))
    var workspace = Workspace()
    workspace.syncScreens([screen])
    for index in 0..<stripLength {
        let id = "window-\(index)"
        workspace.discover(WindowInfo(id: id, app: "Editor", title: id), on: screen.id)
    }
    let ids = workspace.screens[screen.id]!.activeGroup!.orderedIDs
    precondition(ids.count == stripLength)
    let available = Set(ids)
    let route = [1, 2, stripLength / 2, stripLength - 1, stripLength - 2, 0]
    let warmupRounds = 3
    let measuredRounds = 30
    var frameNumber = 0
    var projection = Presentation()
    workspace.select(ids[0])
    _ = projection.update(workspace, available: available, at: 0)

    var nanoseconds: [UInt64] = []
    var frameWrites = 0
    var totalCommands = 0
    var maxWrites = 0
    var idleTicks = 0
    var idleCommands = 0
    for round in 0..<(warmupRounds + measuredRounds) {
        let measuring = round >= warmupRounds
        for column in route {
            workspace.select(ids[column])
            var time = Double(frameNumber) / 120
            _ = projection.update(workspace, available: available, at: time, activate: ids[column])
            precondition(projection.isMoving(at: time), "Benchmark navigation must start an animation")
            let startFrame = frameNumber
            while projection.isMoving(at: time) {
                frameNumber += 1
                time = Double(frameNumber) / 120
                let start = DispatchTime.now().uptimeNanoseconds
                let commands = projection.tick(at: time)
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                if measuring {
                    nanoseconds.append(elapsed)
                    var writes = 0
                    for case .place in commands { writes += 1 }
                    frameWrites += writes
                    maxWrites = max(writes, maxWrites)
                    totalCommands += commands.count
                }
                precondition(frameNumber - startFrame <= 240, "Animation failed to settle in two virtual seconds")
            }
            for _ in 0..<12 {
                frameNumber += 1
                let commands = projection.tick(at: Double(frameNumber) / 120)
                if measuring {
                    idleTicks += 1
                    idleCommands += commands.count
                }
            }
        }
    }

    precondition(!nanoseconds.isEmpty && frameWrites > 0 && idleCommands == 0)
    // Three exposed columns move and at most two previously exposed edges
    // return to their background positions, irrespective of jump distance.
    precondition(maxWrites <= 5)
    nanoseconds.sort()
    // Nearest-rank percentiles, in microseconds. No thresholds depend on host timing.
    func microseconds(atPercentile percentile: Int) -> String {
        let rank = (nanoseconds.count * percentile + 99) / 100
        return String(format: "%.2f", Double(nanoseconds[rank - 1]) / 1_000)
    }
    print("\(ids.count) windows, \(warmupRounds * route.count) warm-up moves, "
          + "\(measuredRounds * route.count) measured moves, \(nanoseconds.count) animation ticks")
    print("  Projection µs   p50 \(microseconds(atPercentile: 50))   p95 \(microseconds(atPercentile: 95))"
          + "   max \(microseconds(atPercentile: 100))")
    print("  Animation commands \(totalCommands), frame writes \(frameWrites), peak writes/tick \(maxWrites)")
    print("  Idle ticks \(idleTicks), idle commands \(idleCommands)")
}
