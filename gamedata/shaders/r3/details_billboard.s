-- Far-LOD grass billboards.
-- Same deferred grass material as details\blend, but the vertex shader (deffer_grass_bb)
-- expands a shared upright quad into a Y-axis camera-facing billboard. The pixel shader
-- is the stock deffer_grass PS, so far billboards light / pack into the G-buffer exactly
-- like the full clusters. One shared texture is bound for the whole far field (the engine
-- creates this shader once with a detail object's own grass diffuse), so the _bump path
-- resolves the same way it does for real grass.
function normal		(shader, t_base, t_second, t_detail)
	shader:begin	("deffer_grass_bb","deffer_grass")
	: fog (false)
	shader:dx10stencil	( 	true, cmp_func.always,
							255 , 127,
							stencil_op.keep, stencil_op.replace, stencil_op.keep)
	shader:dx10stencil_ref	(1)
	shader:dx10cullmode	(1)

	local	opt = shader:dx10Options()

	shader:dx10texture("s_base",	t_base)
	shader:dx10texture("s_bump",	"levels\\" .. opt:getLevel() .. "\\" .. t_base.."_bump")
	shader:dx10texture("s_bumpX",	t_base.."_bump#")

	shader:dx10texture("s_waves",	"fx\\wind_wave")

	shader:dx10sampler("smp_base")
	shader:dx10sampler("smp_linear")
	shader:dx10sampler("smp_linear2")
end
