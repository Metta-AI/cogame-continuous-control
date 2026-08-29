#!/usr/bin/env python3
"""Generates the three machines' visual identity sheet with nano-banana.

    GEMINI_API_KEY=... python3 scripts/art/gen_machine_sheet.py

The Softmax cog is the character, one kit per morphology, so a spectator can
tell the three machines apart at board scale without reading a label. The
render is committed under scripts/art/source/ and split by
scripts/art/split_machine_sheet.py; CI never regenerates art.

The key is NEVER printed, never written to a file and never passed as a URL
parameter: it is the `x-goog-api-key` header and nothing else.
"""

import base64
import json
import os
import urllib.request

REFERENCE = "data/soldier_red_front.png"
OUT = "scripts/art/source/machines_sheet.png"

PROMPT = """Using this robot character ("cog") as the exact character design
reference, draw THREE side-view mechanical running machines in one row, evenly
spaced, same height, same clean cartoon rendering, each built from the same
red-plated riveted parts and each carrying the cog's screen face on its body.
Background: perfectly flat, solid, uniform pure bright green (#00FF00), no
shadows, no gradients, no floor - it will be chroma-keyed out.
LEFT - HOPPER: a ONE-LEGGED pogo machine, a short upright torso over a single
long leg ending in a wide flat foot, amber (#E8A33D) servo bands at each joint.
MIDDLE - CHEETAH: a LONG LOW horizontal body on two short legs, nose forward,
built for speed, teal (#3FACC4) servo bands at each joint.
RIGHT - WALKER: an UPRIGHT two-legged machine with a tall torso and two long
legs with flat feet, pale (#F2E8D8) servo bands at each joint.
Side elevation, all three facing right. No text, no labels, no ground line."""


def main():
    reference = base64.b64encode(open(REFERENCE, "rb").read()).decode()
    body = {
        "contents": [{"parts": [
            {"inline_data": {"mime_type": "image/png", "data": reference}},
            {"text": PROMPT}]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        "https://generativelanguage.googleapis.com/v1beta/models/"
        "gemini-2.5-flash-image:generateContent",
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"],
                 "content-type": "application/json"})
    response = json.load(urllib.request.urlopen(request))
    part = next(p for p in response["candidates"][0]["content"]["parts"]
                if "inlineData" in p)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "wb").write(base64.b64decode(part["inlineData"]["data"]))
    print("wrote", OUT, os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
