# Controller design and stability argument (roadmap 2.4)

Implementation: `model/enh.py` (float) and `model/pipeline_int.py` (bit-accurate). Constants below are the integer-model values.

## What is regulated
One scalar, the tone-curve gain G, in the log2 domain (`lg`, Q12), once per frame, from the **measured mean of the tone-mapped output**
of the frame just finished (feedback, not feed-forward from the input). New parameters take effect at the first active pixel of the next
frame (one frame of delay, Architecture decision 3).

```
e      = log2(TARGET) - log2(mean_out)                 TARGET = 128
step   = 0                         if |e| < 0.072 log2 (5% deadband)
       = clip(e / 2, -0.58, +0.29) otherwise            k = 0.5, rate limit -0.40 / +0.20 ln per frame
lg    <- clip(lg + step, 0, min(6, log2(255) - log2(max(p99 - B, 8))))   G in [1, 64], p99 headroom clamp
```
The clamp is applied to the state itself every frame (no integrator wind-up).
Black level B = min(p1, 16). Denoise and sharpen strengths are functions of the predicted output noise (coupling, `enh.py` docstring);
they do not feed back into G except through the small change of mean luma that denoising causes.

## Stability
Plant: output mean m(G) = mean over pixels of 255*clip(G(v-B)/255, 0, 1)^gamma. Away from clipping, m is proportional to G^gamma, so
`d ln m / d ln G = gamma_eff` with `0 < gamma_eff <= gamma = 0.4` (clipping only lowers it).

For a static scene the loop is a first-order discrete system with one frame of delay in the actuation:

    e[n+1] = (1 - k * gamma_eff) * e[n]

* stable iff `0 < k*gamma_eff < 2`; monotone with no overshoot iff `k*gamma_eff <= 1`.
* tuned design: `k*gamma_eff <= 0.2`, contraction 0.8 per frame, time constant about 4.5 frames (0.08 s at 60 Hz) before the rate
  limiter and deadband act; the rate limiter bounds the worst case: a 10x scene change is absorbed in about 8 frames.
* `k = 5` gives `k*gamma_eff = 2`, the stability boundary: sustained two-frame oscillation. Measured in
  `docs/results/step_response_moderate.png` (flicker 39 grey levels/frame, gain alternating between two values every frame).

Why the deadband and the rate limit exist anyway: the measured mean contains moving-object and noise fluctuations of a few percent.
Without a deadband those become gain dither (visible as pumping); the price is a steady-state brightness error of up to +/-5%.
The p99 clamp is a saturating nonlinearity (it can only reduce G), so it cannot destabilise the linear loop above.

## Known limitations
* The noise estimate used by the coupling is an image-wide Immerkaer estimate; texture biases it upward in busy, bright scenes.
* Scene cuts: the first frame after a cut is processed with the old gain (one frame of delay); the temporal stage resets per pixel through
  the motion measure, the gain re-converges in a few frames.
* Settling metric in `scripts/phase2_stepresponse.py` uses a 10% band that the deadband partly overlaps; tighten to the deadband before quoting.
