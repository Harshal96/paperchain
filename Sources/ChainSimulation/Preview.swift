import ChainCore
import Foundation

private struct PreviewTile: Encodable {
    let id: String
    let frame: Box
}

private struct PreviewSample: Encodable {
    let layers: [PreviewTile]
    let focus: String?
}

private struct PreviewRecording: Encodable {
    let bounds: Box
    let titles: [String]
    let fps: Int
    let samples: [PreviewSample]
}

/// Writes an offline HTML player for a deterministic recording of the production
/// presentation engine. Tile order and frames come from the simulated WindowServer.
func writePreview(to url: URL) throws {
    let bounds = Box(x: -1_280, y: 0, width: 1_280, height: 760)
    let screen = ScreenInfo(id: "preview", name: "Active display", bounds: bounds)
    let titles = ["Field notes", "Contact sheet", "Project brief", "Draft layout", "Color study"]
    let fps = 60
    var workspace = Workspace()
    workspace.syncScreens([screen])
    for (index, title) in titles.enumerated() {
        let id = String(index)
        workspace.discover(WindowInfo(id: id, app: "Preview", title: title), on: screen.id)
        workspace.select(id)
    }
    let available = Set(workspace.windows.keys)
    var projection = Presentation()
    var desktop = VirtualDesktop()
    var samples: [PreviewSample] = []
    var frame = 0
    func sample() {
        let tiles = desktop.layers.map { PreviewTile(id: $0, frame: desktop.frames[$0]!) }
        samples.append(PreviewSample(layers: tiles, focus: desktop.focused))
    }
    func select(_ id: String) {
        workspace.select(id)
        let commands = projection.update(workspace, available: available, at: Double(frame) / Double(fps), activate: id)
        desktop.consume(commands, screens: workspace.screens)
    }
    select("0")
    sample()
    for destination in [1, 2, 3, 4, 3, 2, 1, 0] {
        select(String(destination))
        for _ in 0..<42 {
            frame += 1
            let commands = projection.tick(at: Double(frame) / Double(fps))
            desktop.consume(commands, screens: workspace.screens)
            sample()
        }
    }
    let recording = PreviewRecording(bounds: bounds, titles: titles, fps: fps, samples: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(recording)
    let json = String(decoding: data, as: UTF8.self)
    try previewHTML(recording: json).write(to: url, atomically: true, encoding: .utf8)
}

private func previewHTML(recording: String) -> String {
    #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>PaperChain strip replay</title>
    <style>
    :root{color-scheme:light;font:16px/1.45 Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#23332d;background:#f5f5ee}
    *{box-sizing:border-box}
    body{margin:0}main{max-width:1080px;margin:0 auto;padding:clamp(20px,5vw,65px) clamp(14px,4vw,48px)}
    h1{font:600 clamp(1.8rem,5vw,3.4rem)/1.1 Georgia,serif;letter-spacing:-.045em;margin:0}
    p{margin:.5rem 0 1.5rem;color:#4d5e55}figure{margin:0}
    .stage{position:relative;isolation:isolate;aspect-ratio:1280/760;overflow:hidden;border:1px solid #5f6f66;background:#dce5da}
    .tile{position:absolute;overflow:hidden;display:flex;flex-direction:column;justify-content:space-between;
      border:1px solid #354b3e;border-radius:5px;background:var(--paper);color:#1d2b23}
    .tile[hidden]{display:none}
    .bar{display:flex;justify-content:space-between;background:#ffffff70;border-bottom:1px solid #24372b42;padding:clamp(3px,1vw,9px) 3%;font-size:clamp(.6rem,1.5vw,.85rem);font-weight:650;white-space:nowrap}
    .art{height:30%;margin:0 9%;background:repeating-linear-gradient(90deg,var(--ink) 0 7%,transparent 7% 10%);opacity:.62}
    .title{margin:0 8% 8%;font:600 clamp(1rem,4.4vw,3.7rem)/.96 Georgia,serif;letter-spacing:-.04em;max-width:82%}
    .controls{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding-top:16px}
    button{background:#fff;border:1px solid #b3bfb5;color:inherit;font:inherit;font-size:.875rem;font-weight:600;
      min-height:40px;border-radius:5px;padding:0 12px;cursor:pointer}
    button:disabled{opacity:.45;cursor:default}button:focus-visible,input:focus-visible{outline:3px solid #345dbe;outline-offset:2px}
    #play{background:#213f34;color:white;border-color:#213f34;min-width:80px}
    input{flex:1 1 180px;min-width:0;accent-color:#225642}
    .status{display:flex;gap:14px;justify-content:space-between;color:#4d5e55;font-size:.85rem;
      font-variant-numeric:tabular-nums;margin-top:10px}
    @media(max-width:480px){.controls input{flex-basis:100%}.title{font-size:clamp(.85rem,5vw,1.5rem)}}
    </style>
    </head>
    <body><main>
    <h1>PaperChain strip replay</h1>
    <p>Follow five windows to the end of the strip and back. Each window labels its left and right edges.</p>
    <figure aria-label="Recorded window positions and stacking order">
      <div class="stage" id="screen"></div>
    </figure>
    <div class="controls">
      <button id="play" type="button">Play</button>
      <button id="previous" type="button" aria-label="Previous frame">←</button>
      <button id="next" type="button" aria-label="Next frame">→</button>
      <input id="scrub" aria-label="Replay frame" type="range" min="0" step="1" value="0">
    </div>
    <div class="status"><span id="focus"></span><span id="position"></span></div>
    <noscript>Enable JavaScript to play the recorded frames.</noscript>
    </main>
    <script id="recording" type="application/json">\#(recording)</script>
    <script>
    "use strict";
    const recording = JSON.parse(document.getElementById("recording").textContent);
    const screenElement = document.getElementById("screen");
    const play = document.getElementById("play"), previous = document.getElementById("previous");
    const next = document.getElementById("next"), scrub = document.getElementById("scrub");
    const focusLabel = document.getElementById("focus"), positionLabel = document.getElementById("position");
    const colors = [["#efd59e","#a46d23"],["#c7d8f5","#4268a3"],["#e5cde5","#8b598a"],
                    ["#c8dfc3","#47764d"],["#f1cbb5","#a4623d"]];
    const windows = recording.titles.map((title,i) => {
      const tile = document.createElement("div");
      tile.className = "tile";
      tile.style.setProperty("--paper",colors[i][0]);
      tile.style.setProperty("--ink",colors[i][1]);
      const bar = document.createElement("div"), art = document.createElement("div"), name = document.createElement("div");
      bar.className = "bar";
      for (const side of ["Left","Right"]) {
        const marker = document.createElement("span");
        marker.textContent = String.fromCharCode(65+i) + " · " + side;
        bar.append(marker);
      }
      art.className = "art"; art.setAttribute("aria-hidden","true");
      name.className = "title"; name.textContent = title;
      tile.append(bar,art,name); screenElement.append(tile);
      return tile;
    });
    const last = recording.samples.length - 1, bounds = recording.bounds;
    scrub.max = String(last);
    let index = 0, animation = null;
    function render(frame) {
      index = frame;
      const sample = recording.samples[index];
      for (const tile of windows) tile.hidden = true;
      sample.layers.forEach((layer,z) => {
        const tile = windows[Number(layer.id)], box = layer.frame;
        tile.hidden = false; tile.style.zIndex = String(z+1);
        tile.style.left = (box.x-bounds.x)*100/bounds.width + "%";
        tile.style.top = (box.y-bounds.y)*100/bounds.height + "%";
        tile.style.width = box.width*100/bounds.width + "%";
        tile.style.height = box.height*100/bounds.height + "%";
      });
      scrub.value = String(index);
      previous.disabled = index === 0; next.disabled = index === last;
      focusLabel.textContent = "Focused window · " + recording.titles[Number(sample.focus)];
      positionLabel.textContent = "Frame " + (index+1) + " / " + (last+1) + " · " + (index/recording.fps).toFixed(2) + " s";
    }
    function pause() {
      if (animation !== null) cancelAnimationFrame(animation);
      animation = null; play.textContent = "Play";
    }
    play.addEventListener("click",() => {
      if (animation !== null) { pause(); return; }
      if (index === last) render(0);
      const start = performance.now(), first = index;
      function advance(now) {
        const frame = Math.min(last,first + Math.floor((now-start)*recording.fps/1000));
        if (frame > index) render(frame);
        if (frame === last) pause(); else animation = requestAnimationFrame(advance);
      }
      play.textContent = "Pause"; animation = requestAnimationFrame(advance);
    });
    previous.addEventListener("click",() => { pause(); render(Math.max(0,index-1)); });
    next.addEventListener("click",() => { pause(); render(Math.min(last,index+1)); });
    scrub.addEventListener("input",() => { pause(); render(Number(scrub.value)); });
    document.addEventListener("visibilitychange",() => { if (document.hidden) pause(); });
    render(0);
    </script></body></html>
    """#
}
