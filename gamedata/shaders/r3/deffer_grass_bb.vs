// Far-LOD grass billboard vertex shader.
//
// Expands a shared upright unit quad (slot 0: v_detail, x in [-0.5,0.5], y in [0,1]) into
// a Y-axis (cylindrical) camera-facing billboard, sized and placed by the per-instance
// stream the engine fills for distant grass (slot 1, same 64-byte record as the cluster
// instancing path):
//   m0/m1/m2 = 3x4 world transform rows (translation in .w, scale baked into the rotation),
//   c0       = colour (xyz sun, w hemi),
//   data     = terrain normal (xyz) + grass alpha / dither-fade (w).
//
// Output is v2p_bumped so the stock deffer_grass pixel shader lights and packs the
// billboard into the G-buffer exactly like a real cluster. No wind (far field).

#include "common.h"
#include "check_screenspace.h"
#include "screenspace_mvectors.h"

uniform float4 ssfx_floravariation; // Grass Int, Grass Freq, Foliage Int, Foliage Freq

float4 consts;    // {1/quant, 1/quant, 1/quant, 1} - consts.x decodes the quad's quantized UV
float4 bb_params; // {width_scale, height_scale, 0, 0} (multiplied by per-instance scale)

v2p_bumped 	main (v_detail v,
                  float4 m0 : TEXCOORD1, float4 m1 : TEXCOORD2, float4 m2 : TEXCOORD3,
                  float4 c0 : TEXCOORD4, float4 data : TEXCOORD5)
{
	v2p_bumped 		O;

	// Instance pivot (world) and the uniform scale baked into the transform rows.
	float3 T = float3(m0.w, m1.w, m2.w);
	float  s = length(float3(m0.x, m1.x, m2.x));

	float W = s * bb_params.x; // billboard width
	float H = s * bb_params.y; // billboard height

	// Y-axis billboard: keep upright, rotate only around world-up to face the camera.
	float3 toCam = eye_position.xyz - T;
	toCam.y = 0.0f;
	float  lenXZ = length(toCam);
	float3 fwd   = lenXZ > 1e-4f ? toCam / lenXZ : float3(0, 0, 1);
	float3 right = normalize(cross(float3(0, 1, 0), fwd));

	float cornerX = v.pos.x; // -0.5 .. 0.5
	float cornerY = v.pos.y; //  0   .. 1
	float vH      = cornerY * H; // height of this vertex above the pivot

	float4 pos = float4(T + right * (cornerX * W) + float3(0, 1, 0) * vH, 1.0f);

	// Terrain normal -> eye space, packed into the PS transform exactly like deffer_grass.
	float3 N = mul((float3x3)m_WV, data.xyz);

	float3x3 xform = 0;
	xform[0].z = N.x;
	xform[1].z = N.y;
	xform[2].z = N.z;
	xform[0].x = data.w; // alpha (dither fade-in)

	O.M1 = xform[0];
	O.M2 = xform[1];
	O.M3 = xform[2];

	float  hemi = clamp(c0.w, 0.05f, 1.0f);
	float3 Pe   = mul(m_V, pos);
	O.tcdh      = float4((v.misc * consts).xyyy);
	O.hpos      = mul(m_VP, pos);
	O.position  = float4(Pe, hemi);

	// Motion vectors: no wind, so previous-frame world position == current.
	O.vel_curr = O.hpos;
	O.vel_prev = mul(m_vp_prev, pos);

	// sss_extra.x = 1 marks this as a LOD1 billboard (0 = LOD0 cluster) for the grass LOD debug view.
	O.sss_extra = float4(1, 0, hash12(floor((T.xz + m0.xx * 2.0f) * ssfx_floravariation.y)), vH);

	// TAA jitter (vel_curr captured above is the un-jittered clip pos).
	O.hpos.xy = ssfx_taa_jitter(O.hpos);

#if defined(USE_R2_STATIC_SUN) && !defined(USE_LM_HEMI)
	O.tcdh.w = hemi * c_sun.x + c_sun.y; // (,,,dir-occlusion)
#endif

	return O;
}
FXVS;
