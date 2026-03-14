// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/ex_autoresearch"
import topbar from "../vendor/topbar"
import * as echarts from "../vendor/echarts.min"

// ECharts hook for LiveView
const Chart = {
  mounted() {
    this.chart = echarts.init(this.el, 'dark')
    this.handleEvent(`chart-data-${this.el.id}`, (data) => {
      this.chart.setOption(data, { notMerge: true })
    })
    this.chart.on('click', (params) => {
      if (params.data && params.data.version_id) {
        this.pushEvent("select_version", { version: params.data.version_id })
      }
    })
    new ResizeObserver(() => this.chart.resize()).observe(this.el)
  },
  destroyed() {
    if (this.chart) this.chart.dispose()
  }
}

// Mermaid hook — loads mermaid from CDN on first use, renders diagrams
const Mermaid = {
  mounted() {
    this.renderDiagram()
    this.el.addEventListener('mermaid:export-svg', () => {
      const svg = this.el.querySelector('svg')
      if (!svg) return
      const svgData = new XMLSerializer().serializeToString(svg)
      const blob = new Blob([svgData], { type: 'image/svg+xml' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = 'model-architecture.svg'
      a.click()
      URL.revokeObjectURL(url)
    })
  },
  updated() {
    this.renderDiagram()
  },
  async renderDiagram() {
    const diagram = this.el.dataset.diagram
    if (!diagram) return

    // Lazy-load mermaid from CDN
    if (!window.mermaid) {
      const script = document.createElement('script')
      script.src = 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js'
      script.onload = () => {
        window.mermaid.initialize({
          startOnLoad: false,
          theme: 'dark',
          themeVariables: {
            primaryColor: '#818cf8',
            primaryTextColor: '#e4e4e7',
            primaryBorderColor: '#3f3f46',
            lineColor: '#71717a',
            secondaryColor: '#27272a',
            tertiaryColor: '#18181b',
            fontSize: '12px'
          }
        })
        this.doRender(diagram)
      }
      document.head.appendChild(script)
    } else {
      this.doRender(diagram)
    }
  },
  async doRender(diagram) {
    try {
      const id = 'mermaid-render-' + Math.random().toString(36).slice(2)
      const { svg } = await window.mermaid.render(id, diagram)
      // Wrap SVG in a zoomable container
      const wrapper = document.createElement('div')
      wrapper.style.cssText = 'transform-origin: top center; transition: transform 0.1s ease-out; cursor: grab;'
      wrapper.innerHTML = svg
      this.el.innerHTML = ''
      this.el.appendChild(wrapper)
      this.el.style.overflow = 'auto'

      let scale = 1
      this.el.addEventListener('wheel', (e) => {
        if (!e.ctrlKey && !e.metaKey) return
        e.preventDefault()
        scale = Math.min(5, Math.max(0.3, scale - e.deltaY * 0.002))
        wrapper.style.transform = `scale(${scale})`
      }, { passive: false })
    } catch(e) {
      this.el.innerHTML = '<div class="text-red-400 text-xs p-2">Diagram render failed: ' + e.message + '</div>'
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone},
  hooks: {...colocatedHooks, Chart, Mermaid},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

