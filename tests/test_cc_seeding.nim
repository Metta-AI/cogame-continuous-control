## Seeding and determinism — §Tests 18-21.

import std/[math, random, tables, unittest]
import cc/[sim, sim_config, baselines]
import helpers

proc poseWords(morph: Morph, seed: int64, stage: int): seq[int64] =
  var perturb: array[MaxJoints, int32]
  let body = buildStartPose(seed, stage, morph, perturb)
  let s = spec(morph)
  for i in 0 ..< s.linkCount:
    result.add(body.links[i].x)
    result.add(body.links[i].y)
    result.add(body.links[i].a)
  for j in 0 ..< s.jointCount:
    result.add(int64(perturb[j]))

suite "seeded start poses":
  test "18. start poses are a pure function of (seed, stageIndex)":
    ## Every stage of every variant starts identically under three different
    ## policy behaviours, Q16 word for word, including the perturbation.
    for ladder in [@[mHopper, mCheetah, mWalker], @[mHopper, mWalker, mWalker]]:
      var seen: seq[seq[int64]] = @[]
      for stage in 0 .. 2:
        seen.add(poseWords(ladder[stage], 4242, stage))
      for kind in [blTrotter, blPlodder]:
        let run = runScriptedEpisode(ladderConfig(ladder, 4242), kind)
        for stage in 0 .. 2:
          check poseWords(ladder[stage], 4242, stage) == seen[stage]
        check run.sim.tick > 0
      ## and a third behaviour: a constant order
      var config = ladderConfig(ladder, 4242)
      var sim = newSimServer(config)
      sim.phase = phPlaying
      sim.startStage(0)
      while not sim.episodeOver():
        if sim.turnDue():
          sim.beginTurn(Order(gait: gBound, cadence: 91, power: 33))
        sim.stepTick()
        if sim.ladderComplete(): break
      for stage in 0 .. 2:
        check poseWords(ladder[stage], 4242, stage) == seen[stage]

  test "19. stage k's start is independent of what happened in stage k-1":
    let early = poseWords(mWalker, 777, 2)
    ## a stage that fell at tick 20 and a stage that ran to 468 both leave
    ## stage 2's start untouched, because the draw is a pure hash.
    check poseWords(mWalker, 777, 2) == early
    check poseWords(mWalker, 777, 2) != poseWords(mWalker, 777, 1)
    check poseWords(mWalker, 778, 2) != early

  test "20. the seed spans the space":
    var buckets = newSeq[int](10)
    var poses = initTable[string, int]()
    var collisions = 0
    for seed in 1 .. 5_000:
      var perturb: array[MaxJoints, int32]
      discard buildStartPose(int64(seed), 0, mWalker, perturb)
      for j in 0 ..< spec(mWalker).jointCount:
        let bucket = int((int64(perturb[j]) + InitPerturbQ16) * 10 div
          (2 * InitPerturbQ16 + 1))
        buckets[clamp(bucket, 0, 9)] += 1
      var key = ""
      for stage in 0 .. 2:
        var p2: array[MaxJoints, int32]
        discard buildStartPose(int64(seed), stage, mWalker, p2)
        for j in 0 ..< MaxJoints:
          key.add($p2[j] & ",")
      if poses.hasKeyOrPut(key, seed):
        inc collisions
    ## uniform within a chi-squared bound (9 dof, 0.1 % -> 27.9)
    var expected = 0.0
    for count in buckets:
      expected += float(count)
    expected = expected / 10.0
    var chi = 0.0
    for count in buckets:
      chi += (float(count) - expected) * (float(count) - expected) / expected
    check chi < 27.9
    ## no two seeds in the sweep produce the same three-stage pose set
    check collisions == 0

  test "21. two episodes, same seed, same orders: byte-identical":
    let config = ladderConfig(@[mHopper, mCheetah, mWalker], 909)
    let a = runScriptedEpisode(config)
    let b = runScriptedEpisode(config)
    check a.bytes == b.bytes
    check a.sim.hashes == b.sim.hashes
    check a.sim.keyframes.len == b.sim.keyframes.len
    for i in 0 ..< a.sim.keyframes.len:
      check a.sim.keyframes[i] == b.sim.keyframes[i]
