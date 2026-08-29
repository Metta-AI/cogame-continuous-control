## The continuous-control player container: a policy is just a prompt.
##
## This process is DELIBERATELY thin. It connects to its seat, sends ONE Sprite
## v1 chat message carrying its registration, and thereafter only acknowledges
## frames: every decision happens inside the GAME server, because that is the
## only container the platform injects the `anthropic_api_key` coworld secret
## into, and because keeping the decision layer server-side is what makes the
## recorded per-turn order log reproducible with no network in the loop.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      trotter | plodder            -> this seat is scripted
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `trotter`. To field your own policy, reuse this
## image and set PLAYER_PROMPT:
##
##   coworld upload-policy coworld-continuous-control --name my-cog \
##     --run /bin/continuous-control-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils, times]
import bitworld/spriteprotocol
import whisky
import cc/sim_types

const
  ConnectAttempts = 8
  ConnectBackoffMs = 250
  ReRegisterSeconds = 10.0
    ## The registration blob is RE-SENT for the first ~10 s of received frames:
    ## a first send can race the server's slot bookkeeping and the seat then
    ## plays the default baseline for the whole episode with no error anywhere
    ## (the paintball 2026-08-25 slot-sequential-join scar).

when isMainModule:
  var url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    url = getEnv("COGAMES_ENGINE_WS_URL")   ## the legacy alias
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT").truncateRunes(MaxPromptRunes)
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  let label = getEnv("PLAYER_POLICY_LABEL").truncateRunes(MaxPolicyLabelRunes)

  let registration = $(%*{
    "policy": (if label.len > 0: label
               elif prompt.strip().len > 0: "llm"
               elif scripted.len > 0: scripted
               else: "trotter"),
    "prompt": prompt,
    "scripted": (if scripted.len > 0: %scripted else: newJNull())})

  var socket: WebSocket = nil
  for attempt in 1 .. ConnectAttempts:
    try:
      socket = newWebSocket(url)
      break
    except CatchableError as error:
      echo "continuous-control player: connect attempt ", attempt,
        " failed: ", error.msg
      if attempt == ConnectAttempts:
        ## A bounded retry, then leave quietly: the game declares the no-show
        ## itself and plays the seat on the trotter baseline.
        echo "continuous-control player: giving up on ", url
        quit(0)
      sleep(ConnectBackoffMs * attempt)

  proc sendRegistration() =
    try:
      socket.send(blobFromSpriteChat(registration), BinaryMessage)
    except CatchableError as error:
      echo "continuous-control player: registration send failed: ", error.msg

  sendRegistration()
  echo "continuous-control player: registered (", prompt.len, " prompt chars",
    (if scripted.len > 0: ", scripted " & scripted else: ", llm"), ")"

  let started = epochTime()
  while true:
    ## whisky's `receiveMessage` RAISES rather than returning none on both a
    ## close frame and a half-read one, and mummy's `send` only queues: the
    ## game writes its artifacts and exits, so a seat can lose the socket
    ## before its `done` frame is flushed. EXIT 0 on a dead socket — a player
    ## that dies here fails certification with `player_error` (the raid 0.1.3
    ## close-frame race).
    var received: Option[Message]
    try:
      received = socket.receiveMessage()
    except CatchableError as error:
      echo "continuous-control player: connection ended (", error.msg,
        "), exiting"
      break
    if received.isNone:
      echo "continuous-control player: connection closed, exiting"
      break
    if epochTime() - started < ReRegisterSeconds:
      sendRegistration()
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      if payload{"done"}.getBool():
        echo "continuous-control player: final score ",
          payload{"result"}{"scores"}
        break
      case payload{"type"}.getStr()
      of "welcome":
        echo "continuous-control player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"alias"}.getStr()
        sendRegistration()
      else:
        discard
    except CatchableError as error:
      echo "continuous-control player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
