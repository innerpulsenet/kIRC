// SPDX-License-Identifier: GPL-2.0-or-later
//
// ScanlineOverlay — the effects overlay painted OVER the whole window.
//
// One component carries BOTH families of effect the [effects] control owns:
//
//   * the CRT family — scanlines, vignette, grain, flicker, hum bar — which
//     shades the whole window (log, sidebar, header and composer alike);
//   * the glass family's chrome-facing layer — reflection — which is a
//     specular gloss along the window's own static chrome (the top band and
//     top edge).  The rest of the glass family (frost/sheen/edges) lives in
//     GlassSurface.qml per surface, where it always has.
//
// The host window stacks one instance of this above every layer it owns, so
// the filter is global rather than a property of the log.
//
// ---------------------------------------------------------------------------
// WHAT IT MUST NEVER DO (this codebase has paid for these twice)
// ---------------------------------------------------------------------------
//   * NO per-row Repeater.  A scanline is a *pattern*, not 350 Items: the
//     layers here are six static painters, not a model.
//   * NO ShaderEffectSource, no MultiEffect and no blur of the scrolling log:
//     this file has no `source`, no capture and no `shaderSource` at all.  A
//     captured scrolling ListView is the performance trap that was removed
//     from the glass sheet (see .hermes/implementation/p8-glass.md) and from
//     the delegate before it; the scanline/vignette/grain patterns are
//     *generated* here instead (Canvas 2D, painted once per size/amount
//     change), so there is nothing to re-rasterise per frame and nothing to
//     re-blur while scrolling.
//   * NO mirrored copy of the message log.  Reflection is a gloss over static
//     chrome, not a flipped image of the log: a true mirror would be exactly
//     the capture above (see .hermes/implementation/p10-effects.md).
//   * NO 60 Hz animation unless the user asked for one.  Scanlines, vignette,
//     grain and reflection are static: after their one paint they cost nothing
//     per frame and never invalidate the scene.  Flicker is stepped by a ~10 Hz
//     Timer (not a QPropertyAnimation) and the hum bar is a single slow
//     Rectangle animation; both are off by default.
//
// ---------------------------------------------------------------------------
// CHEAPNESS CONTRACT (the one the tests assert)
// ---------------------------------------------------------------------------
//   * With every effect OFF the host window never instantiates this file at
//     all (main.qml's Loader is inactive), so all-off contributes zero nodes
//     and the window is pixel-identical to the pre-effects build.
//   * Each effect is behind its own Loader here, so an effect that is OFF is
//     not merely invisible: it has no nodes and runs no timers/animations even
//     while a sibling effect is ON.
//   * Input: the root is `enabled: false` and nothing in this file installs a
//     MouseArea/TapHandler/HoverHandler, so clicks fall through to the header,
//     the log and the composer underneath.
//
// The property names below are the interface main.qml binds to; the state
// itself lives in KircConfig ([UI] Scanlines/… and Reflection keys) so it is
// persisted and global, exactly like the rest of the glass prefs.
import QtQuick

// ThemeEngine (singleton) supplies withAlpha() for the reflection gloss, the
// same helper the glass sheet uses.
import org.kde.kirc

// Bound component behaviour: the Loaders below instantiate the declared
// components, which reference `overlay.*` like any nested component.
pragma ComponentBehavior: Bound

Item {
    id: overlay

    objectName: "scanlineOverlay"

    // --- switches + intensities (mirrored from KircConfig by main.qml) -----
    property bool scanlinesOn: false
    property int scanlineAmount: 35
    property bool vignetteOn: false
    property int vignetteAmount: 30
    property bool grainOn: false
    property int grainAmount: 10
    property bool flickerOn: false
    property int flickerAmount: 4
    property bool humBarOn: false
    property int humBarAmount: 8
    // Glass family: the specular chrome gloss.
    property bool reflectionOn: false
    property int reflectionAmount: 25

    /// True when the window's own background reads dark.  Grain, the hum bar
    /// and the reflection gloss are *light* on a dark tube and *dark* on a
    /// light one (the `paper` theme), so they stay visible either way without a
    /// per-theme token.
    property bool backgroundIsDark: true

    /// Height of the window's chrome band (the header) — the only part of the
    /// window Reflection is allowed to gloss.  Supplied by the host window;
    /// 0 keeps the gloss off entirely.
    property real chromeTopHeight: 0

    /// Tint of the reflection gloss.  The host passes the theme accent so the
    /// gloss speaks the same language as the glass sheet's sheen.
    property color glossColor: "#ffffff"

    readonly property bool anyOn: overlay.scanlinesOn || overlay.vignetteOn
                                  || overlay.grainOn || overlay.flickerOn
                                  || overlay.humBarOn || overlay.reflectionOn

    // Paint-only: never takes input, never participates in layout.
    enabled: false
    // Defensive: the host already gates instantiation on `anyOn`.
    visible: overlay.anyOn

    // --- intensity -> alpha curves -----------------------------------------
    // Each is linear in the 1..100 pref so the settings slider reads as a
    // strength, and each is tuned so the DEFAULT is legible over text (see
    // .hermes/implementation/p10-effects.md for the screenshot review).
    readonly property real scanAlpha: 0.55 * (overlay.scanlineAmount / 100.0)
    readonly property real vignetteAlpha: 0.85 * (overlay.vignetteAmount / 100.0)
    readonly property real grainAlpha: 0.35 * (overlay.grainAmount / 100.0)
    readonly property real flickerPeak: 0.50 * (overlay.flickerAmount / 100.0)
    readonly property real humAlpha: 0.45 * (overlay.humBarAmount / 100.0)
    readonly property real reflectionEdgeAlpha: 0.10 + 0.45 * (overlay.reflectionAmount / 100.0)
    readonly property real reflectionGlossAlpha: 0.06 + 0.30 * (overlay.reflectionAmount / 100.0)

    /// Dark line period of the scanline pattern, in logical pixels: one dark
    /// line, two clear rows.  A 1px line every 2px halves the brightness and
    /// reads as dirt; 1-in-3 reads as a tube.
    readonly property int scanPeriod: 3

    /// Ink for the additive layers that must stay *visible* rather than
    /// darken (grain, hum bar).  Scanlines and the vignette are always black:
    /// they are shadow, and they read as a tube on a light or a dark field.
    readonly property color effectInk: overlay.backgroundIsDark ? "#ffffff" : "#000000"
    readonly property string effectInkCss: overlay.backgroundIsDark ? "#ffffff" : "#000000"

    // ---------------------------------------------------------------------- //
    // 1 + 2. scanlines and vignette — ONE static canvas
    //
    // Both are dark shading of the same surface, so they share a single
    // full-window Canvas (one texture, one paint) that is repainted only when
    // the size or an amount changes.  No animation ever invalidates it.
    // ---------------------------------------------------------------------- //
    Loader {
        id: screenLoader
        objectName: "scanlineScreenLoader"
        anchors.fill: parent
        active: overlay.scanlinesOn || overlay.vignetteOn

        sourceComponent: Component {
            Canvas {
                id: screenCanvas
                objectName: "scanlineScreen"
                anchors.fill: parent

                // Inputs (bindings from the root, so a live amount change
                // repaints exactly once).
                property real lineAlpha: overlay.scanlinesOn ? overlay.scanAlpha : 0
                property int linePeriod: overlay.scanPeriod
                property real cornerAlpha: overlay.vignetteOn ? overlay.vignetteAlpha : 0

                onLineAlphaChanged: screenCanvas.requestPaint()
                onLinePeriodChanged: screenCanvas.requestPaint()
                onCornerAlphaChanged: screenCanvas.requestPaint()
                onWidthChanged: screenCanvas.requestPaint()
                onHeightChanged: screenCanvas.requestPaint()

                onPaint: {
                    var ctx = screenCanvas.getContext("2d")
                    ctx.clearRect(0, 0, screenCanvas.width, screenCanvas.height)

                    // --- vignette: a radial corner falloff, painted first so
                    // the scanlines stay crisp on top of it.
                    if (screenCanvas.cornerAlpha > 0) {
                        var w = screenCanvas.width
                        var h = screenCanvas.height
                        var cx = w / 2
                        var cy = h / 2
                        // Fully clear out to 42% of the *smaller* axis, then
                        // ramp to the edge: a tube's corners are what fall off.
                        var inner = Math.min(w, h) * 0.42
                        var outer = Math.max(w, h) * 0.72
                        var grad = ctx.createRadialGradient(cx, cy, inner, cx, cy, outer)
                        grad.addColorStop(0.0, "rgba(0,0,0,0)")
                        grad.addColorStop(0.6, "rgba(0,0,0," + (screenCanvas.cornerAlpha * 0.35).toFixed(4) + ")")
                        grad.addColorStop(1.0, "rgba(0,0,0," + screenCanvas.cornerAlpha.toFixed(4) + ")")
                        ctx.fillStyle = grad
                        ctx.fillRect(0, 0, w, h)
                    }

                    // --- scanlines: one dark row every `linePeriod` rows.  A
                    // few hundred fillRects, once per paint — never per frame.
                    if (screenCanvas.lineAlpha > 0) {
                        ctx.fillStyle = "rgba(0,0,0," + screenCanvas.lineAlpha.toFixed(4) + ")"
                        var period = Math.max(2, screenCanvas.linePeriod)
                        for (var y = 0; y < screenCanvas.height; y += period) {
                            ctx.fillRect(0, y, screenCanvas.width, 1)
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------- //
    // 3. grain — a static deterministic noise wash
    //
    // Same approach as the glass sheet's grain (GlassSurface.qml): a Canvas
    // rasterised once, seeded by the canvas size so the pattern is stable (no
    // RNG, stable screenshots) and never repaints in steady state.
    // ---------------------------------------------------------------------- //
    Loader {
        id: grainLoader
        objectName: "scanlineGrainLoader"
        anchors.fill: parent
        active: overlay.grainOn

        sourceComponent: Component {
            Canvas {
                id: grainCanvas
                objectName: "scanlineGrain"
                anchors.fill: parent

                property real washAlpha: overlay.grainAlpha
                property string washColor: overlay.effectInkCss

                onWashAlphaChanged: grainCanvas.requestPaint()
                onWashColorChanged: grainCanvas.requestPaint()
                onWidthChanged: grainCanvas.requestPaint()
                onHeightChanged: grainCanvas.requestPaint()

                onPaint: {
                    var ctx = grainCanvas.getContext("2d")
                    var w = grainCanvas.width
                    var h = grainCanvas.height
                    ctx.clearRect(0, 0, w, h)
                    if (grainCanvas.washAlpha <= 0 || w <= 0 || h <= 0) {
                        return
                    }
                    ctx.fillStyle = grainCanvas.washColor
                    ctx.globalAlpha = grainCanvas.washAlpha
                    var count = Math.round((w * h) / 160)
                    // Deterministic LCG seeded by the size (stable screenshots,
                    // no Math.random).
                    var seed = 2654435761 + (Math.round(w) * 73856093 ^ Math.round(h) * 19349663)
                    for (var i = 0; i < count; ++i) {
                        seed = (seed * 1103515245 + 12345) % 2147483648
                        var gx = Math.floor((seed / 2147483648) * w)
                        seed = (seed * 1103515245 + 12345) % 2147483648
                        var gy = Math.floor((seed / 2147483648) * h)
                        ctx.fillRect(gx, gy, 1, 1)
                    }
                    ctx.globalAlpha = 1.0
                }
            }
        }
    }

    // ---------------------------------------------------------------------- //
    // 4. flicker — a very subtle, slow brightness oscillation
    //
    // A single full-window black film whose opacity follows a slow sine.  It
    // is stepped by a ~10 Hz Timer rather than a 60 Hz animation on purpose:
    // the whole window is repainted per step, so the effect asks for ten
    // repaints a second instead of sixty.  Off by default.
    // ---------------------------------------------------------------------- //
    Loader {
        id: flickerLoader
        objectName: "scanlineFlickerLoader"
        anchors.fill: parent
        active: overlay.flickerOn

        sourceComponent: Component {
            Rectangle {
                id: flickerFilm
                objectName: "scanlineFlicker"
                anchors.fill: parent
                color: "#000000"
                opacity: 0

                property real peak: overlay.flickerPeak
                // One full cycle every 120 steps (12 s): a slow, breathing dip
                // rather than a strobe.
                property int phase: 0

                onPeakChanged: flickerFilm.applyStep()

                function applyStep() {
                    flickerFilm.opacity = flickerFilm.peak
                        * (0.5 + 0.5 * Math.sin(flickerFilm.phase / 120.0 * 2 * Math.PI))
                }

                Timer {
                    interval: 100
                    repeat: true
                    running: true
                    onTriggered: {
                        flickerFilm.phase = (flickerFilm.phase + 1) % 120
                        flickerFilm.applyStep()
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------- //
    // 5. hum bar — one bright band drifting slowly down the tube
    //
    // The failing-CRT roll: a single gradient rectangle on a long animation.
    // Off by default; it is the only layer here that keeps the window
    // repainting while it is on.
    // ---------------------------------------------------------------------- //
    Loader {
        id: humLoader
        objectName: "scanlineHumLoader"
        anchors.fill: parent
        active: overlay.humBarOn

        sourceComponent: Component {
            Item {
                id: humField
                objectName: "scanlineHumBar"
                anchors.fill: parent
                clip: true

                Rectangle {
                    id: humBand
                    objectName: "scanlineHumBand"
                    width: humField.width
                    height: Math.max(24, Math.round(humField.height * 0.16))
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop {
                            position: 0.5
                            color: overlay.backgroundIsDark
                                   ? Qt.rgba(1, 1, 1, overlay.humAlpha)
                                   : Qt.rgba(0, 0, 0, overlay.humAlpha)
                        }
                        GradientStop { position: 1.0; color: "transparent" }
                    }

                    NumberAnimation on y {
                        from: -humBand.height
                        to: humField.height
                        duration: 9000
                        loops: Animation.Infinite
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------- //
    // 6. reflection — the glass family's specular gloss (STATIC CHROME ONLY)
    //
    // WHAT THIS IS, PLAINLY: an intensified specular sweep along the window's
    // top edge plus a soft diagonal gloss over the header band.  It is NOT a
    // mirror of the message log.  A mirrored copy of the log would have to be a
    // ShaderEffectSource over the scrolling ListView — the capture this
    // codebase has removed twice — so the reflection is deliberately confined
    // to the chrome, which is static: a static gradient rectangle costs nothing
    // per frame and can never pick up the scroll path.
    //
    // Off by default, and entirely static while on.
    // ---------------------------------------------------------------------- //
    Loader {
        id: reflectionLoader
        objectName: "effectsReflectionLoader"
        anchors.fill: parent
        active: overlay.reflectionOn

        sourceComponent: Component {
            Item {
                id: reflectField
                objectName: "effectsReflection"
                anchors.fill: parent

                // --- the gloss over the chrome band -----------------------
                // `chromeTopHeight` is the header's height, supplied by the
                // window: the gloss is clipped to that static band and never
                // reaches the log below it.
                Item {
                    id: chromeBand
                    objectName: "reflectionChromeBand"
                    width: reflectField.width
                    height: Math.max(0, Math.min(reflectField.height, overlay.chromeTopHeight))
                    clip: true

                    // A wide, shallow band rotated like the glass sheet's sheen,
                    // so the two read as the same material.
                    Rectangle {
                        id: glossBand
                        objectName: "reflectionGloss"
                        width: Math.max(chromeBand.width * 1.8, 48)
                        height: Math.max(chromeBand.height * 1.6, 12)
                        x: -chromeBand.width * 0.34
                        y: -chromeBand.height * 0.55
                        rotation: -14
                        transformOrigin: Item.Center
                        gradient: Gradient {
                            GradientStop { position: 0.00; color: "transparent" }
                            GradientStop {
                                position: 0.45
                                color: ThemeEngine.withAlpha(overlay.glossColor,
                                                             overlay.reflectionGlossAlpha)
                            }
                            GradientStop {
                                position: 0.52
                                color: ThemeEngine.withAlpha(overlay.glossColor,
                                                             overlay.reflectionGlossAlpha)
                            }
                            GradientStop { position: 1.00; color: "transparent" }
                        }
                    }
                }

                // --- the specular top edge --------------------------------
                // The light catching the top lip of the screen, and a short
                // falloff under it so the gloss reads as a surface rather than
                // a line.
                Rectangle {
                    objectName: "reflectionEdge"
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: ThemeEngine.withAlpha(overlay.glossColor,
                                                 overlay.reflectionEdgeAlpha)
                }

                Rectangle {
                    objectName: "reflectionFalloff"
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: Math.max(6, Math.round(reflectField.height * 0.035))
                    gradient: Gradient {
                        GradientStop {
                            position: 0.0
                            color: ThemeEngine.withAlpha(overlay.glossColor,
                                                         overlay.reflectionGlossAlpha * 0.8)
                        }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
            }
        }
    }
}
