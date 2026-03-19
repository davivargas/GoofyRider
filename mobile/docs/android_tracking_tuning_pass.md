# Android Tracking Tuning Pass

This runbook is for validating snowboard tracking behavior after mode-adaptive sampling and motion-state hardening.

## Goal

Validate that:

- Active descent samples at 1 Hz target with bursts up to 5 Hz.
- Lift classification is stable and not triggered by traverses.
- Distance and max speed are not inflated by jitter or spikes.

## Test Build

1. Build and run the app on a physical Android device with high-accuracy location enabled.
2. Keep the app in foreground during each run.
3. Record each scenario as a separate session.

## Scenarios

1. **Active descent**
   - Continuous downhill run for 60-90 seconds.
   - Expected:
     - Sample cadence clusters around 1 Hz.
     - Short bursts as fast as ~200 ms are possible.
     - Most points are `quality_class=accept` when horizontal accuracy is <= 25 m.

2. **Chair lift**
   - Ride a lift line for 60-120 seconds with steady heading.
   - Expected:
     - State converges to `lift_uphill`.
     - Heading stability does not flap with small compass jitter.

3. **Stop / idle**
   - Stand still for 30-60 seconds.
   - Expected:
     - State converges to `stopped_idle`.
     - Distance accumulation remains near zero.

4. **Recovery**
   - Temporarily block signal (indoors/pocket), then recover outdoors.
   - Expected:
     - Low-confidence/recovery state appears during degraded fixes.
     - Normal classification resumes after stable lock returns.

## Data Review

After each run, inspect session points in local DB or uploaded payloads:

- `quality_class`, `quality_reason`
- `motion_state`
- `fused_speed_mps`, `derived_speed_mps`
- `distance_delta_m`
- `accuracy_m`, `bearing_accuracy_deg`

## Pass/Fail Heuristics

- No large max-speed spikes from single-point jumps.
- No significant distance growth while stationary.
- Lift detection requires sustained uphill + stable heading.
- Descent points with ~30 m horizontal accuracy are accepted as low confidence, not full confidence.
