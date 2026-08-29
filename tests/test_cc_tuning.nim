## The swept parameter pins.
##
## `tools/tune_gaits.nim` and `tools/tune_baselines.nim` sweep the gait table,
## the servo gains and the six baseline knobs; `tools/ci/gait_tuning.json` and
## `tools/ci/baseline_tuning.json` record the picks. THE MORPHOLOGY, SOLVER AND
## SCORING CONSTANTS ARE NOT SWEPT AND ARE NOT TUNABLE: if a body cannot walk,
## the sweep moves, not the physics.

import std/[json, strutils, unittest]
import cc/[sim, sim_config, baselines]
import helpers

suite "the shipped tuning equals the committed pick":
  test "the gait table equals tools/ci/gait_tuning.json":
    let pinned = parseJson(readRepoFile("tools/ci/gait_tuning.json"))
    let shipped = gaitTableJson(GaitTable)
    for morph in Morphs:
      checkpoint($morph)
      check pinned["gaits"][$morph] == shipped[$morph]

  test "the baseline knobs equal tools/ci/baseline_tuning.json":
    let pinned = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
    let params = defaultBaselineParams()
    check pinned["settleTicks"].getInt() == int(params.settleTicks)
    for i in 0 .. 2:
      check pinned["targetVxMicro"][i].getInt() == int(params.targetVxMicro[i])
      check pinned["rampCadence"][i].getInt() == int(params.rampCadence[i])
      check pinned["cruiseCadence"][i].getInt() ==
        int(params.cruiseCadence[i])
      check pinned["cruisePower"][i].getInt() == int(params.cruisePower[i])
      check pinned["biasFor"][i].getInt() == int(params.biasFor[i])

  test "the physics constants are NOT in either tuning file":
    let gaits = readRepoFile("tools/ci/gait_tuning.json")
    let baselines = readRepoFile("tools/ci/baseline_tuning.json")
    for forbidden in ["gravity", "groundFriction", "distNum", "distDen",
                      "uprightPerTick", "substepsPerTick", "solverIterations",
                      "tauMax", "hl", "invM"]:
      checkpoint(forbidden)
      check forbidden notin gaits
      check forbidden notin baselines
