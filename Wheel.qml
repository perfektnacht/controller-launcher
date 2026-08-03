import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons
import qs.Ui

// Radial launcher wheel drawn as a donut of arc wedges. The stick's direction
// picks a wedge and there is no confirm step -- releasing the summon button
// fires whatever is lit.
//
// Angles are kept in "compass" degrees (0 = straight up, growing clockwise)
// because that is how the gesture reads to the hand. Qt's arc angles start at
// three o'clock, hence the -90 when handing them to PathAngleArc.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // The shell injects the matching service singleton here when this plugin
  // pairs an overlay with a service entry point. Declared writable for that
  // reason; serviceFor() is only a fallback for a summon that beats injection.
  property var service: null

  readonly property string pluginId: "perfektnacht.controller-launcher"
  property bool opened: false

  // Aim vector in screen space (y grows downward), -1..1 per axis.
  property real aimX: 0
  property real aimY: 0
  property bool aborting: false

  // Below this the stick is treated as centered, so a resting thumb never
  // launches anything on release.
  readonly property real selectionThreshold: 0.42

  property var launchers: []

  // ------------------------------------------------------------ appearance

  readonly property color surface: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color outline: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property string fontFamily: Style.font.menuFamily

  // The theme's menu scrim is tuned for a small card on a busy desktop. This
  // covers the whole screen and is meant to read as a mode you entered, so it
  // keeps the theme's hue but enforces a floor on the dim.
  readonly property color scrimFill: Qt.rgba(root.scrim.r, root.scrim.g, root.scrim.b,
                                             Math.max(root.scrim.a, 0.72))

  // Everything is a proportion of the shorter screen edge rather than a fixed
  // size. Gaming mode should own the display, and a 13" laptop gets the same
  // wheel as a 27" monitor instead of a postage stamp in the middle.
  readonly property real viewport: Math.max(320, Math.min(panel.width, panel.height))

  readonly property int outerRadius: Math.round(viewport * 0.44)
  readonly property int innerRadius: Math.round(outerRadius * 0.54)
  readonly property int hubRadius: Math.round(outerRadius * 0.43)
  readonly property int extrude: Math.round(outerRadius * 0.055)
  readonly property int faceSize: Math.round(outerRadius * 0.40)
  readonly property real wedgeGap: 2.6   // degrees of breathing room per side

  // Type and iconography scale with the ring so proportions hold at any size,
  // but never drop below the theme's own minimums.
  readonly property int titleSize: Math.max(Style.font.heading, Math.round(viewport * 0.030))
  readonly property int subSize: Math.max(Style.font.bodySmall, Math.round(viewport * 0.0135))
  readonly property int labelSize: Math.max(Style.font.bodySmall, Math.round(viewport * 0.0135))
  readonly property int faceIconSize: Math.round(faceSize * 0.44)
  readonly property int hubIconSize: Math.round(hubRadius * 0.52)
  readonly property int glyphSize: Math.round(faceSize * 0.40)

  readonly property string pluginDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""

  // Bundled logos, named by entry id. These matter most for applications that
  // are NOT installed: with nothing on disk there is no icon-theme entry to
  // find, so without these every uninstalled wedge would fall back to a font
  // glyph, and several of those are missing from JetBrainsMono Nerd Font.
  // `media` defaults to the entry id; set it to "" for entries that are meant
  // to be a glyph, so we do not probe for a file that was never shipped.
  function mediaIconFor(entry) {
    if (!entry || root.pluginDir === "") return ""
    var name = entry.media === undefined ? String(entry.id || "") : String(entry.media)
    if (!name) return ""
    return Util.fileUrl(root.pluginDir + "/media/" + name + ".png")
  }

  readonly property int count: launchers.length
  readonly property real step: count > 0 ? 360 / count : 360

  // --------------------------------------------------------------- aiming

  readonly property real aimMagnitude: Math.sqrt(aimX * aimX + aimY * aimY)
  readonly property bool aiming: aimMagnitude >= selectionThreshold

  // 0 = up, growing clockwise, matching the wedge layout below.
  readonly property real aimCompass: {
    var degrees = Math.atan2(aimX, -aimY) * 180 / Math.PI
    return degrees < 0 ? degrees + 360 : degrees
  }

  readonly property int selectedIndex: {
    if (count === 0 || !aiming) return -1
    return Math.round(aimCompass / step) % count
  }

  readonly property var selectedEntry: (selectedIndex >= 0 && selectedIndex < count)
    ? launchers[selectedIndex] : null

  // An entry that cannot be chosen does not get to wear its brand color; a
  // full-strength accent reads as actionable.
  readonly property color disabledAccent: Qt.rgba(foreground.r, foreground.g, foreground.b, 1)

  function accentFor(entry) {
    if (!entry) return Color.accent
    if (!root.isInstalled(entry)) return root.disabledAccent
    var value = String(entry.accent || "")
    return value ? value : Color.accent
  }

  // Themes may ship a translucent menu background, which is fine behind a
  // solid card but lets desktop content read straight through a wedge. Wedges
  // and hub composite their own near-opaque fill instead.
  function opaque(base, alpha) {
    return Qt.rgba(base.r, base.g, base.b, alpha)
  }

  function tinted(base, accent, amount) {
    return Qt.rgba(base.r + (accent.r - base.r) * amount,
                   base.g + (accent.g - base.g) * amount,
                   base.b + (accent.b - base.b) * amount,
                   0.96)
  }

  readonly property color activeAccent: root.accentFor(root.selectedEntry)

  // Drives the staggered unfurl. Each wedge derives its own slice of this one
  // animated value rather than owning a timer.
  property real bloom: 0

  NumberAnimation {
    id: bloomAnimation
    target: root
    property: "bloom"
    from: 0
    to: 1
    duration: 360
    easing.type: Easing.OutCubic
  }

  onOpenedChanged: {
    bloomAnimation.stop()
    root.bloom = 0
    if (root.opened) bloomAnimation.start()
  }

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.aimX = 0
    root.aimY = 0
    root.aborting = false
    root.refreshLaunchers(payloadJson)

    // Every way of summoning the wheel lands here -- the daemon's button, an
    // IPC toggle, a keybind -- but only the daemon's used to ask the service
    // to rescan. Asking from open() means all of them pick up an app
    // installed since the last run. The result arrives after we are already
    // on screen; the service hands it to us then.
    var live = root.liveService()
    if (live && typeof live.refreshLaunchers === "function") live.refreshLaunchers()

    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.aborting = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    else root.close()
  }

  function liveService() {
    if (root.service) return root.service
    if (!root.shell || typeof root.shell.serviceFor !== "function") return null
    return root.shell.serviceFor(root.pluginId)
  }

  // The service keeps the discovered list; the summon payload is only a
  // fallback for callers that hand us one directly (an IPC summon, say).
  //
  // Also called by the service while the wheel is open, when discovery comes
  // back with a list that differs from the one we opened with.
  function refreshLaunchers(payloadJson) {
    var live = root.liveService()
    if (live && Array.isArray(live.launchers) && live.launchers.length > 0) {
      root.launchers = live.launchers
      return
    }
    try {
      var payload = JSON.parse(String(payloadJson || "{}"))
      if (Array.isArray(payload.launchers)) root.launchers = payload.launchers
    } catch (error) {
      // A malformed payload is not worth refusing to open over.
    }
  }

  // ---------------------------------------------------------- daemon hooks

  function setAim(x, y) {
    root.aimX = Number(x) || 0
    root.aimY = Number(y) || 0
  }

  function setAborting(value) {
    root.aborting = value === true
  }

  function commit() {
    if (root.aborting) return
    root.launch(root.selectedEntry)
  }

  function isInstalled(entry) {
    return !entry || entry.installed !== false
  }

  function launch(entry) {
    if (!entry) return
    // Entries that are not installed are inert. They keep their slot so the
    // ring never reorders under your thumb, but selecting one does nothing --
    // this wheel launches games, it does not install software.
    if (!root.isInstalled(entry)) return
    var action = String(entry.action || "")
    if (!action) return  // the Desktop cell: dismissing is the whole action
    Quickshell.execDetached(["bash", "-lc", action])
  }

  // ------------------------------------------------------------------- ui

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-controller-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrimFill
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
          event.accepted = true
        }
      }

      Item {
        id: dial
        anchors.centerIn: parent
        width: (root.outerRadius + root.extrude) * 2
        height: width

        readonly property real cx: width / 2
        readonly property real cy: height / 2

        opacity: root.aborting ? 0.4 : 1
        Behavior on opacity { NumberAnimation { duration: 140 } }

        scale: 0.9 + 0.1 * root.bloom
        Behavior on scale { NumberAnimation { duration: 90 } }

        // ------------------------------------------------------- the wedges

        Repeater {
          model: root.launchers

          delegate: Shape {
            id: wedge

            required property int index
            required property var modelData

            anchors.fill: parent
            antialiasing: true
            asynchronous: false

            // The default renderer triangulates the path, which leaves the
            // outer arc visibly stair-stepped at this radius -- `antialiasing`
            // alone does not smooth it. CurveRenderer keeps the curves as
            // curves and antialiases them analytically on the GPU.
            preferredRendererType: Shape.CurveRenderer

            readonly property bool selected: root.selectedIndex === wedge.index
            readonly property bool installed: root.isInstalled(wedge.modelData)
            readonly property color accent: root.accentFor(wedge.modelData)

            // Each wedge gets its own slice of the bloom, so the ring unfurls
            // clockwise instead of every sector fading up at once.
            readonly property real reveal: Math.max(0, Math.min(1,
              root.bloom * (root.count + 1) - wedge.index))

            readonly property real startAngle: wedge.index * root.step - root.step / 2 + root.wedgeGap - 90
            readonly property real sweepAngle: root.step - root.wedgeGap * 2
            // Not readonly: a Behavior needs a writable property to intercept,
            // and the binding still drives it.
            property real ro: (root.outerRadius + (wedge.selected ? root.extrude : 0)) * wedge.reveal
            property real ri: root.innerRadius * wedge.reveal

            Behavior on ro { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

            opacity: wedge.reveal

            ShapePath {
              // A dashed outline and a thinner fill mark "not installed here
              // yet" without pushing the entry out of its slot.
              // A selected-but-inert wedge still has to show it is selected,
              // but must not out-shout the entries that can actually be run.
              fillColor: wedge.selected
                ? root.tinted(root.surface, wedge.accent, wedge.installed ? 0.30 : 0.07)
                : root.opaque(root.surface, wedge.installed ? 0.97 : 0.82)
              strokeColor: wedge.selected ? wedge.accent : root.outline
              strokeWidth: wedge.selected ? 2 : 1
              strokeStyle: wedge.installed ? ShapePath.SolidLine : ShapePath.DashLine
              dashPattern: [4, 4]
              capStyle: ShapePath.FlatCap
              joinStyle: ShapePath.MiterJoin

              // Annular sector: out along the start edge, around the outer arc,
              // back in along the end edge, then home along the inner arc.
              startX: dial.cx + wedge.ri * Math.cos(wedge.startAngle * Math.PI / 180)
              startY: dial.cy + wedge.ri * Math.sin(wedge.startAngle * Math.PI / 180)

              PathLine {
                x: dial.cx + wedge.ro * Math.cos(wedge.startAngle * Math.PI / 180)
                y: dial.cy + wedge.ro * Math.sin(wedge.startAngle * Math.PI / 180)
              }
              PathAngleArc {
                centerX: dial.cx
                centerY: dial.cy
                radiusX: wedge.ro
                radiusY: wedge.ro
                startAngle: wedge.startAngle
                sweepAngle: wedge.sweepAngle
                moveToStart: false
              }
              PathLine {
                x: dial.cx + wedge.ri * Math.cos((wedge.startAngle + wedge.sweepAngle) * Math.PI / 180)
                y: dial.cy + wedge.ri * Math.sin((wedge.startAngle + wedge.sweepAngle) * Math.PI / 180)
              }
              PathAngleArc {
                centerX: dial.cx
                centerY: dial.cy
                radiusX: wedge.ri
                radiusY: wedge.ri
                startAngle: wedge.startAngle + wedge.sweepAngle
                sweepAngle: -wedge.sweepAngle
                moveToStart: false
              }
            }
          }
        }

        // ------------------------------------------------- wedge face content

        Repeater {
          model: root.launchers

          delegate: Item {
            id: face

            required property int index
            required property var modelData

            readonly property bool selected: root.selectedIndex === face.index
            readonly property bool installed: root.isInstalled(face.modelData)
            readonly property real compass: face.index * root.step
            readonly property real reveal: Math.max(0, Math.min(1,
              root.bloom * (root.count + 1) - face.index))
            readonly property real orbit: (root.innerRadius + root.outerRadius) / 2
              + (face.selected ? root.extrude * 0.5 : 0)

            // Three tiers, walked down as each one fails to load: the system
            // icon theme first so installed apps match the rest of the
            // desktop, then the logo bundled with the plugin, then the glyph.
            readonly property string themeIcon: modelData.icon
              ? Quickshell.iconPath(String(modelData.icon), true) : ""
            readonly property string mediaIcon: root.mediaIconFor(modelData)
            property int iconTier: face.themeIcon !== "" ? 0 : 1
            readonly property string iconSource: face.iconTier === 0 ? face.themeIcon
                                               : face.iconTier === 1 ? face.mediaIcon : ""

            width: root.faceSize
            height: root.faceSize
            x: dial.cx + face.orbit * Math.sin(face.compass * Math.PI / 180) - width / 2
            y: dial.cy - face.orbit * Math.cos(face.compass * Math.PI / 180) - height / 2

            opacity: face.reveal * ((face.installed || face.selected) ? 1 : 0.45)
            scale: (0.85 + 0.15 * face.reveal) * (face.selected ? 1.1 : 1)

            Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.xs
              width: parent.width

              Image {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: face.iconSource !== ""
                source: face.iconSource
                sourceSize.width: root.faceIconSize
                sourceSize.height: root.faceIconSize
                width: root.faceIconSize
                height: root.faceIconSize
                fillMode: Image.PreserveAspectFit
                smooth: true
                // Drop to the next tier rather than leaving a hole.
                onStatusChanged: if (status === Image.Error && face.iconTier < 2) face.iconTier++

                // A full-colour Minecraft block still reads as clickable even
                // at low opacity, so unavailable entries lose their colour too.
                layer.enabled: !face.installed
                layer.effect: MultiEffect { saturation: -1.0 }
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: face.iconSource === ""
                font.family: root.fontFamily
                font.pixelSize: root.glyphSize
                color: face.selected ? root.accentFor(face.modelData) : root.foreground
                text: String(face.modelData.glyph || "")
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: root.labelSize
                font.bold: face.selected
                color: face.selected ? root.accentFor(face.modelData) : root.foreground
                opacity: face.selected ? 1 : 0.75
                text: String(face.modelData.label || "")
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !face.installed
                font.family: root.fontFamily
                font.pixelSize: Math.round(root.labelSize * 0.85)
                color: root.foreground
                opacity: 0.55
                text: "not installed"
              }
            }

            // Pointer parity, so the wheel is usable and testable with no
            // controller attached at all.
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.launch(face.modelData)
                root.dismiss()
              }
            }
          }
        }

        // ---------------------------------------------------------- the hub

        Rectangle {
          id: hub
          anchors.centerIn: parent
          width: root.hubRadius * 2
          height: width
          radius: width / 2
          color: root.opaque(root.surface, 0.97)
          border.width: 2
          border.color: root.aiming ? root.activeAccent : root.outline
          opacity: root.bloom

          Behavior on border.color { ColorAnimation { duration: 150 } }

          Column {
            id: hubContent
            anchors.centerIn: parent
            spacing: Style.spacing.sm
            width: hub.width * 0.74

            // Mirrors the wedge faces' tier walk so the hub never shows a
            // hole for an application that is not installed.
            readonly property string themeIcon: (root.selectedEntry && root.selectedEntry.icon)
              ? Quickshell.iconPath(String(root.selectedEntry.icon), true) : ""
            readonly property string mediaIcon: root.mediaIconFor(root.selectedEntry)
            property int iconTier: hubContent.themeIcon !== "" ? 0 : 1
            readonly property string iconSource: hubContent.iconTier === 0 ? hubContent.themeIcon
                                               : hubContent.iconTier === 1 ? hubContent.mediaIcon : ""

            onThemeIconChanged: hubContent.iconTier = hubContent.themeIcon !== "" ? 0 : 1

            Image {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: hubContent.iconSource !== ""
              source: hubContent.iconSource
              sourceSize.width: root.hubIconSize
              sourceSize.height: root.hubIconSize
              width: root.hubIconSize
              height: root.hubIconSize
              fillMode: Image.PreserveAspectFit
              smooth: true
              onStatusChanged: if (status === Image.Error && hubContent.iconTier < 2) hubContent.iconTier++

              // Match the wedge faces, or the hub would show a full-colour
              // logo for something that cannot be launched.
              layer.enabled: !root.isInstalled(root.selectedEntry)
              layer.effect: MultiEffect { saturation: -1.0 }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: root.titleSize
              font.bold: true
              color: root.aiming ? root.activeAccent : root.foreground
              text: root.aborting ? "Cancelled"
                   : root.selectedEntry ? String(root.selectedEntry.label || "")
                   : "Pick one"
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: root.subSize
              color: root.foreground
              opacity: 0.6
              visible: text !== ""
              text: root.aborting ? ""
                   : !root.selectedEntry ? "Release to dismiss"
                   : !root.isInstalled(root.selectedEntry) ? "Not installed"
                   : String(root.selectedEntry.sublabel || "")
            }
          }
        }
      }

      // A single glow pass over the whole dial, tinted by the current
      // selection. Cheaper than a per-wedge effect and it lets the highlight
      // bleed across the hub and needle as one piece of light.
      MultiEffect {
        anchors.fill: dial
        source: dial
        visible: root.aiming && !root.aborting
        blurEnabled: true
        blur: 1.0
        blurMax: 72
        brightness: 0.25
        colorization: 1.0
        colorizationColor: root.activeAccent
        // Kept low: this is a halo escaping from behind the dial, not a wash
        // over it. Higher and it muddies whatever is on screen behind.
        opacity: 0.30 * root.bloom
        z: -1
      }
    }
  }
}
