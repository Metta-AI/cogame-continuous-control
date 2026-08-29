## The sprite-protocol compositor: the board, as bytes the inherited
## `client/broadcast_core.js` composites.
##
## Forked from the starter's `src/ctf/global.nim` with its three named edits:
##
## 1. THE BOARD IS A SIDE-ELEVATION CAMERA VIEWPORT, NOT A TOP-DOWN PIXEL
##    ARENA. The bed is baked ONCE at `MapWidth x MapHeight` covering 9.00 m of
##    track, seamlessly tileable on a 1.50 m period, and the renderer draws it
##    offset by `camX mod 1.50 m` — so the bake never changes, only its draw
##    offset, and there is no per-frame map cost. The raycast fov cache and the
##    shadowcasting are DELETED OUTRIGHT: this game is perfect information and
##    there is no fog layer at all.
## 2. LINK, FOOT AND FOOTPRINT POOLS. `LinkBase` (sized to 8 — the largest
##    morphology plus one), `FootBase` (4), `FootprintBase` (64, a ring buffer
##    of ground marks) and `DustBase`, filled in LINK INDEX ORDER and emitted
##    incrementally like the starter's other object families.
## 3. BAKED TRACK BED. `data/arena_floor.png` is tiled and darkened at install
##    with pixie, exactly the way the starter bakes endzone paint, and the dirt
##    grain, the metre ticks and the 5-metre numerals are baked onto it once —
##    one bake per episode, so the per-frame cost is the machine's 7 links, 4
##    feet, the dust and the overlays.
##
## THE SPRITE PROTOCOL HAS NO ROTATION, so a rotating capsule link cannot be one
## baked chip. Each link is COMPOSITED from a run of baked round chips of the
## link's own radius laid along its own segment — which is literally what a
## capsule is — plus a joint hub at each anchor. That is the same technique the
## starter uses for its rig legs and it costs one sprite per link rather than
## one per link per angle bucket.
##
## Floats are legal here: nothing in this module enters `gameHash`.

import std/[json, math, os, strutils]
import pixie
import bitworld/spriteprotocol
import sim_types, trig, body, solver, sim, report, labels

const
  MapLayerId = 0
  MapLayerType = 0
  ZoomableLayerFlag = 1

  GroundRow* = 840             ## board row of world y = 0
  CamLeadPx* = 480             ## the torso rides a third of the way across
  BedTilePx* = 240             ## 1.50 m at 6 250 um/px

  BedSpriteId = 10
  HorizonSpriteId = 11
  GateSpriteId = 12
  StartLineSpriteId = 13
  TickSpriteId = 14
  NumeralSpriteBase = 20       ## + metre div 5, 0 .. 12
  LinkSpriteBase = 40          ## + morph * 8 + link
  LinkGlowSpriteBase = 70      ## + morph * 8 + link
  HubSpriteId = 100
  HubHotSpriteId = 101
  FootSpriteBase = 110         ## + planted
  FootprintSpriteId = 120
  DustSpriteBase = 130         ## + stage 0..2
  FallRingSpriteId = 140
  MachineSpriteBase = 150     ## + ord(morph): the nano-banana identity chip

  BedObjectBase = 40           ## 40 .. 99 with z = -32768 is broadcast_core's
  StaticBandZ = -32768         ## static-band cache window; the bed never moves
  HorizonObjectBase = 60
  TickObjectBase = 200
  NumeralObjectBase = 300
  GateObjectId = 340
  StartLineObjectId = 341
  FootprintObjectBase = 400    ## 64-entry ring
  LinkObjectBase = 600         ## link chips, LINK INDEX order
  HubObjectBase = 800
  FootObjectBase = 830
  DustObjectBase = 840
  FallRingObjectId = 860
  MachineObjectId = 861

  LinkChips = 7                ## chips composited along one link
  FootprintRing = 64

## --- Board render scale (spectator/replay supersampling), KEPT FROM CTF -----
## `boardRenderScaleFor`, `RenderScale`, `MaxSupersampledMapPixels`,
## `predictedViewerRenderBytes` and `WasmViewerBudgetBytes` are the starter's
## own (`src/ctf/global.nim:1095-1151`) and are kept UNCHANGED. 1 440 x 960 =
## 1 382 400 logical map pixels sits far under `MaxSupersampledMapPixels`, so
## `boardRenderScaleFor` still returns `RenderScale = 2` and
## `predictedViewerRenderBytes(1440, 960)` is 121 651 200 B ~ 122 MB against
## the 1.6 GB budget — the viewer's load-time capacity preflight passes with
## 13x headroom.
const RenderScale* {.intdefine.} = 2
const MaxSupersampledMapPixels* {.intdefine.} = 8_000_000
const WasmViewerBudgetBytes* = 1_600_000_000

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  if mapWidth * mapHeight > MaxSupersampledMapPixels: 1
  else: RenderScale

proc predictedViewerRenderBytes*(mapWidth, mapHeight: int): int64 =
  ## Engineering estimate of the replay viewer's peak working set for one
  ## board, at the scale `boardRenderScaleFor` picks for it.
  let
    px = int64(mapWidth) * int64(mapHeight)
    k = int64(boardRenderScaleFor(mapWidth, mapHeight))
  px * 4 * (4 * k * k + 6)

type
  GlobalViewerState* = object
    ## What one viewer has been told. `nextState` is threaded through every
    ## packet build so a redefinition is emitted only when something changed.
    spritesSent*: bool
    bedSent*: bool
    initialised*: bool
    leadSent*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    liveObjects*: seq[int]

proc initGlobalViewerState*(): GlobalViewerState =
  GlobalViewerState(replaySeekTick: -1)

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies the viewer's client messages. Whole-string commands (`s:<tick>`)
  ## are intercepted before the legacy char-by-char transport path, so a
  ## multi-digit tick is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    else:
      discard

# ---------------------------------------------------------------------------
#  Art
# ---------------------------------------------------------------------------

var
  artLoaded = false
  floorTile: Image
  wallH: Image
  wallV: Image
  plating: Image
  horizon: Image
  boardFont: Typeface
  machineChips: array[3, Image]
  bedPlate: Image
  horizonPlate: Image
  gatePlate: Image

proc dataPath(name: string): string =
  ## The wasm bundle preloads `data@data` and `client/art@client/art`, and the
  ## native image copies both into its workdir, so one relative path serves
  ## both.
  if fileExists(name): name else: "/" & name

proc loadArt() =
  if artLoaded:
    return
  artLoaded = true
  floorTile = readImage(dataPath("data/arena_floor.png"))
  wallH = readImage(dataPath("client/art/walls/wall_h.jpg"))
  wallV = readImage(dataPath("client/art/walls/wall_v.jpg"))
  plating = readImage(dataPath("data/soldier_red.png"))
  horizon = readImage(dataPath("client/art/lockerroom/bg.jpg"))
  boardFont = readTypeface(dataPath("data/font.ttf"))
  ## The three machines' visual identities: nano-banana renders of the Softmax
  ## cog, one kit per morphology, so a spectator can tell the machines apart at
  ## board scale without reading a label. Generated by
  ## `scripts/art/gen_machine_sheet.py`, keyed and split by
  ## `scripts/art/split_machine_sheet.py`; both the source sheet and the split
  ## script are committed and CI never regenerates art.
  for i, name in ["hopper", "cheetah", "walker"]:
    machineChips[i] = readImage(dataPath("data/art/machine_" & name & ".png"))

proc straightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc shade(image: Image, x, y: int, r, g, b, a: int) =
  if x < 0 or y < 0 or x >= image.width or y >= image.height:
    return
  let existing = image[x, y].rgba()
  let alpha = clamp(a, 0, 255)
  proc mix(src, dst: int): uint8 =
    uint8(clamp((src * alpha + dst * (255 - alpha)) div 255, 0, 255))
  image[x, y] = rgba(mix(r, int(existing.r)), mix(g, int(existing.g)),
                     mix(b, int(existing.b)),
                     max(existing.a, uint8(alpha)))

proc disc(image: Image, cx, cy, radius: float, r, g, b, a: int) =
  let
    x0 = max(0, int(cx - radius - 1.0))
    x1 = min(image.width - 1, int(cx + radius + 1.0))
    y0 = max(0, int(cy - radius - 1.0))
    y1 = min(image.height - 1, int(cy + radius + 1.0))
  for y in y0 .. y1:
    for x in x0 .. x1:
      let
        dx = float(x) + 0.5 - cx
        dy = float(y) + 0.5 - cy
        d = sqrt(dx * dx + dy * dy)
      if d <= radius - 0.5:
        image.shade(x, y, r, g, b, a)
      elif d < radius + 0.5:
        image.shade(x, y, r, g, b, int(float(a) * (radius + 0.5 - d)))

proc textPlate(text: string, w, h: int, size: float,
               ink: ColorRGBA, bg: ColorRGBA): Image =
  loadArt()
  result = newImage(w, h)
  result.fill(rgba(bg.r, bg.g, bg.b, bg.a))
  var font = newFont(boardFont)
  font.size = size
  font.paint = rgbx(ink.r, ink.g, ink.b, 255)
  let arrangement = typeset(@[newSpan(text, font)],
    bounds = vec2(float32(w) - 4.0, float32(h) - 2.0))
  result.fillText(arrangement, translate(vec2(2.0, 1.0)))

proc bakeBed(): Image =
  ## The dirt bed: `data/arena_floor.png` tiled on a 1.50 m period and darkened
  ## 25 %, with baked grain and a bright ground line. The bake is ONE tile
  ## period wider than the frame so the draw offset can scroll it seamlessly.
  loadArt()
  let w = MapWidth + BedTilePx
  result = newImage(w, MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< w:
      if y < GroundRow:
        ## sky: a warm dark gradient, so the horizon band reads against it
        let t = float(y) / float(GroundRow)
        result[x, y] = rgba(
          uint8(22 + int(26.0 * t)), uint8(17 + int(20.0 * t)),
          uint8(13 + int(16.0 * t)), 255)
      else:
        let c = floorTile[x mod floorTile.width,
                          (y - GroundRow) mod floorTile.height].rgba()
        result[x, y] = rgba(
          uint8(int(c.r) * 75 div 100), uint8(int(c.g) * 72 div 100),
          uint8(int(c.b) * 68 div 100), 255)
  ## Dirt grain: a deterministic speckle so the ground is not a flat wash.
  var seed = 0x2545F491'u32
  for _ in 0 ..< 26_000:
    seed = seed * 1664525'u32 + 1013904223'u32
    let x = int(seed shr 8) mod w
    seed = seed * 1664525'u32 + 1013904223'u32
    let y = GroundRow + int(seed shr 8) mod (MapHeight - GroundRow)
    result.shade(x, y, 246, 232, 208, 26)
  ## The ground line itself.
  for x in 0 ..< w:
    result.shade(x, GroundRow, 242, 232, 216, 150)
    result.shade(x, GroundRow + 1, 26, 20, 15, 120)

proc bakeHorizon(): Image =
  ## The parallax band: `client/art/lockerroom/bg.jpg` darkened and blurred,
  ## with blocks cut from the wall textures scrolling at 0.35x the camera.
  loadArt()
  let
    w = MapWidth + BedTilePx
    h = 220
  result = newImage(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let c = horizon[x mod horizon.width, y mod horizon.height].rgba()
      result[x, y] = rgba(
        uint8(int(c.r) * 30 div 100), uint8(int(c.g) * 30 div 100),
        uint8(int(c.b) * 34 div 100), 255)
  var block_x = 0
  var toggle = 0
  while block_x < w:
    let bw = 90 + (toggle mod 3) * 40
    let bh = 60 + (toggle mod 4) * 40
    let source = if toggle mod 2 == 0: wallH else: wallV
    for y in 0 ..< bh:
      for x in 0 ..< bw:
        if block_x + x >= w:
          break
        let c = source[x mod source.width, y mod source.height].rgba()
        result.shade(block_x + x, h - bh + y,
          int(c.r) * 42 div 100, int(c.g) * 40 div 100,
          int(c.b) * 44 div 100, 235)
    block_x += bw + 24
    inc toggle

proc bakeGate(): Image =
  ## The finish gate: red-and-white banding cut from `wall_v.jpg`.
  loadArt()
  let
    w = 26
    h = 300
  result = newImage(w, h)
  for y in 0 ..< h:
    let red = (y div 24) mod 2 == 0
    for x in 0 ..< w:
      let c = wallV[x mod wallV.width, y mod wallV.height].rgba()
      if red:
        result[x, y] = rgba(uint8(200 + int(c.r) div 6), 70, 58, 255)
      else:
        result[x, y] = rgba(uint8(226 + int(c.r) div 12), 224, 212, 255)

proc bakeStartLine(): Image =
  result = newImage(6, 300)
  for y in 0 ..< 300:
    for x in 0 ..< 6:
      result[x, y] = rgba(242, 232, 216, 190)

proc bakeTick(): Image =
  result = newImage(3, 18)
  for y in 0 ..< 18:
    for x in 0 ..< 3:
      result[x, y] = rgba(242, 232, 216, 130)

proc bakeLinkChip(morph: Morph, link: int, glow: bool): Image =
  ## One chip of a link's capsule hull: the red plating of
  ## `data/soldier_red.png` sampled for its colour, with a bevelled edge, a
  ## rivet line and an amber servo ring when the joint it feeds is loaded.
  loadArt()
  let
    s = spec(morph)
    radiusPx = max(3, int(metres(s.links[link].r) * 1_000_000.0 /
      float(UmPerPixel)))
    size = radiusPx * 2 + 6
  result = newImage(size, size)
  let
    c = float(size) / 2.0
    sample = plating[(link * 13 + 7) mod plating.width,
                     (link * 29 + 11) mod plating.height].rgba()
    baseR = 60 + int(sample.r) div 3
    baseG = 24 + int(sample.g) div 5
    baseB = 20 + int(sample.b) div 5
  result.disc(c, c, float(radiusPx) + 1.0, 24, 16, 12, 220)
  result.disc(c, c, float(radiusPx), baseR, baseG, baseB, 255)
  result.disc(c - float(radiusPx) * 0.28, c - float(radiusPx) * 0.28,
    float(radiusPx) * 0.5, min(255, baseR + 60), min(255, baseG + 40),
    min(255, baseB + 34), 190)
  if glow:
    result.disc(c, c, float(radiusPx) * 0.62, 232, 163, 61, 235)

proc bakeHub(hot: bool): Image =
  let size = 16
  result = newImage(size, size)
  let c = float(size) / 2.0
  result.disc(c, c, 6.0, 30, 22, 16, 235)
  if hot:
    result.disc(c, c, 4.2, 224, 82, 58, 255)
  else:
    result.disc(c, c, 4.2, 232, 163, 61, 235)
  result.disc(c, c, 2.0, 246, 232, 208, 255)

proc bakeFoot(planted: bool): Image =
  let size = 26
  result = newImage(size, size)
  let c = float(size) / 2.0
  if planted:
    result.disc(c, c, 10.0, 232, 163, 61, 245)
    result.disc(c, c, 5.0, 246, 232, 208, 255)
  else:
    result.disc(c, c, 10.0, 46, 34, 26, 235)
    result.disc(c, c, 10.0, 138, 127, 114, 90)

proc bakeFootprint(): Image =
  result = newImage(18, 8)
  for y in 0 ..< 8:
    for x in 0 ..< 18:
      result[x, y] = rgba(30, 22, 16, uint8(120 - y * 12))

proc bakeDust(stage: int): Image =
  let size = 34 + stage * 10
  result = newImage(size, size)
  let c = float(size) / 2.0
  result.disc(c, c, c - 2.0, 214, 176, 126, 96 - stage * 26)
  result.disc(c, c, (c - 2.0) * 0.6, 214, 176, 126, 120 - stage * 32)

proc bakeFallRing(): Image =
  let size = 120
  result = newImage(size, size)
  let c = float(size) / 2.0
  result.disc(c, c, c - 2.0, 224, 82, 58, 60)
  result.disc(c, c, c - 10.0, 0, 0, 0, 0)
  for i in 0 ..< 360:
    let a = float(i) * PI / 180.0
    result.shade(int(c + cos(a) * (c - 6.0)), int(c + sin(a) * (c - 6.0)),
      224, 82, 58, 230)

# ---------------------------------------------------------------------------
#  Camera
# ---------------------------------------------------------------------------

proc cameraLeftMicro*(sim: SimServer): int64 =
  ## The camera tracks the torso in x (clamped so the whole track stays inside
  ## `[-6, 60]` m) and is FIXED in y.
  let torso = microMetres(sim.body.links[0].x)
  clamp(torso - int64(CamLeadPx) * int64(UmPerPixel),
    -6_000_000'i64, 52_500_000'i64)

proc boardX(sim: SimServer, xQ16: int64): int =
  int((microMetres(xQ16) - sim.cameraLeftMicro()) div int64(UmPerPixel))

proc boardXMicro(sim: SimServer, xMicro: int64): int =
  int((xMicro - sim.cameraLeftMicro()) div int64(UmPerPixel))

proc boardY(yQ16: int64): int =
  GroundRow - int(microMetres(yQ16) div int64(UmPerPixel))

# ---------------------------------------------------------------------------
#  Packets
# ---------------------------------------------------------------------------

proc addSpriteImage(packet: var seq[uint8], spriteId: int, image: Image,
                    label: string) =
  packet.addSprite(spriteId, image.width, image.height, image.straightRgba(),
    label)

const MaxWsFrameBytes* = 900_000
  ## The hosted replay closes any WS frame larger than 1 MiB (1009), and the
  ## first frame carries the whole baked bed. Kept from ctf.

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one sprite-protocol packet into WS-frame-sized chunks AT MESSAGE
  ## BOUNDARIES. The client accumulates state across binary messages, so N
  ## chunks are equivalent to one packet as long as no frame is cut mid
  ## message. Kept from ctf's `global.nim`.
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    chunkStart = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let compressed = packet.readU32(offset + 6)
      offset += 10 + compressed
      let labelLen = packet.readU16(offset)
      offset += 2 + labelLen
    of 0x02: offset += 11
    of 0x03: offset += 2
    of 0x04: discard
    of 0x05: offset += 5
    of 0x06: offset += 3
    else:
      break
    if offset - chunkStart > maxBytes and messageStart > chunkStart:
      result.add(packet[chunkStart ..< messageStart])
      chunkStart = messageStart
  if chunkStart < packet.len:
    result.add(packet[chunkStart ..< packet.len])

proc buildSpriteProtocolInit*(): seq[uint8] =
  result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
  result.addViewport(MapLayerId, MapWidth, MapHeight)

proc sendStatics(packet: var seq[uint8], state: var GlobalViewerState) =
  if state.spritesSent:
    return
  loadArt()
  if bedPlate.isNil: bedPlate = bakeBed()
  if horizonPlate.isNil: horizonPlate = bakeHorizon()
  if gatePlate.isNil: gatePlate = bakeGate()
  packet.addSpriteImage(BedSpriteId, bedPlate, "track bed")
  packet.addSpriteImage(HorizonSpriteId, horizonPlate, "horizon")
  packet.addSpriteImage(GateSpriteId, gatePlate, "finish gate")
  packet.addSpriteImage(StartLineSpriteId, bakeStartLine(), "start line")
  packet.addSpriteImage(TickSpriteId, bakeTick(), "metre tick")
  for i in 0 .. 12:
    packet.addSpriteImage(NumeralSpriteBase + i,
      textPlate($(i * 5), 44, 22, 18.0, rgba(242, 232, 216, 255),
        rgba(0, 0, 0, 0)), "ruler " & $(i * 5) & " m")
  for m in Morphs:
    let s = spec(m)
    for i in 0 ..< s.linkCount:
      packet.addSpriteImage(LinkSpriteBase + ord(m) * 8 + i,
        bakeLinkChip(m, i, false), "link " & $m & " " & s.links[i].name)
      packet.addSpriteImage(LinkGlowSpriteBase + ord(m) * 8 + i,
        bakeLinkChip(m, i, true),
        "link " & $m & " " & s.links[i].name & " loaded")
  packet.addSpriteImage(HubSpriteId, bakeHub(false), "joint hub")
  packet.addSpriteImage(HubHotSpriteId, bakeHub(true), "joint hub pegged")
  packet.addSpriteImage(FootSpriteBase, bakeFoot(false), "foot airborne")
  packet.addSpriteImage(FootSpriteBase + 1, bakeFoot(true), "foot planted")
  packet.addSpriteImage(FootprintSpriteId, bakeFootprint(), "footprint")
  for stage in 0 .. 2:
    packet.addSpriteImage(DustSpriteBase + stage, bakeDust(stage),
      "dust " & $stage)
  packet.addSpriteImage(FallRingSpriteId, bakeFallRing(), "fall ring")
  for m in Morphs:
    packet.addSpriteImage(MachineSpriteBase + ord(m), machineChips[ord(m)],
      "machine " & morphLabel(m))
  state.spritesSent = true

proc addBed(sim: SimServer, packet: var seq[uint8], live: var seq[int]) =
  ## The bed and the horizon scroll by their DRAW OFFSET only: the bake never
  ## changes, so there is no per-frame map cost.
  let camMicro = sim.cameraLeftMicro()
  let bedOffset = int(((camMicro mod (int64(BedTilePx) * int64(UmPerPixel))) +
    int64(BedTilePx) * int64(UmPerPixel)) mod
    (int64(BedTilePx) * int64(UmPerPixel)) div int64(UmPerPixel))
  packet.addObject(BedObjectBase, -bedOffset, 0, StaticBandZ, MapLayerId,
    BedSpriteId)
  live.add(BedObjectBase)
  let horizonOffset = int((camMicro * 35 div 100) div int64(UmPerPixel)) mod
    (MapWidth + BedTilePx)
  packet.addObject(HorizonObjectBase, -horizonOffset, GroundRow - 220, -30_000,
    MapLayerId, HorizonSpriteId)
  live.add(HorizonObjectBase)

proc addRuler(sim: SimServer, packet: var seq[uint8], live: var seq[int]) =
  ## Metre ticks and a numeral every 5 m, placed at WORLD positions so the
  ## ruler slides under the machine and speed is legible as motion.
  var slot = 0
  for metre in -6 .. 60:
    let x = sim.boardXMicro(int64(metre) * 1_000_000'i64)
    if x < -40 or x > MapWidth + 40:
      continue
    if slot >= 80:
      break
    packet.addObject(TickObjectBase + slot, x, GroundRow + 4, -20_000,
      MapLayerId, TickSpriteId)
    live.add(TickObjectBase + slot)
    inc slot
    if metre mod 5 == 0 and metre >= 0:
      let index = metre div 5
      packet.addObject(NumeralObjectBase + index, x - 20, GroundRow + 26,
        -19_000, MapLayerId, NumeralSpriteBase + index)
      live.add(NumeralObjectBase + index)
  let startX = sim.boardXMicro(0)
  if startX > -20 and startX < MapWidth + 20:
    packet.addObject(StartLineObjectId, startX - 3, GroundRow - 300, -18_000,
      MapLayerId, StartLineSpriteId)
    live.add(StartLineObjectId)
  let gateX = sim.boardXMicro(60_000_000'i64)
  if gateX > -40 and gateX < MapWidth + 40:
    packet.addObject(GateObjectId, gateX - 13, GroundRow - 300, -17_000,
      MapLayerId, GateSpriteId)
    live.add(GateObjectId)

proc addMachine(sim: SimServer, packet: var seq[uint8], live: var seq[int]) =
  ## Every link composited from `LinkChips` chips along its own segment, in
  ## LINK INDEX ORDER, then the joint hubs, then the feet. A joint at >= 90 %
  ## of its torque cap glows amber; at 100 % its hub flashes red, so a
  ## spectator can SEE which joint is pegged.
  let s = sim.spec
  var loaded: array[MaxLinks, bool]
  var hot: array[MaxJoints, bool]
  for j in 0 ..< s.jointCount:
    let pct = sim.torquePct(j)
    if pct >= 90:
      loaded[s.joints[j].child] = true
    hot[j] = pct >= 100
  var obj = LinkObjectBase
  for i in 0 ..< s.linkCount:
    let
      hl = s.links[i].hl
      sprite = (if loaded[i]: LinkGlowSpriteBase else: LinkSpriteBase) +
        ord(sim.morph) * 8 + i
      radiusPx = max(3, int(metres(s.links[i].r) * 1_000_000.0 /
        float(UmPerPixel)))
      half = radiusPx + 3
    for chip in 0 ..< LinkChips:
      let t = -hl + (2 * hl * int64(chip)) div int64(LinkChips - 1)
      let p = sim.body.links[i].localToWorld(0, t)
      packet.addObject(obj, sim.boardX(p.x) - half, boardY(p.y) - half,
        1000 + i * 4, MapLayerId, sprite)
      live.add(obj)
      inc obj
  for j in 0 ..< s.jointCount:
    let
      js = s.joints[j]
      anchor = sim.body.links[js.parent].localToWorld(js.pOffX, js.pOffY)
    packet.addObject(HubObjectBase + j, sim.boardX(anchor.x) - 8,
      boardY(anchor.y) - 8, 1400 + j, MapLayerId,
      (if hot[j]: HubHotSpriteId else: HubSpriteId))
    live.add(HubObjectBase + j)
  for f in 0 ..< s.footCount:
    let
      idx = s.feet[f]
      planted = sim.body.footOnGround(s, f, PenetrationSlopQ16)
      p = sim.body.contactPoint(s, idx, 1)
    packet.addObject(FootObjectBase + f, sim.boardX(p.x) - 13,
      boardY(p.y) - 13, 1500 + f, MapLayerId,
      FootSpriteBase + (if planted: 1 else: 0))
    live.add(FootObjectBase + f)
    if planted and sim.body.footSlip(s, f) > 3_277:
      let stage = (sim.tick div 3) mod 3
      packet.addObject(DustObjectBase + f, sim.boardX(p.x) - 20,
        boardY(p.y) - 14, 1600 + f, MapLayerId, DustSpriteBase + stage)
      live.add(DustObjectBase + f)
  if sim.phase == phStageReset and sim.stageIndex >= 0 and
      sim.stages[sim.stageIndex].outcome == soFell:
    let torso = sim.body.links[0]
    packet.addObject(FallRingObjectId, sim.boardX(torso.x) - 60,
      boardY(torso.y) - 60, 1800, MapLayerId, FallRingSpriteId)
    live.add(FallRingObjectId)

proc addFootprints(sim: SimServer, packet: var seq[uint8],
                   live: var seq[int], marks: openArray[array[2, int]]) =
  ## The 64-entry ring of ground marks left at each footstrike.
  var slot = 0
  for mark in marks:
    if slot >= FootprintRing:
      break
    let x = sim.boardXMicro(int64(mark[0]))
    if x < -20 or x > MapWidth + 20:
      inc slot
      continue
    packet.addObject(FootprintObjectBase + slot, x - 9, GroundRow - 4, -16_000,
      MapLayerId, FootprintSpriteId)
    live.add(FootprintObjectBase + slot)
    inc slot

proc addMachineChip(sim: SimServer, packet: var seq[uint8],
                    live: var seq[int]) =
  ## The morphology's identity chip, pinned in the board's top-left corner so
  ## the machine in play is legible even at 360 px, where a 0.5 m link is ten
  ## board pixels.
  packet.addObject(MachineObjectId, 24, 24, 3000, MapLayerId,
    MachineSpriteBase + ord(sim.morph))
  live.add(MachineObjectId)

proc buildViewerPacket*(sim: SimServer, state: GlobalViewerState,
                        nextState: var GlobalViewerState, chrome: string,
                        footprints: openArray[array[2, int]] = []): seq[uint8] =
  ## One presentation frame: the layer/viewport on the first packet, every
  ## sprite definition once, then the bed, the ruler, the footprints and the
  ## machine every frame (the client re-describes only what moved), and the
  ## chrome JSON smuggled as the label of the reserved 1 x 1 sprite.
  nextState = state
  if not state.initialised:
    result.add(buildSpriteProtocolInit())
    nextState.initialised = true
  result.sendStatics(nextState)
  var live: seq[int] = @[]
  sim.addBed(result, live)
  sim.addRuler(result, live)
  sim.addFootprints(result, live, footprints)
  if sim.stageIndex >= 0:
    sim.addMachine(result, live)
    sim.addMachineChip(result, live)
  for objectId in state.liveObjects:
    if objectId notin live:
      result.addDeleteObject(objectId)
  nextState.liveObjects = live
  result.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chrome)

proc warmBoardRenderCaches*() =
  ## Bakes the bed and the horizon BEFORE the listener opens: a viewer's
  ## first-message clock starts at its successful connect (the certifier allows
  ## only seconds), so nothing may be accepted until every frame the loop will
  ## ever build can be assembled instantly.
  loadArt()
  if bedPlate.isNil: bedPlate = bakeBed()
  if horizonPlate.isNil: horizonPlate = bakeHorizon()
  if gatePlate.isNil: gatePlate = bakeGate()

proc boardAspect*(): float = float(MapWidth) / float(MapHeight)
