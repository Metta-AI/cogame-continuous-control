## Emits `src/cc/trig.nim`'s committed `SinQ16Table` on stdout.
##
## The table is generated ONCE and checked in; `tests/test_cc_sim.nim` 3
## re-derives every one of the 1 025 entries from `math.sin` and asserts
## `|err| <= 2` in Q16. Regenerate with:
##
##   nim r --hints:off tools/gen_trig_table.nim > /tmp/table.nim
##
## and splice the array body into `src/cc/trig.nim`. Nothing at runtime calls
## `math.sin`: that is what makes the native amd64 server and the
## emscripten/wasm32 replay viewer agree bit for bit rather than depending on
## two builds of libm agreeing.

import std/[math, strutils]

when isMainModule:
  var row: seq[string] = @[]
  for k in 0 .. 1024:
    let value = int32(round(65536.0 * sin(float(k) * PI / 2048.0)))
    row.add($value & "'i32")
    if row.len == 8 or k == 1024:
      echo "    " & row.join(", ") & (if k == 1024: "" else: ",")
      row = @[]
