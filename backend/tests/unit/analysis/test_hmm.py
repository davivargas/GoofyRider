from app.services.analysis.config import AnalyzerConfig
from app.services.analysis.hmm import State
from app.services.analysis.hmm import decode
from app.services.analysis.lift_matching import LiftSpan
from app.services.analysis.signal import condition
from tests.unit.analysis.helpers import climb
from tests.unit.analysis.helpers import descent
from tests.unit.analysis.helpers import point
from tests.unit.analysis.helpers import standstill

CONFIG = AnalyzerConfig()


def _states(points, anchored=()):
    frame = condition(points, CONFIG)
    assert frame is not None
    return decode(frame, list(anchored), CONFIG)


def _share(states, state, lo, hi):
    window = states[lo:hi]
    return sum(1 for s in window if s == state) / len(window)


def test_steady_descent_is_descent() -> None:
    states = _states(descent(0, 120))
    assert _share(states, State.DESCENT, 5, 115) == 1.0


def test_a_forty_second_stop_inside_a_descent_is_a_stop() -> None:
    points = (
        descent(0, 60)
        + standstill(60, 40, north=-472.0, alt=823.0)
        + descent(100, 60, north0=-472.0, alt0=823.0)
    )
    states = _states(points)
    assert _share(states, State.DESCENT, 5, 50) == 1.0
    assert _share(states, State.STOP, 68, 92) == 1.0
    assert _share(states, State.DESCENT, 110, 155) == 1.0


def test_a_single_slow_second_does_not_flicker_to_stop() -> None:
    points = descent(0, 120)
    points[60] = point(60, north_m=-480.0, altitude_m=820.0, speed_mps=0.2)
    states = _states(points)
    assert _share(states, State.DESCENT, 50, 70) == 1.0


def test_sparse_stationary_samples_decode_as_one_stop() -> None:
    points = (
        descent(0, 60)
        + standstill(60, 600, north=-472.0, alt=823.0, every_s=25)
        + descent(660, 60, north0=-472.0, alt0=823.0)
    )
    states = _states(points)
    assert _share(states, State.STOP, 70, 650) == 1.0


def test_slow_straight_climb_is_a_fallback_lift() -> None:
    states = _states(
        standstill(0, 30, north=0.0, alt=700.0) + climb(30, 200, speed=2.5, gain_per_s=0.5)
    )
    assert _share(states, State.LIFT, 45, 220) >= 0.95


def test_anchored_seconds_are_lift_regardless_of_features() -> None:
    states = _states(descent(0, 120), anchored=[LiftSpan(20, 80, "X", None)])
    assert _share(states, State.LIFT, 20, 81) == 1.0
    assert _share(states, State.DESCENT, 85, 115) == 1.0


def test_long_moving_gap_is_unknown() -> None:
    points = descent(0, 30) + descent(230, 30, north0=-1840.0, alt0=310.0)
    states = _states(points)
    assert _share(states, State.UNKNOWN, 35, 225) == 1.0
