# SPDX-FileCopyrightText: © 2026 Filip Jasionek
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

import model

GATE_LEVEL = os.environ.get("GATES") == "yes"


async def capture(dut, index):
    """Capture the next full frame from the VGA pins (done in tb.v)."""
    dut.capture.value = 1
    await RisingEdge(dut.capture_done)
    dut.capture.value = 0
    await FallingEdge(dut.capture_done)
    return model.read_ppm(f"output/frame{index}.ppm")


def match_phase(dut, img, refs, name):
    """The colour phase whose model frame equals img exactly."""
    for phase, ref in enumerate(refs):
        if img == ref:
            dut._log.info(f"{name}: matches model at phase {phase}")
            return phase
    best = min(range(16), key=lambda p: sum(a != b for a, b in zip(img, refs[p])))
    bad = [i for i in range(len(img)) if img[i] != refs[best][i]]
    raise AssertionError(
        f"{name}: no phase matches; closest {best} differs in {len(bad)} pixels, "
        f"first at ({bad[0] % 640},{bad[0] // 640}): got {img[bad[0]]}, expected {refs[best][bad[0]]}")


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")
    os.makedirs("output", exist_ok=True)

    # the 50.35 MHz clock is generated in tb.v

    # Reset; speed 0 (step every frame), forward, running
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    assert dut.uio_oe.value == 0, "bidirectional pins must stay inputs"

    grid = model.blocks()
    pal = model.palette()
    refs = [model.frame(grid, pal, p) for p in range(16)]
    inside = sum(n is None for row in grid for n in row)
    dut._log.info(f"model: {inside} of {model.COLS * model.ROWS} blocks inside the set")

    # (ui_in for the capture, expected phase step from the previous frame)
    steps = [(0b0000, None),   # forward
             (0b0000, +1)]
    if not GATE_LEVEL:  # gate-level sim is slow: one forward step is enough there
        steps += [(0b0100, -1),   # reverse
                  (0b0100, -1),
                  (0b1100, 0),    # pause
                  (0b1100, 0)]

    phases = []
    for i, (ui, step) in enumerate(steps):
        dut.ui_in.value = ui
        img = await capture(dut, i)
        phase = match_phase(dut, img, refs, f"frame{i}")
        if step is not None:
            got = (phase - phases[-1]) % 16
            assert got == step % 16, f"frame{i}: phase {phases[-1]} -> {phase}, expected step {step:+d}"
        phases.append(phase)

    if not GATE_LEVEL:
        # speed 1 (step every 2nd frame): over 4 frames the phase advances by 2
        dut.ui_in.value = 0b0001
        start = phases[-1]
        for i in range(len(steps), len(steps) + 4):
            img = await capture(dut, i)
            phases.append(match_phase(dut, img, refs, f"frame{i}"))
        advanced = (phases[-1] - start) % 16
        assert advanced == 2, f"speed 1: phase advanced {advanced} over 4 frames, expected 2"

    # palette select (ui_in[5:4]), paused so the phase must stay put
    sels = [1, 2, 3] if not GATE_LEVEL else [2]
    held = phases[-1]
    for sel in sels:
        dut.ui_in.value = (sel << 4) | 0b1000
        i = len(phases)
        img = await capture(dut, i)
        ref = model.frame(grid, model.palette(sel), held)
        if img != ref:
            bad = [k for k in range(len(img)) if img[k] != ref[k]]
            raise AssertionError(f"frame{i}: palette {sel} at phase {held} differs in {len(bad)} pixels, "
                                 f"first at ({bad[0] % 640},{bad[0] // 640}): got {img[bad[0]]}, expected {ref[bad[0]]}")
        dut._log.info(f"frame{i}: matches model with palette {sel} at phase {held}")
        phases.append(held)

    dut._log.info(f"phase sequence {phases}")
