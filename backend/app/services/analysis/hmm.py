"""Viterbi decoding of descent, stop, lift, and unknown between anchored lifts (spec section 7)."""

from __future__ import annotations

from collections.abc import Sequence
from enum import IntEnum

from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.lift_matching import LiftSpan
from app.services.analysis.signal import FeatureFrame

_IMPOSSIBLE = -50.0
_DECODED_STATES = 4


class State(IntEnum):
    DESCENT = 0
    STOP = 1
    LIFT = 2
    UNKNOWN = 3
    INVALID = 4


def decode(
    frame: FeatureFrame, anchored: Sequence[LiftSpan], config: AnalyzerConfig
) -> list[State]:
    n = len(frame)
    states: list[State | None] = [None] * n
    for span in anchored:
        for i in range(max(0, span.start), min(n - 1, span.end) + 1):
            states[i] = State.LIFT
    i = 0
    while i < n:
        if states[i] is not None:
            i += 1
            continue
        j = i
        while j + 1 < n and states[j + 1] is None:
            j += 1
        states[i : j + 1] = _viterbi(frame, i, j, config)
        i = j + 1
    return [s if s is not None else State.STOP for s in states]


def _emissions(frame: FeatureFrame, i: int, config: AnalyzerConfig) -> list[float]:
    if frame.gap[i]:
        return [_IMPOSSIBLE, _IMPOSSIBLE, _IMPOSSIBLE, 0.0]
    speed, vrate = frame.speed[i], frame.vrate[i]

    descent = (
        0.0
        if speed > config.descent_fast_mps
        else -1.5
        if speed > config.descent_slow_mps
        else -4.0
    )
    descent += 0.0 if vrate < config.descent_vrate_mps else -1.0 if vrate <= 0.3 else -4.0

    stop = 0.0 if speed < config.still_mps else -1.5 if speed < config.stop_fast_mps else -5.0
    stop += 0.0 if abs(vrate) <= 0.3 else -2.0

    lift = 0.0 if 1.0 <= speed <= config.lift_max_mps else -2.0 if speed < 1.0 else -4.0
    lift += 0.0 if vrate > config.lift_vrate_mps else -1.5 if vrate >= -0.1 else -5.0
    lift += 0.0 if frame.heading_var[i] <= config.lift_heading_var_max else -1.0

    return [descent, stop, lift, _IMPOSSIBLE]


def _viterbi(frame: FeatureFrame, lo: int, hi: int, config: AnalyzerConfig) -> list[State]:
    transitions = [
        [0.0, config.switch_descent_stop, config.switch_descent_lift, 0.0],
        [config.switch_stop_descent, 0.0, config.switch_stop_lift, 0.0],
        [config.switch_lift_descent, config.switch_lift_stop, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0],
    ]
    score = _emissions(frame, lo, config)
    back: list[list[int]] = []
    for i in range(lo + 1, hi + 1):
        emit = _emissions(frame, i, config)
        new_score: list[float] = []
        pointers: list[int] = []
        for j in range(_DECODED_STATES):
            best_value, best_state = score[0] + transitions[0][j], 0
            for k in range(1, _DECODED_STATES):
                value = score[k] + transitions[k][j]
                if value > best_value:
                    best_value, best_state = value, k
            new_score.append(best_value + emit[j])
            pointers.append(best_state)
        score = new_score
        back.append(pointers)
    path = [max(range(_DECODED_STATES), key=lambda j: score[j])]
    for pointers in reversed(back):
        path.append(pointers[path[-1]])
    path.reverse()
    return [State(s) for s in path]
