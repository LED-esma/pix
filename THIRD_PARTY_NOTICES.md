# Third-party notices

Pix's own code is under the [MIT License](LICENSE). The app bundles these libraries for the board (graphs, math, simulations). They are downloaded at build time by `tools/fetch-plugins.sh` at the pinned versions below and ship inside the app unchanged.

| Library | Version | License | Copyright |
|---|---|---|---|
| [KaTeX](https://github.com/KaTeX/KaTeX) (including its fonts) | 0.19.0 | MIT | Khan Academy and other contributors |
| [anime.js](https://github.com/juliangarnier/anime) | 4.5.0 | MIT | Julian Garnier |
| [Mermaid](https://github.com/mermaid-js/mermaid) | 12.1.0 | MIT | Knut Sveidqvist and contributors |
| [Matter.js](https://github.com/liabru/matter-js) | 0.20.0 | MIT | Liam Brummitt |
| [three.js](https://github.com/mrdoob/three.js) (core, module, OrbitControls) | 0.186.1 | MIT | three.js authors |
| [Chart.js](https://github.com/chartjs/Chart.js) | 4.5.1 | MIT | Chart.js contributors |
| [cannon-es](https://github.com/pmndrs/cannon-es) | 0.20.0 | MIT | Stefan Hedman and contributors |
| [Pyodide](https://github.com/pyodide/pyodide) | 314.0.7 | MPL-2.0 (the bundled Python standard library is under the PSF License) | Pyodide contributors |

Pyodide is used unmodified; its source is available at the link above, as the Mozilla Public License 2.0 requires.

Pix also works with, but does not include, [Claude Code](https://code.claude.com) (Anthropic's terms), [Ollama](https://ollama.com) (MIT) and the AI models and services you choose; each has its own terms.
