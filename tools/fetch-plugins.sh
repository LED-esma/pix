#!/bin/bash
# Downloads the canvas plugins' libraries (pinned versions) into Plugins/, which is
# bundled into Pix.app so the canvas works offline. Run once; reruns skip existing files.
set -euo pipefail
cd "$(dirname "$0")/../Plugins"
CDN=https://cdn.jsdelivr.net/npm

get() {  # get <package@version> <path in package> <destination>
  [[ -s "$3" ]] && return
  mkdir -p "$(dirname "$3")"
  curl -fsSL "$CDN/$1$2" -o "$3"
}

get katex@0.19.0 /dist/katex.min.js math/katex.min.js
get katex@0.19.0 /dist/katex.min.css math/katex.min.css
for f in AMS-Regular Caligraphic-Bold Caligraphic-Regular Fraktur-Bold Fraktur-Regular Main-Bold Main-BoldItalic \
         Main-Italic Main-Regular Math-BoldItalic Math-Italic SansSerif-Bold SansSerif-Italic SansSerif-Regular \
         Script-Regular Size1-Regular Size2-Regular Size3-Regular Size4-Regular Typewriter-Regular; do
  get katex@0.19.0 /dist/fonts/KaTeX_$f.woff2 math/fonts/KaTeX_$f.woff2
done
get animejs@4.5.0 /dist/bundles/anime.umd.min.js core/anime.umd.min.js
get mermaid@12.1.0 /dist/mermaid.min.js flow/mermaid.min.js
get matter-js@0.20.0 /build/matter.min.js physics/matter.min.js
get three@0.186.1 /build/three.module.js 3d/three.module.js
get three@0.186.1 /build/three.core.js 3d/three.core.js
get three@0.186.1 /examples/jsm/controls/OrbitControls.js 3d/OrbitControls.js
get chart.js@4.5.1 /dist/chart.umd.min.js charts/chart.umd.min.js
get cannon-es@0.20.0 /dist/cannon-es.js sim3d/cannon-es.js
for f in pyodide.js pyodide.asm.mjs pyodide.asm.wasm python_stdlib.zip pyodide-lock.json; do
  get pyodide@314.0.7 /$f python/$f
done
du -sh . | awk '{print "Plugins: " $1}'
