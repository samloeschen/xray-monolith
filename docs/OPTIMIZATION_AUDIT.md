# Optimization Audit Handoff

Last updated: 2026-08-12

## Repository State

- Active integration branch: `dev`
- Demonized upstream branch: `origin/all-in-one-vs2022-wpo-mt`
- Upstream merge commit: `fdaa9e7b`
- Shader import commit currently at HEAD: `b191452c`
- The branch contains both local optimization families:
  - Detail-grass hardware instancing and batching
  - SSFX render-target bandwidth reductions and GPU profiling
- The required optimization shaders are tracked under `gamedata/shaders/r3`.
- Root scripts `build-mt.bat`, `deploy.bat`, and `publish.bat` were added after
  `b191452c` and may still be uncommitted. See `git status` before starting work.

## Audit Scope

The audit compared the local renderer delta against
`origin/all-in-one-vs2022-wpo-mt`. It was a static code audit supplemented by
successful clean builds of these MT configurations:

- `DX10|x64`
- `DX10-AVX|x64`
- `DX11|x64`
- `DX11-AVX|x64`

No in-game RenderDoc, PIX, PresentMon, or Optick captures were collected. Impact
rankings below are therefore based on resource sizes, call frequency, and hot-path
control flow. Measure before and after each performance change.

## Recommended Work Order

1. Make render-target swaps preserve existing SRVs instead of recreating them.
2. Remove AO and IL full-resource history copies and fix `surface_get` leaks.
3. Make SMAA and SSFX TAA mutually exclusive by default.
4. Cull grass instances for sun cascades and local-light shadow passes.
5. Skip unnecessary grass packing and disabled density-falloff calculations.
6. Fix confirmed correctness issues before trusting benchmark comparisons.
7. Profile conditional blur generation, LUT/final PP fusion, sorting, and RT formats.

## SSFX Findings

### 1. RT swaps recreate SRVs on every pass

Confidence: confirmed

References:

- `src/Layers/xrRenderDX10/dx10SH_RT.cpp:211-248`
- `src/Layers/xrRenderDX10/dx10SH_Texture.cpp:66-133`

`CRT::swap_surfaces` exchanges texture resources and RTVs, then calls
`CTexture::surface_set` twice. `surface_set` releases and recreates each SRV,
performs descriptor queries, and updates texture state. This trades large GPU
copies for avoidable render-thread and driver work on every postprocess swap.

Minimal change:

- Add a user-texture swap operation that exchanges `pSurface`, `m_pSRView`, and
  cached descriptors together.
- Keep render-cache invalidation, but do not call `CreateShaderResourceView`.
- Cache compatibility metadata instead of querying both resource descriptors per
  swap.

Measure:

- `CreateShaderResourceView` calls per frame
- Render-thread time in the postprocess chain
- GPU time to confirm no copies return

Risk:

- Resource ownership and descriptor caches must remain paired.
- Do not use the path for sequence, video, or non-user textures.

### 2. AO and IL still copy full-resolution history allocations

Confidence: confirmed

References:

- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_ssao.cpp:180-221`
- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_ssao.cpp:328-367`
- `src/Layers/xrRenderPC_R4/r4_rendertarget.cpp:596-604`
- `src/Layers/xrRenderPC_R4/blender_blur.cpp:252-347`

AO and IL render in a reduced corner viewport but then call `CopyResource` on
full-resolution RGBA8 allocations. At 4K, one RGBA8 copy is about 33 MB copied,
or roughly 66 MB of read-plus-write traffic. Default IL scale is 6.66, so IL
renders about 2.25 percent of the target while still copying the full allocation.

Minimal change:

- Swap `rt_ssfx_ao` with the freshly rendered AO target and make blur phase 1
  sample logical AO history.
- Do the equivalent for `rt_ssfx_il`.
- Update the C++ blender bindings so the first blur pass follows the logical
  history target after the swap.

Measure:

- Copy-engine/resource-copy events
- AO and IL GPU phase durations at 1440p and 4K
- Scales 1, 2, 4, 6.66, and 8

Risk:

- Validate temporal history after camera cuts and resolution changes.
- Force a shader-cache rebuild after binding or define changes.

### 3. `surface_get` copy callers leak COM references

Confidence: confirmed

References:

- `src/Layers/xrRenderDX10/dx10SH_Texture.cpp:137-147`
- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_ssao.cpp:221,367`
- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_combine.cpp:333-335,370,412-459,596`
- `src/Layers/xrRender/rendertarget_phase_blur.cpp:263,421,485,637,874,902`

`CTexture::surface_get` calls `AddRef`. Multiple per-frame `CopyResource` and
`ResolveSubresource` call sites do not release returned pointers. This can retain
old render targets across resize or reset and cause long-session VRAM growth.

Minimal change:

- For render targets, use `CRT::pSurface` directly.
- Otherwise hold returned pointers and release both after the API call.
- Do not globally change `surface_get` ownership without auditing all callers.

Measure:

- D3D debug-layer live-object output
- VRAM across repeated resolution changes and renderer resets

### 4. SMAA and SSFX TAA run back-to-back by default

Confidence: confirmed behavior; visual tradeoff requires measurement

References:

- `src/Layers/xrRender/xrRender_console.cpp:45`
- `src/Layers/xrRender/xrRender_console.cpp:405`
- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_combine.cpp:582-593`
- `src/Layers/xrRender/rendertarget_phase_smaa.cpp:26-100`

SMAA defaults on and SSFX TAA defaults on. SMAA adds three full-resolution passes
and two clears immediately before TAA.

Minimal change:

- Run SMAA only when SSFX TAA is unavailable or disabled.
- Keep an explicit override only if combined AA is intentionally desired.

Measure:

- Total postprocess GPU time
- Thin-edge quality and temporal shimmer
- SMAA off/on with TAA enabled

### 5. Classic blur generation is unconditional

Confidence: confirmed behavior; consumer analysis needs runtime validation

References:

- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_combine.cpp:536-538`
- `src/Layers/xrRender/rendertarget_phase_blur.cpp:31-183`

Six blur passes generate half-, quarter-, and eighth-resolution textures every
main-viewport frame. Common consumers often need only the half-resolution level.

Potential change:

- Determine required blur levels from enabled effects.
- Skip all blur when no consumer needs it.
- Generate only the half-resolution level for DoF/fake scopes.
- Downsample hierarchically when all levels are needed.

Risk:

- External shader mods may consume blur targets in ways not visible in this repo.

### 6. LUT and final PP passes are unconditional

Confidence: confirmed behavior; integration risk is high

References:

- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_combine.cpp:553-559`
- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_combine.cpp:598-615`

`phase_lut` always runs, and `PP_Complex` is forcibly set to true. This preserves
extra full-screen passes even when camera postprocessing is effectively identity.

Potential change:

- Restore the real `u_need_PP` decision where safe.
- Render combine directly to the output when no intermediate is required.
- Fold LUT/color correction into a mandatory pass such as combine or TAA sharpen.

Risk:

- Validate UI composition, screenshots, HDR, menus, and windowed presentation.

### 7. Other replaceable SSFX history copies remain

Confidence: confirmed copies; each resource flow needs individual validation

References:

- SSR: `src/Layers/xrRender/rendertarget_phase_blur.cpp:262-263`
- Volumetrics: `src/Layers/xrRender/rendertarget_phase_blur.cpp:403-421`
- Water: `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_combine.cpp:369-373`
- SSS: `src/Layers/xrRender/rendertarget_phase_blur.cpp:637,874,902`
- Previous position: `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_combine.cpp:595-596`

SSR, water, and SSS history pairs are candidates for the same logical swap model.
Previous position is a real duplicate and likely needs a format/data redesign
rather than a simple swap.

### 8. HDAO compute cache/lifetime bugs

Confidence: confirmed correctness issues

References:

- `src/Layers/xrRenderDX10/StateManager/dx10ShaderResourceStateCache.cpp:11-44`
- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_hdao.cpp:27-43`
- `src/Layers/xrRender/R_Backend_Runtime.cpp:138-154`

The shader-resource cache does not fully reset compute-shader state, HDAO directly
clears CS SRVs without updating the cache, and references returned by
`OMGetRenderTargets` are not released. Fix this before using HDAO measurements.

### 9. Legacy SSAO viewport/resource defects

Confidence: confirmed correctness issues

References:

- `src/Layers/xrRenderPC_R4/r4_rendertarget_phase_ssao.cpp:3-9,57,103,129,163`
- `src/Layers/xrRenderPC_R4/r4_rendertarget.cpp:946-961`

A static viewport captures only the first dimensions passed, and legacy SSAO can
reference resources whose creation is disabled. Fix or disable unsupported modes
before benchmarking SSAO alternatives.

### 10. GPU profiler can perturb measurements

Confidence: confirmed API behavior

References:

- `src/Layers/xrRenderDX10/dx10EventWrapper.cpp:114-177`
- `src/Layers/xrRenderDX10/dx10EventWrapper.cpp:190-207`

Timestamp readback uses `GetData(..., 0)`, which can flush command submission.
Many timestamp queries are emitted when profiling is enabled.

Minimal change:

- Use `D3D11_ASYNC_GETDATA_DONOTFLUSH`.
- Poll only sufficiently old ring entries.
- Drop an unready sample instead of stalling.
- Add query lifecycle handling for device recreation.

Never use profiler-on FPS as the final result; compare with external tooling.

## Grass Findings

### 1. Shadow passes submit the full camera-visible instance set

Confidence: confirmed

References:

- `src/Layers/xrRender/R_sun.cpp:303-317`
- `src/Layers/xrRender/lights_render.cpp:203-219`
- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:309-325`
- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:405-408`

DX11 draws every visible grass instance for each eligible sun cascade and local
shadowed light. VS fade can collapse a blade but does not avoid vertex processing.

Minimal change:

- While filling already distance-sorted instances, record a sun-shadow eligible
  prefix count per object and variant.
- Partition instances into coarse spatial chunks for local lights and draw only
  chunks intersecting the light sphere/frustum.
- Keep one master instance buffer per frame; avoid repacking per pass initially.

Measure:

- VS invocations and submitted instance counts per shadow phase
- Grass shadow GPU duration
- Draw-call count and shadow-map occupancy
- Sun-only and many-spotlight scenes separately

Risk:

- Bounds must include blade height and wind displacement.
- Spatial chunks add draw calls and may lose on scenes with few lights.

### 2. Instance packing occurs before the outdoor visibility early-out

Confidence: confirmed

References:

- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:128-141`
- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:182-265`
- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:275-283`

The renderer maps and fills the complete instance buffer before checking whether
the outdoor sector is visible. Indoor frames can do all packing work and draw no
grass.

Minimal change:

- Check outdoor visibility before filling.
- Mark counts and frame state explicitly so later phases cannot consume stale data.
- Skip Map/Unmap entirely when the current visible count is zero.

### 3. Fixed instance capacity can drop grass

Confidence: confirmed

References:

- `src/Layers/xrRender/DetailManager.h:231-245`
- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:222-262`

The 64-byte instance record buffer is capped at 262,144 records (16 MiB). Large
radius/density configurations can overflow. Later models/variants are dropped and
the warning is logged every overflowing frame.

Minimal change:

- Add requested, written, dropped, and high-water counters.
- Rate-limit overflow logging.
- Use growable power-of-two capacity or fixed pages.

Measure at detail radii 49, 98, 160, and 250 with multiple densities.

### 4. Disabled density falloff still performs work

Confidence: confirmed

References:

- `src/Layers/xrRender/DetailManager.cpp:397-413`
- `src/Layers/xrRender/xrRender_console.cpp:132-137`

The default knee is 1.0, which disables density falloff, but every updated slot
still computes a square root and distance fraction.

Minimal change:

- Read the knee once outside the loops.
- Completely bypass sqrt/pow/hash work when `knee >= 1`.

### 5. Alpha-zero handling truncates a slot vector

Confidence: confirmed likely bug

Reference:

- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:214-225`

When an instance alpha is zero, `hw_Fill_Instances` uses `break`, dropping every
remaining instance in that slot vector. The vector is not sorted by alpha.

Minimal change:

- Change `break` to `continue`.
- Instrument zero-alpha encounters and skipped valid followers first if desired.

### 6. Visibility distance/scale can be stale for 15-30 frames

Confidence: confirmed behavior; net cost requires profiling

References:

- `src/Layers/xrRender/DetailManager.cpp:383-418`
- `src/Layers/xrRender/DetailManager.cpp:482-518`

Distance rejection, scale matrices, SSA, and stored sort distance update only when
the slot frame expires. During fast camera movement, out-of-radius grass can remain
submitted and sorting uses stale distance.

Potential change:

- Compute one current squared distance per visible slot each frame and reject
  out-of-radius slots immediately.
- Keep expensive per-blade SSA on the existing update cadence.
- Move more camera fade work to the VS over time.

### 7. Visibility/fill paths move large scattered records

Confidence: structural observation; redesign requires profiling

References:

- `src/Layers/xrRender/DetailManager.h:74-90`
- `src/Layers/xrRender/DetailManager.cpp:482-497`
- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:204-242`

Each `SlotItem` carries two matrices plus duplicated slot position/distance and
static lighting data. Fill pointer-chases large records and repacks static values
every frame.

Potential change:

- Store sort distance on the slot/slot-part.
- Prepack static normal/sun/hemi data at decompression.
- Use compact transform data for R4 before changing shared legacy structures.
- Consider visible indices into contiguous storage instead of pointers.

Measure cache misses, memory bandwidth, and bytes written per instance.

### 8. DX10 remains on legacy constant-array batching

Confidence: confirmed missed opportunity

References:

- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:415-538`
- `src/Layers/xrRenderDX10/dx10R_Backend_Runtime.h:333-361`
- `src/Layers/xrRenderDX10/dx10BufferUtils.cpp:145-157`

D3D10 supports input-stream instancing and the backend already exposes an instanced
draw path, but R3 still bakes mesh copies and uploads transform constant arrays for
every batch.

Potential change:

- Extend the stream-1 instance buffer path to `USE_DX10 || USE_DX11`.
- Retain the current baked-copy path as a fallback.
- Update and validate the DX10 shader branch.

The tracked shaders currently support DX11 instancing and DX10 legacy batching in
one shader set.

### 9. DX10 feature parity remains incomplete

Confidence: confirmed

References:

- `src/Layers/xrRenderDX10/dx10DetailManager_VS.cpp:415-538`
- `gamedata/shaders/r3/deffer_grass.vs`
- `gamedata/shaders/r3/deffer_detail_w_flat.vs`
- `gamedata/shaders/r3/deffer_detail_s_flat.vs`

The legacy R3 path does not carry the DX11 terrain-normal/alpha instance payload or
the same phase-specific VS fade behavior. Treat R3 rendering as compatibility,
not feature parity, until it is moved to real instancing.

### 10. Fast cache update erases while iterating forward

Confidence: confirmed bug

Reference:

- `src/Layers/xrRender/DetailManager_CACHE.cpp:159-168`

Erasing `cache_task[iteration]` shifts later items left and then increments the
index, skipping the moved item. It also causes repeated middle shifts.

Minimal change:

- Consume from the back, use a while loop, or swap/pop if ordering is irrelevant.
- Consider a bounded decompression budget to avoid a teleport spike.

### 11. MT synchronization can create render-thread bubbles

Confidence: structural observation; impact requires profiling

References:

- `src/Layers/xrRender/DetailManager.cpp:277-281,550-604`
- `src/xrEngine/EngineThreading.cpp:33-40`
- `src/xrEngine/device.cpp:472-475`

The critical section spans visibility/cache work, and rendering uses it as a wait
point. Shadow renders can reacquire synchronization even when frame data is ready.

Potential change:

- Add a lock-free completed-frame fast path.
- Use an explicit task/fence completion mechanism.
- Cache per-frame wind/constants so shadow calls only submit draws.
- Double-buffer visibility data before removing locking.

### 12. Sorting needs an A/B profile

Confidence: profiling-dependent

Reference:

- `src/Layers/xrRender/DetailManager.cpp:522-536`

Per-object front-to-back sorting costs CPU but can reduce alpha-tested overdraw.
Its distance values can currently be stale. Compare full sort, bucketed sort, and
no sort using CPU sort time, PS invocations, early-Z rejection, and detail GPU time.

## Additional Profiling Candidates

- Reduce the 64-byte instance record toward 32 bytes and trade fetch bandwidth for
  VS reconstruction ALU.
- Explicitly ring-buffer the 16 MiB dynamic instance VB if Map stalls are observed.
- Add shadow-only detail shaders that omit motion/lighting work not required for
  depth rendering.
- Evaluate one-sided foliage and the two-pass ATOC path.
- Use a full-screen triangle and avoid repeated dynamic four-vertex locks.
- Downscale screen-space sunshafts from full resolution.
- Reduce HDR bloom/flare iteration counts and consider R11G11B10F.
- Specialize RT formats: R8 AO, RG16F motion vectors, compact depth history, and
  narrower SMAA edge data where shader contracts permit.

## What Is Already Good

- DX11 grass uses one mesh copy and hardware instancing, substantially reducing
  draw calls and static geometry duplication.
- The instance buffer is filled once per frame and reused by normal and shadow
  phases.
- The 64-byte record keeps transforms at full precision and packs static values as
  half floats.
- Visibility vectors preserve capacity with `clear_not_free`, avoiding routine
  steady-state allocation churn.
- Hierarchical grass culling includes cache spheres, slot spheres, HOM, radius,
  SSA, and stable stochastic rejection.
- The SSFX logical render-target ping-pong model is sound for current compatible
  resource pairs and removes many full-screen copies.
- AO blur passes 1-3 and the full IL blur chain run in the reduced corner domain.
- The GPU profiler is off by default and uses a frame ring rather than an explicit
  blocking wait loop.

## Shader Contract Notes

Tracked optimization shaders:

- `gamedata/shaders/r3/deffer_grass.vs`
- `gamedata/shaders/r3/deffer_detail_w_flat.vs`
- `gamedata/shaders/r3/deffer_detail_s_flat.vs`
- `gamedata/shaders/r3/deffer_grass_bb.vs`
- `gamedata/shaders/r3/details_billboard.s`
- `gamedata/shaders/r3/ssfx_ao.ps`
- `gamedata/shaders/r3/ssfx_ao_blur.ps`

The three active detail vertex shaders match the engine's stream-1 semantics:

- `TEXCOORD1-3`: three float4 transform rows
- `TEXCOORD4`: half4 terrain normal plus alpha
- `TEXCOORD5`: half4 sun/hemi plus spare values
- Total instance stride: 64 bytes

The detail shaders include DX10 legacy constant-array branches. The billboard
shader pair appears currently unreferenced by engine code and should be treated as
an experiment until its C++ path is restored or implemented.

AO shaders depend on the engine-defined `SSFX_AO_SCALED_BLUR` compile define.
Delete the shader cache whenever changing these shaders or their C++ bindings.

## Build And Package Notes

- `build-mt.bat` builds only DX10/DX11 MT normal and AVX configurations.
- `deploy.bat` defaults to:
  - Anomaly root: `D:\anomaly`
  - Shader mod: `D:\gamma\mods\Sam's Optimization Patches (Shaders)`
- `publish.bat` produces an outer ZIP containing:
  - `Sam-Optimization-Patches-MT-Executables.zip`
  - `Sam-Optimization-Patches-Shaders.zip`
  - `INSTALL.txt`
- Default publish output: `_build/publish`
- Publish forces a clean rebuild; deploy uses incremental builds.
- The scripts were verified using temporary deployment roots and nested ZIP
  inspection. Copied executables and shaders matched source SHA-256 hashes.

## Suggested Benchmark Matrix

Use fixed save files, camera routes, weather, resolution, and settings. Record CPU
and GPU frame time separately rather than reporting FPS alone.

Scenarios:

1. Dense outdoor grass, no grass shadows
2. Dense outdoor grass, sun grass shadows
3. Dense grass with many local shadowed lights
4. Indoor/portal-heavy scene where outdoor sector is not visible
5. Fast sprint or vehicle movement through detail cache boundaries
6. SSFX AO only at scales 1, 2, 4, and 8
7. SSFX IL at default scale 6.66
8. TAA only versus SMAA plus TAA
9. Full postprocess chain at 1080p, 1440p, and 4K
10. Repeated resolution changes and renderer resets for leak detection

Tools and counters:

- PresentMon for external frame pacing
- PIX or RenderDoc for pass timings, copies, draw counts, and resource inspection
- Optick for render-thread and detail-worker overlap
- D3D11 debug layer for resource hazards and live-object reporting
- VS/PS invocations, early-Z rejection, bytes copied, instance counts, Map duration,
  cache misses, and memory bandwidth where available

## First New-Session Prompt

Suggested continuation request:

> Read `OPTIMIZATION_AUDIT.md`, inspect the current git status, and implement the
> first SSFX optimization: preserve SRVs during compatible render-target swaps.
> Add debug assertions for incompatible resource descriptors, build all four MT
> configurations, and describe an in-game measurement plan.
