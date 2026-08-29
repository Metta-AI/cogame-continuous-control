## Scoring — §Tests 15-17.

import std/[json, random, unittest]
import cc/[sim, sim_config, report, baselines]
import helpers

suite "the return":
  test "15. the formula, exactly, in micro-points":
    var rng = initRand(15)
    for morph in Morphs:
      let s = spec(morph)
      for _ in 0 ..< 500:
        var config = ladderConfig(@[morph, morph, morph], 1)
        var sim = newSimServer(config)
        var record = sim.stages[0]
        record.morph = morph
        record.distanceMicro = int64(rng.rand(-12_000_000 .. 60_000_000))
        record.uprightTicks = int32(rng.rand(0 .. 468))
        record.ctrlCostMicro = int64(rng.rand(0 .. 500_000))
        sim.stages[0] = record
        let want = (record.distanceMicro * s.distNum) div s.distDen +
          s.uprightPerTick * int64(record.uprightTicks) - record.ctrlCostMicro
        check sim.stageReturnMicro(0) == want

  test "15b. totalReturn is the sum, and scores[0] rounds it to 3 decimals":
    let run = runScriptedEpisode(ladderConfig(
      @[mHopper, mCheetah, mWalker], 42))
    var total = 0'i64
    for record in run.sim.stages:
      total += record.returnMicro
    check total == run.sim.totalReturnMicro
    check run.results["scores"][0].getFloat() ==
      micro3(run.sim.totalReturnMicro)
    check run.results["totalReturn"].getFloat() ==
      micro3(run.sim.totalReturnMicro)

  test "16. sign, bounds, and the maxima":
    ## a backwards run produces a NEGATIVE score and is not clamped
    var config = ladderConfig(@[mCheetah, mCheetah, mCheetah], 3)
    var sim = newSimServer(config)
    sim.phase = phPlaying
    sim.startStage(0)
    sim.body.translate(sim.spec, -5 * OneQ16, 0)
    sim.beginTurn(defaultOrder())
    sim.stepTick()
    sim.settle(endComplete, erLadderComplete)
    check sim.totalReturnMicro < 0
    check sim.ladderResultsJson()["scores"][0].getFloat() < 0.0
    ## the theoretical maxima
    check micro3(maxReturnMicro(ladderConfig(
      @[mHopper, mCheetah, mWalker], 1))) == 243.744
    var bipeds = ladderConfig(@[mHopper, mWalker, mWalker], 1)
    bipeds.par = 30_000_000
    check micro3(maxReturnMicro(bipeds)) == 305.616
    ## the control cost never exceeds 0.439 points on a 6-joint stage
    check (468'i64 * 6 * 100 * 100) div 64 <= 439_000
    ## win and winner
    var winning = newSimServer(ladderConfig(@[mHopper, mCheetah, mWalker], 1))
    winning.totalReturnMicro = 40_000_001
    check winning.episodeWin()
    check winning.ladderResultsJson()["winner"].getInt() == 0
    winning.totalReturnMicro = 39_999_999
    check not winning.episodeWin()
    check winning.ladderResultsJson()["winner"].kind == JNull

  test "17. no single stage dominates the ladder":
    ## At the pinned baseline distances the three stages' returns are within a
    ## factor of 1.6 of each other on `ladder` — the three points-per-metre
    ## numbers are the INVERSE of how far each body can go, chosen so that a
    ## competent run is worth roughly twenty points on every stage.
    let competent = [9_000_000'i64, 45_000_000, 16_000_000]
    var returns: array[3, float]
    for i, morph in [mHopper, mCheetah, mWalker]:
      let s = spec(morph)
      returns[i] = float((competent[i] * s.distNum) div s.distDen +
        s.uprightPerTick * 468) / 1_000_000.0
    for i in 0 .. 2:
      for j in 0 .. 2:
        check returns[i] <= returns[j] * 1.6
