#!/usr/bin/env python3
"""Prints ONE strict-UTF-8 JSON object summarising a `COWLDCCL` replay.

Python 3 standard library only: no Nim, no Docker, no browser. This is the
phase-60 substitute for `docs/SPEC.md` §Definition of done check 4, because the
replay this game records is BINARY (the static wasm viewer parses exactly that
format, and a JSON replay would mean rewriting the machinery this fork exists
to reuse — the knights-archers precedent).

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                      # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.endRule, .results.totalReturn' /tmp/ep.json
    jq -r '[.orders[]|select(.source=="llm")]|length, .fallbacks, (.says|length)' /tmp/ep.json
    jq -r '[.orders[]|.gait]|unique|length, ([.orders[]|.cadence]|unique|length)' /tmp/ep.json

Every string in the output is decoded as UTF-8 and re-encoded by `json.dumps`
with `ensure_ascii=False`, so a lone surrogate or a byte-truncated codepoint in
the file is a hard error here rather than a silently mangled report.
"""

import json
import struct
import sys

MAGIC = b"COWLDCCL"
FORMAT_VERSION = 1

KIND_STAGE = 1
KIND_ORDER = 2
KIND_CHAT = 3
KIND_STOP = 4
KIND_KEYFRAME = 5

GAITS = ["stand", "crouch", "walk", "run", "bound", "brake"]
SOURCES = ["llm", "scripted", "fallback"]


class Cursor:
    def __init__(self, data):
        self.data = data
        self.offset = 0

    def need(self, count):
        if count < 0 or self.offset + count > len(self.data):
            raise SystemExit("replay truncated")

    def u8(self):
        self.need(1)
        value = self.data[self.offset]
        self.offset += 1
        return value

    def u16(self):
        self.need(2)
        value = struct.unpack_from("<H", self.data, self.offset)[0]
        self.offset += 2
        return value

    def u32(self):
        self.need(4)
        value = struct.unpack_from("<I", self.data, self.offset)[0]
        self.offset += 4
        return value

    def i32(self):
        self.need(4)
        value = struct.unpack_from("<i", self.data, self.offset)[0]
        self.offset += 4
        return value

    def u64(self):
        self.need(8)
        value = struct.unpack_from("<Q", self.data, self.offset)[0]
        self.offset += 8
        return value

    def text(self):
        length = self.u32()
        self.need(length)
        raw = self.data[self.offset:self.offset + length]
        self.offset += length
        # STRICT: a byte-truncated codepoint fails here rather than being
        # replaced, which is the whole point of the rune-boundary rule.
        return raw.decode("utf-8")


def summarise(path):
    data = open(path, "rb").read()
    if not data.startswith(MAGIC):
        raise SystemExit("not a %s replay" % MAGIC.decode("ascii"))
    cursor = Cursor(data)
    cursor.offset = len(MAGIC)
    version = cursor.u16()
    if version != FORMAT_VERSION:
        raise SystemExit("replay format version %d is not supported" % version)
    game_name = cursor.text()
    game_version = cursor.text()
    protocol = cursor.text()
    config = json.loads(cursor.text())

    body_length = cursor.u32()
    body_end = cursor.offset + body_length
    stages, orders, says, chats = [], [], [], []
    keyframes = 0
    fallbacks = 0
    stop = None
    results = {}
    register = None
    while cursor.offset < body_end:
        kind = cursor.u8()
        tick = cursor.u32()
        if kind == KIND_STAGE:
            index = cursor.u16()
            morph = cursor.text()
            start_tick = cursor.u32()
            count = cursor.u16()
            perturb = [cursor.i32() for _ in range(count)]
            stages.append({"i": index, "morph": morph, "tick": tick,
                           "startTick": start_tick, "perturb": perturb})
        elif kind == KIND_ORDER:
            turn = cursor.u16()
            stage = cursor.u16() - 1
            source = cursor.u8()
            gait = cursor.u8()
            cadence = cursor.i32()
            power = cursor.i32()
            lean = cursor.i32()
            stride_bias = cursor.i32()
            phase_shift = cursor.i32()
            repaired = cursor.u16()
            say = cursor.text()
            notes = cursor.text()
            orders.append({
                "tick": tick, "turn": turn, "stage": stage,
                "source": SOURCES[source] if source < len(SOURCES) else "?",
                "gait": GAITS[gait] if gait < len(GAITS) else "?",
                "cadence": cadence, "power": power, "lean": lean,
                "stride_bias": stride_bias, "phase_shift": phase_shift,
                "repaired": repaired, "say": say, "notes_len": len(notes)})
            if say:
                says.append({"tick": tick, "turn": turn, "text": say})
        elif kind == KIND_CHAT:
            text = cursor.text()
            try:
                node = json.loads(text)
            except ValueError:
                chats.append({"tick": tick, "raw": text[:120]})
                continue
            kindName = node.get("k")
            if kindName == "result":
                results = node.get("results", {})
            elif kindName == "fallback":
                fallbacks += 1
                chats.append({"tick": tick, "k": "fallback",
                              "cause": node.get("cause"),
                              "attempt": node.get("attempt")})
            elif kindName == "register":
                register = {"alias": node.get("alias"),
                            "name": node.get("name"),
                            "policy": node.get("policy"),
                            "kind": node.get("kind"),
                            "baseline": node.get("baseline")}
            elif kindName == "budget_guard":
                chats.append({"tick": tick, "k": "budget_guard",
                              "turn": node.get("turn")})
        elif kind == KIND_KEYFRAME:
            count = cursor.u16()
            for _ in range(count):
                cursor.i32()
            keyframes += 1
        elif kind == KIND_STOP:
            reason = cursor.text()
            end_rule = cursor.text()
            detail = cursor.text()
            stop = {"tick": tick, "reason": reason, "endRule": end_rule,
                    "detail": detail}
        else:
            raise SystemExit("unknown replay record kind %d" % kind)
    cursor.offset = body_end
    hash_count = cursor.u32()
    for _ in range(hash_count):
        cursor.u64()

    return {
        "protocol": protocol,
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "variant": config.get("variant"),
        "names": results.get("names", []),
        "aliases": results.get("aliases", []),
        "policyKinds": results.get("policyKinds", []),
        "register": register,
        "tickCount": hash_count,
        "keyframes": keyframes,
        "stages": stages,
        "orders": orders,
        "says": says,
        "chats": chats,
        "fallbacks": fallbacks,
        "stop": stop,
        "results": results,
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: replay_summary.py <replay path>")
    sys.stdout.write(
        json.dumps(summarise(sys.argv[1]), ensure_ascii=False) + "\n")
