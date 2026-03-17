# SSR False Reflections of Nearby Geometry — Debug Report

## The Bug

Standing on a mountain under tree leaves, looking at a distant lake (~100 blocks away), leaves near the camera appear "reflected" in the water. Setting `REFLECTIONS_ENABLED=0` removes the artifact, confirming it's SSR-related. DH is NOT enabled.

A secondary bug was also observed: when a falling leaf particle passes through the player's camera/POV, ALL water in the scene momentarily becomes transparent.

## Shader Pack Architecture

### Rendering Pipeline

SSR runs in **composite4.glsl** (a full-screen post-process pass). It:
1. Reads `depth0` from `depthtex0` (DEPTH_BUFFER_ALL) and `depth1` from `depthtex1` (DEPTH_BUFFER_WO_TRANS)
2. Determines if the pixel has transparent geometry: `useTransparentData = depth0 < depth1`
3. Reads normal/reflectiveness from the appropriate data texture (TRANSPARENT_DATA_TEXTURE for water, OPAQUE_DATA_TEXTURE for blocks)
4. Calls `addReflection(color, viewPos, normal, lmcoord, MAIN_TEXTURE, reflectiveness)`

Key detail: `viewPos = screenToView(vec3(texcoord, depth0))` — uses depthtex0 which includes ALL geometry.

### Depth Buffers Available

| Macro | Iris name | Contains |
|---|---|---|
| `DEPTH_BUFFER_ALL` | `depthtex0` | All geometry (terrain, cutout, transparent, handheld) |
| `DEPTH_BUFFER_WO_TRANS` | `depthtex1` | All except transparent (water, glass). **Includes cutout (leaves)** |
| `DEPTH_BUFFER_WO_TRANS_OR_HANDHELD` | `depthtex2` | All except transparent & handheld. **Still includes cutout (leaves)** |

**There is NO depth buffer that excludes cutout/alpha-tested geometry (leaves, flowers, etc.)** This is a fundamental limitation of the Iris/OptiFine depth buffer system.

### Color Buffers

| Buffer | Usage |
|---|---|
| `colortex0` (tex / MAIN_TEXTURE) | Main composited scene color. SSR reads reflected colors from here. |
| `colortex1` | Previous frame (PREV_TEXTURE) |
| `colortex2` | Opaque data (normals, lightmap, reflectiveness) |
| `colortex3` | Transparent data (normals, lightmap, reflectiveness) |
| `colortex4` | Bloom |
| `colortex5` | Sky objects |
| `colortex6` | Noisy renders |
| `colortex7` | Previous depth |
| `colortex8` | Voxy transparents |

### SSR Ray March Algorithm (reflections.glsl)

The `raytrace()` function:
1. Projects `viewPos` (water surface) and `viewPos - reflectionDir * scale` to screen space
2. Computes `stepVector = screenPos - nextScreenPos` (note: reversed direction, acknowledged in comment)
3. Clamps step to screen bounds, divides by `(REFLECTION_ITERATIONS - 8)` = 32 steps to cross screen, 8 extra for refinement
4. Adds dither offset
5. Loops 40 iterations:
   - Reads depth from `DEPTH_BUFFER_WO_TRANS_OR_HANDHELD` (depthtex2)
   - Computes `realToScreen = screenPos.z - realDepth`
   - **Hit condition**: `realToScreen > 0.0 && realToScreen < sqrt(stepVector.z) * 0.5`
   - On hit: increment hitCount, back up, halve step (binary refinement)
   - On miss: advance by stepVector
   - After 5 hits (hitCount >= 5): converged, return error=0
6. If loop exhausts: return error=1

When `error==0`: reads reflected color from `MAIN_TEXTURE` at hit position
When `error==1`: falls back to sky color

### The `sqrt(stepVector.z)` Issue

When `stepVector.z < 0` (ray depth moves toward camera), `sqrt(negative)` = NaN. The comparison `realToScreen < NaN` is always false. The hit condition NEVER triggers. These rays always return error=1 (sky fallback). This is the normal "blue zone" at steeper viewing angles — it's correct behavior (those reflections should show sky).

When `stepVector.z > 0`, `sqrt` is defined and the hit condition can trigger. This is the "red zone" near the horizon where SSR works.

### gbuffers_terrain

Writes to `/* DRAWBUFFERS:02 */` (colortex0 + colortex2).
Alpha test: `if (rawColor.a < 0.01) discard;` — cutout blocks pass this for their opaque pixels and get written to the depth buffer like any other solid block. There is no way to distinguish a leaf fragment from a stone fragment in the depth buffer.

`mc_Entity` is available (line 286) but not used for leaf detection currently.

### MODERN_BACKEND

Defined when `(MC_VERSION >= 11800 || MC_VERSION == 11605) && defined IS_IRIS`. The user is on Iris + modern MC, so this IS defined. This means normals come from `decodeNormal(data.zw)` (the data texture), NOT from screen-space derivatives `dFdx/dFdy`. So the normal-corruption theory (neighboring leaf depth corrupting dFdx) does NOT apply.

## Debug Observations (SSR_DEBUG modes added on this branch)

### SSR_DEBUG 1 (hit mask: red=hit, blue=sky fallback)
- **Without leaves nearby**: top ~50% of water (near horizon) is RED, bottom ~50% is BLUE. This is normal — shallow angles hit terrain, steep angles miss.
- **Under tree leaves**: leaf-shaped BLUE patches appear in the RED zone. Moving closer to leaves increases the blue patches. Moving away from leaves makes them disappear (all red again).

### SSR_DEBUG 3 (stepVector.z heatmap)
- Hit pixels show GREEN (stepVector.z is positive, relatively large)
- Leaf-artifact pixels show BLUE (error=1, same as non-hit)
- No color difference between normal misses and leaf-caused misses

### Key user observation
- The "More Culling" mod's "Leaves Culling" option affects the artifact. Setting it to "Fast" (more aggressive culling = fewer leaf faces rendered) **greatly reduces** the artifact.

## Root Cause Analysis

### The Mechanism

The SSR ray from a water pixel marches upward in screen space (reflection of the downward view). The ray's path passes through screen positions where **leaves are rendered between the camera and distant terrain**.

At those screen positions:
- The depth buffer (`depthtex2`) shows the **leaf depth** (e.g., 5 blocks from camera → screen depth ~0.99)
- The terrain behind the leaves is **NOT in the depth buffer** at those pixels — it's occluded by the leaf
- The SSR ray cannot converge on terrain that doesn't exist in the depth buffer

After passing the leaf zone, the ray enters sky-only territory (above the mountain/leaves). There is no terrain to converge on. The ray exhausts its iterations → error=1 → sky fallback.

The result: **leaf-shaped patches of sky fallback color** in the water where SSR should have shown terrain reflections. The pattern matches the leaf silhouette because leaves at specific screen positions block the terrain data the ray needs.

### Why it looks like "reflected leaves"

The sky fallback creates bright patches (sky color) against the darker terrain reflections (surrounding SSR hits). The brain interprets these leaf-shaped bright patches as "leaves reflected in the water." It's actually the ABSENCE of a correct reflection (sky showing through) in the exact shape of the leaves.

### Additionally: color buffer contamination (secondary artifact)

Even where the SSR ray DOES converge on terrain, if a leaf is rendered at the hit position on screen, the color buffer (`MAIN_TEXTURE`) at that position shows **leaf color, not terrain color**. The SSR reads this leaf color as the "reflected" color. This is a second, subtler artifact: terrain reflections tinted/textured with leaf colors. This cannot be distinguished in debug mode 1 (both show as RED = successful convergence).

### The particle bug

A falling leaf particle passing through the camera creates a fragment at depth ≈ 0 in `depthtex0`. In composite4:
- `depth0` ≈ 0 (particle depth)
- `depth1` = terrain depth (particles may not be in depthtex1)
- `useTransparentData = depth0 < depth1` → TRUE
- `viewPos = screenToView(texcoord, 0)` → position at the near plane
- Water data is read (reflectiveness > 0) for a pixel that is actually a particle
- SSR is applied with completely wrong viewPos

This likely explains the "all water becomes transparent" glitch — the particle corrupts the SSR input for that pixel, and if the particle covers a large screen area (very close to camera), it affects many pixels.

## What Was Tried (and why it failed)

### Attempt 1: `stepVector.z > 0.001` guard (commit 3844909)
**Idea**: Reject rays with negligible Z progression.
**Result**: ALL water became blue (no SSR hits). Screen-space Z values are much smaller than 0.001 due to NDC compression. The threshold was too aggressive.

### Attempt 2: Screen-space depth skip `realDepth < originScreenDepth * 0.5` (commit 22a5e7d)
**Idea**: Skip depth samples from geometry much closer than the water surface.
**Result**: No effect. NDC depth is highly nonlinear — leaves at 5 blocks have screen depth ~0.99, well above the 0.5 * 0.9995 ≈ 0.5 threshold. The threshold only caught geometry within ~0.1 blocks of the camera.

### Attempt 3: View-space projected threshold at 25% of water distance (commit e8301ac)
**Idea**: Project 25% of the water's view-space Z to screen space for a correct threshold.
**Result**: Made things WORSE (90% blue, was 50%). The threshold was correct for detecting leaves but the `hitCount = 0; stepVector = initialStepVector; screenPos += stepVector;` reset caused the ray to jump past terrain it was already converging on. The reset destroyed in-progress binary refinement.

### Attempt 4: Per-hit view-space distance check (commit 0bba349, current)
**Idea**: Move the existing post-convergence distance check (`hitDistSq < originDistSq * 0.04`) to every potential hit iteration. This prevents the ray from wasting refinement iterations on near-camera geometry.
**Result**: No visible improvement. The per-hit check correctly rejects leaf hits and advances the ray. But the terrain behind the leaves is NOT in the depth buffer. After passing the leaf zone, only sky remains. The ray still fails to converge.

**This is why per-hit rejection doesn't help: the problem isn't false convergence on leaves — it's that leaves REPLACE the terrain data the ray needs.**

## Potential Fix Approaches

### Approach A: Custom "leaf-free" depth buffer (proper fix)

Create a depth buffer that excludes cutout/alpha-tested geometry. The SSR would read from this buffer, effectively "seeing through" leaves to the terrain behind them.

**Implementation options:**

**A1: Write a custom depth to an unused colortex channel in gbuffers_terrain**
- Detect cutout blocks via `mc_Entity` (available at line 286) or `renderStage`
- For cutout blocks: write depth = 1.0 (far plane) to the custom channel
- For solid blocks: write `gl_FragCoord.z` to the custom channel
- Change SSR to read from this buffer
- **Challenge**: all colortex 0-8 appear to be in use. Would need to find a free slot or pack the data.
- **Challenge**: need to identify which `mc_Entity` values correspond to leaves/cutout blocks.

**A2: Separate gbuffers program for cutout blocks**
- Iris supports `gbuffers_terrain_cutout` as a separate program
- Could have this program NOT write to a custom depth buffer (or write far-plane depth)
- This is the cleanest separation but requires adding a new shader program file

**A3: Pre-process depth buffer in a composite pass before SSR**
- In composite3 (before composite4), read depthtex2 and apply a max-filter (dilation)
- Pixels where depth is much closer than neighbors → replace with max neighbor depth
- **Problem**: leaf blocks at 5 blocks distance span ~100-200 pixels. A 3x3 kernel only fills 1 pixel of edge. Would need massive kernels or multi-pass dilation.

### Approach B: Improved SSR fallback (mitigation, not fix)

Accept that some SSR rays will be blocked by leaves. Make the fallback less visible.

**B1: Multiple ray attempts**
- When error=1, try a second ray with a slightly jittered reflection direction
- May find terrain via a different screen path that avoids the leaf zone
- Cost: 2x ray march for affected pixels

**B2: Temporal reprojection**
- Use the previous frame's SSR result (via `colortex1` / PREV_TEXTURE) for pixels where the current frame fails
- If the player moved, leaves are at different screen positions, and previous frame may have valid SSR
- Requires storing per-pixel SSR success/failure and careful reprojection

**B3: Confidence-based blending**
- When the per-hit rejection fires many times during a ray march, reduce reflectionStrength for that pixel
- Smooths the transition from SSR reflection to sky fallback
- Doesn't fix the root cause but reduces visual contrast of the artifact

### Approach C: Depth dilation during ray march (compromise)

When the per-hit check rejects a near-camera hit, sample depth at neighboring screen positions (perpendicular to ray direction). If a neighbor has far-depth (terrain), use that depth for convergence.

- Cost: ~8 extra texture reads per rejected hit (~40-80 per ray)
- Effectiveness: only works at leaf EDGES where a neighbor pixel has terrain. Doesn't help at leaf centers.
- Relatively simple to implement, no pipeline changes

## Current State of the Code

### Changes on `fix/ssr-distant-geometry` branch (vs main)

**shaders/basics/setting_defines.glsl**:
- Added `#define SSR_DEBUG 0 // [0 1 2 3]`

**shaders/lib/reflections.glsl**:
- `raytrace()` signature: added `out float convergenceStepZ` parameter
- Fixed DH texcoord bug: `texcoord` → `screenPos.xy` in the DH depth blending path (lines 33, 35). This was a real bug regardless of the current issue.
- Added `originDistSq` before the loop
- Added per-hit distance check: `if (dot(hitViewPos, hitViewPos) < originDistSq * 0.04)` rejects hits on near-camera geometry and advances instead of refining
- Removed the post-convergence distance check (now redundant with per-hit check)
- Added SSR_DEBUG visualization in `addReflection()`:
  - Mode 1: red=hit, blue=miss
  - Mode 2: depth ratio heatmap (green=similar depth, red=different)
  - Mode 3: stepVector.z log-scale heatmap (green=large, red=tiny)

### What should be kept vs reverted

| Change | Keep? | Reason |
|---|---|---|
| SSR_DEBUG system | Yes | Useful for ongoing development |
| DH texcoord fix (`texcoord` → `screenPos.xy`) | **Yes** | Real bug fix, unrelated to current issue |
| Per-hit distance check | Maybe | Correct in principle, negligible cost, prevents wasted refinement. But doesn't solve the visible artifact. |
| `convergenceStepZ` out parameter | Optional | Only needed for SSR_DEBUG 3 |

## Files Reference

| File | Role |
|---|---|
| `shaders/lib/reflections.glsl` | SSR ray march + reflection blending |
| `shaders/program/composite4.glsl` | SSR invocation (determines water pixels, reads data, calls addReflection) |
| `shaders/basics/common.glsl` | Depth/texture buffer macro definitions |
| `shaders/basics/setting_defines.glsl` | User-facing settings including SSR_DEBUG |
| `shaders/program/gbuffers_terrain.glsl` | Terrain rendering (writes depth buffer + data for all solid & cutout blocks) |
| `shaders/basics/settings.glsl` | MODERN_BACKEND definition |
| `shaders/utils/projections.glsl` | screenToView and related projection utilities |

## Unverified Hypothesis

One thing that has NOT been empirically verified: **whether the per-hit distance check is actually triggering for leaf pixels.** All analysis is based on reasoning about depth values and thresholds. Adding SSR_DEBUG 4 (yellow = per-hit check fired at least once, blue = never triggered) would definitively confirm whether the hit condition triggers for leaves or not. If it doesn't trigger (all blue, no yellow), then the mechanism is purely "leaves are misses that the ray advances through" — and the per-hit check is irrelevant. The root cause (terrain not in depth buffer) remains the same either way.
