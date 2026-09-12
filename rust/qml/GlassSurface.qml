// SPDX-License-Identifier: GPL-2.0-or-later
//
// GlassSurface — the one sheet of frosted glass every main display area lays
// over its terminal background.
//
// kIRC is a retro console first: this component is surfacing *over* the
// existing chrome, never a redesign. It paints, bottom to top:
//
//   1. frost — a MultiEffect blur of a static, hidden underlay (the shape
//              "behind" the glass). The blur source is a static item, so the
//              frost is computed from a stable texture and never re-blurs
//              because of scrolling or arriving messages.
//   2. tint  — a translucent wash of the area's own theme colour, so the
//              console's palette (bgPanel / bgLog / bgInput) still decides
//              what the area looks like.
//   3. sheen — a diagonal reflection sweep tinted with the theme accent.
//   4. grain — a faint deterministic noise wash (Canvas, painted once).
//   5. edges — a lit top edge, a dark bottom edge and inner shading, so the
//              sheet reads as a pane with depth.
//
// HARD CONSTRAINT: the blur source must be a STATIC item. Never point
// `blurSource` — or the sheet itself — at a scrolling view or a delegate: a
// blurred scrolling surface is the performance trap this codebase spent
// earlier passes removing (see .hermes/implementation/p8-glass.md).
//
// With `ThemeEngine.glassEffects` false the component renders NOTHING: the
// chrome underneath is untouched, pixel for pixel, which is what makes the
// "glass off == the old build" guarantee hold.
//
// Frosting is in-app only: it blurs the app's own static underlays. kIRC does
// not blur whatever sits behind the window (that would need compositor
// cooperation, which this phase deliberately does not add).
import QtQuick
import QtQuick.Effects

import org.kde.kirc

Item {
    id: glass

    // --- API (the frozen GlassSurface surface) -----------------------------
    /// Corner radius of the tint/edge layers. The console furniture is square
    /// (0); a non-zero radius rounds the sheet's fill and edges.
    property real radius: 0
    /// Translucent wash colour. Defaults to the theme-derived glass fill; an
    /// area whose colour comes from the desktop palette (breeze) passes
    /// ThemeEngine.glassFillFor(<its resolved colour>).
    property color tint: ThemeEngine.glassFill
    /// Reflection sweep (also gated by the user's GlassSheen preference).
    property bool sheen: true
    /// Lit edge + depth (also gated by the user's GlassEdges preference).
    property bool edges: true
    /// Frost/lightning (also gated by the user's GlassBlur preference).
    property bool blur: true
    /// Optional STATIC item to blur instead of the built-in underlay.
    property Item blurSource: null
    /// Multiplier on the grain wash; 0 disables it.
    property real grainOpacity: 1.0

    // --- state -------------------------------------------------------------
    objectName: "glassSurface"
    // The master switch: off renders nothing at all.
    visible: ThemeEngine.glassEffects
    // Paint-only sheet: never takes input, never takes part in layout.
    enabled: false
    // A sheet is a rectangle: the frost blur can spill a few pixels past its
    // geometry (MultiEffect padding), so clip everything to the sheet.
    clip: true

    readonly property bool frostOn: glass.blur && ThemeEngine.glassBlur
    readonly property bool sheenOn: glass.sheen && ThemeEngine.glassSheen
    readonly property bool edgeOn: glass.edges && ThemeEngine.glassEdges

    // --- 1. frost ----------------------------------------------------------
    Item {
        id: frostLayer
        objectName: "glassFrost"
        anchors.fill: parent
        visible: glass.frostOn

        // Static underlay — the texture the frost is made of. Hidden: it is
        // painted only through the blur below, so no crisp copy shows.
        //
        // NOTE: this is a Rectangle (a visual item), not a bare Item: a
        // gradient-bearing CHILD inside a hidden plain Item renders as a
        // white-blown texture through MultiEffect on this stack (verified
        // against llvmpipe/Qt 6.11 with pixel probes — see p8-glass.md). A
        // Rectangle's own `gradient` as the source's root background does not.
        Rectangle {
            id: underlay
            anchors.fill: parent
            visible: false
            clip: true
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: ThemeEngine.darkenRgb(ThemeEngine.glassBase, 0.32)
                }
                GradientStop {
                    position: 1.0
                    color: ThemeEngine.glassBase
                }
            }

            // Two soft accent pools + a cool streak: blurred, they read as
            // frosted light and shape behind the pane instead of flat paint.
            // Deliberately faint — at higher alphas the pools read as smudges
            // rather than as light (see p8-glass.md, tuned from screenshots).
            Rectangle {
                width: Math.max(20, Math.min(underlay.width, underlay.height) * 0.70)
                height: width
                radius: width / 2
                x: underlay.width * 0.16 - width * 0.5
                y: underlay.height * 0.08 - height * 0.5
                color: ThemeEngine.withAlpha(ThemeEngine.glassAccent, 0.08)
            }

            Rectangle {
                width: Math.max(16, Math.min(underlay.width, underlay.height) * 0.45)
                height: width
                radius: width / 2
                x: underlay.width * 0.84 - width * 0.5
                y: underlay.height * 0.92 - height * 0.5
                color: ThemeEngine.withAlpha(
                    ThemeEngine.lightenRgb(ThemeEngine.glassAccent, 0.35), 0.05)
            }

            Rectangle {
                width: Math.max(underlay.width, 40) * 1.6
                height: Math.max(underlay.height * 0.18, 8)
                x: -underlay.width * 0.3
                y: underlay.height * 0.34
                rotation: -12
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop {
                        position: 0.5
                        color: ThemeEngine.withAlpha(ThemeEngine.glassAccent, 0.06)
                    }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
        }

        MultiEffect {
            id: frostEffect
            source: glass.blurSource !== null ? glass.blurSource : underlay
            anchors.fill: parent
            opacity: ThemeEngine.glassFrostOpacity
            blurEnabled: true
            blur: ThemeEngine.glassBlurAmount
            blurMax: ThemeEngine.glassBlurMax
            // NOTE: do NOT set saturation/brightness/contrast here. The colour
            // adjust stage blows the transparent parts of the texture out to
            // opaque white on this stack (Qt 6.11 / llvmpipe): with it the
            // frost renders as a milky wash over everything. Verified by
            // pixel probe (see p8-glass.md). The frost stays a plain blur.
        }
    }

    // --- 2. tint -----------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        radius: glass.radius
        color: glass.tint
    }

    // --- 3. sheen ----------------------------------------------------------
    Item {
        id: sheenLayer
        objectName: "glassSheen"
        anchors.fill: parent
        visible: glass.sheenOn
        opacity: ThemeEngine.glassSheenOpacity
        clip: true

        Rectangle {
            id: sheenBand
            width: Math.max(glass.width * 1.8, 48)
            height: Math.max(glass.height * 0.6, 26)
            x: -glass.width * 0.42
            y: -glass.height * 0.46
            rotation: -14
            transformOrigin: Item.Center
            // A narrow bright core inside the band: the reflection reads as a
            // reflection only when it has an edge (a broad wash reads as fog).
            gradient: Gradient {
                GradientStop { position: 0.00; color: "transparent" }
                GradientStop { position: 0.43; color: ThemeEngine.glassSheenTint }
                GradientStop { position: 0.50; color: ThemeEngine.glassSheenTint }
                GradientStop { position: 0.57; color: "transparent" }
                GradientStop { position: 1.00; color: "transparent" }
            }
        }
    }

    // --- 4. grain ----------------------------------------------------------
    // Deterministic 1px noise, rasterised once per size change. Canvas (not a
    // texture asset) so the sheet stays a single self-contained QML file.
    // The wash strength lives in the item's opacity (colour alpha × the
    // caller's multiplier) — the dots themselves are drawn at full strength.
    Canvas {
        id: grainCanvas
        objectName: "glassGrain"
        anchors.fill: parent
        visible: glass.grainOpacity > 0
        opacity: glass.grainOpacity * ThemeEngine.glassGrain.a
        // Repaint when the wash colour or the size changes; nothing else can
        // invalidate it, so this never repaints in steady state.
        property string grainColor: ThemeEngine.cssColor(ThemeEngine.glassGrain)
        onGrainColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.fillStyle = grainColor
            var area = width * height
            var count = Math.round(area / 260)
            // Deterministic LCG seeded by the size, so the same sheet size
            // always yields the same pattern (stable screenshots, no RNG).
            var seed = 2654435761 + (Math.round(width) * 73856093 ^ Math.round(height) * 19349663)
            for (var i = 0; i < count; ++i) {
                seed = (seed * 1103515245 + 12345) % 2147483648
                var gx = Math.floor((seed / 2147483648) * width)
                seed = (seed * 1103515245 + 12345) % 2147483648
                var gy = Math.floor((seed / 2147483648) * height)
                ctx.fillRect(gx, gy, 1, 1)
            }
        }
    }

    // --- 5. edges + depth --------------------------------------------------
    Item {
        id: edgeLayer
        objectName: "glassEdges"
        anchors.fill: parent
        visible: glass.edgeOn

        // Lit top edge: the light catching the lip of the pane.
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: ThemeEngine.glassEdgeLight
        }

        // Inner glow just under the lip, so the edge reads as thickness.
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(2, Math.min(10, glass.height * 0.16))
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: ThemeEngine.withAlpha(ThemeEngine.glassEdgeLight, 0.35)
                }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }

        // A faint lit edge down the left side (screen-left light source).
        Rectangle {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: 1
            color: ThemeEngine.withAlpha(ThemeEngine.glassEdgeLight, 0.22)
        }

        // Inner bottom shade + dark bottom edge: the pane's depth.
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(3, Math.min(16, glass.height * 0.20))
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop {
                    position: 1.0
                    color: ThemeEngine.withAlpha(ThemeEngine.glassShadow, 0.85)
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: ThemeEngine.glassEdgeDark
        }
    }
}
