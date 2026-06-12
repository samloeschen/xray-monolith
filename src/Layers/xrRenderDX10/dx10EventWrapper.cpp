#include "stdafx.h"
#pragma hdrstop
#include "dx10EventWrapper.h"
#include "../xrRender/HW.h"
#include "../xrRender/xrRender_console.h"

dxPixEventWrapper::dxPixEventWrapper(LPCWSTR wszName)
{
    if (HW.pAnnotation)
        HW.pAnnotation->BeginEvent(wszName);
#ifdef USE_DX11
    m_timerId = GpuProf::ScopeBegin(wszName);
#endif
}

dxPixEventWrapper::~dxPixEventWrapper()
{
#ifdef USE_DX11
    GpuProf::ScopeEnd(m_timerId);
#endif
    if (HW.pAnnotation)
        HW.pAnnotation->EndEvent();
}

#ifdef USE_DX11

#include <string>

namespace GpuProf
{
	static const u32 MAX_SCOPES = 256;		// PIX scopes per frame we can time
	static const u32 FRAME_RING = 4;		// frames in flight before readback
	static const u32 DUMP_INTERVAL = 200;	// harvested frames between log dumps
	static const double DUMP_MIN_MS = 0.03;	// don't log scopes cheaper than this

	struct Scope
	{
		LPCWSTR name;
		ID3D11Query* qBegin;
		ID3D11Query* qEnd;
	};

	struct Frame
	{
		ID3D11Query* qDisjoint;
		Scope scopes[MAX_SCOPES];
		u32 count;
		BOOL pending;
	};

	static Frame s_frames[FRAME_RING];
	static u32 s_slot = 0;
	static Frame* s_current = nullptr;	// non-null only while recording a frame
	static bool s_created = false;
	static bool s_broken = false;		// query creation failed - stay off

	struct Stat
	{
		double ms;
		u32 hits;
	};
	static xr_map<std::wstring, Stat> s_stats;
	static u32 s_framesAccum = 0;

	static bool create_queries()
	{
		D3D11_QUERY_DESC qd;
		qd.MiscFlags = 0;
		for (u32 f = 0; f < FRAME_RING; ++f)
		{
			Frame& F = s_frames[f];
			qd.Query = D3D11_QUERY_TIMESTAMP_DISJOINT;
			if (FAILED(HW.pDevice->CreateQuery(&qd, &F.qDisjoint)))
				return false;
			qd.Query = D3D11_QUERY_TIMESTAMP;
			for (u32 i = 0; i < MAX_SCOPES; ++i)
			{
				if (FAILED(HW.pDevice->CreateQuery(&qd, &F.scopes[i].qBegin)) ||
					FAILED(HW.pDevice->CreateQuery(&qd, &F.scopes[i].qEnd)))
					return false;
			}
			F.count = 0;
			F.pending = FALSE;
		}
		return true;
	}

	static void dump()
	{
		if (!s_framesAccum || s_stats.empty())
			return;

		xr_vector<std::pair<double, std::wstring>> sorted;
		sorted.reserve(s_stats.size());
		for (auto& it : s_stats)
			sorted.emplace_back(it.second.ms / double(s_framesAccum), it.first);
		std::sort(sorted.begin(), sorted.end(),
			[](const auto& a, const auto& b) { return a.first > b.first; });

		Msg("* GPU profile @ %ux%u, avg over %u frames (note: parent scopes include children):",
			Device.dwWidth, Device.dwHeight, s_framesAccum);
		for (auto& e : sorted)
		{
			if (e.first < DUMP_MIN_MS)
				break;
			const Stat& st = s_stats[e.second];
			Msg("*   %6.3f ms  x%-3u  %S", e.first, st.hits / s_framesAccum, e.second.c_str());
		}

		s_stats.clear();
		s_framesAccum = 0;
	}

	//	Returns true when the frame's data was consumed (or dropped).
	static bool harvest(Frame& F, bool force_drop)
	{
		D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj;
		HRESULT hr = HW.pContext->GetData(F.qDisjoint, &dj, sizeof(dj), 0);
		if (S_OK != hr)
		{
			if (force_drop)
				F.pending = FALSE;
			return force_drop;
		}
		F.pending = FALSE;

		if (dj.Disjoint || !dj.Frequency)
			return true;

		for (u32 i = 0; i < F.count; ++i)
		{
			UINT64 t0, t1;
			if (S_OK != HW.pContext->GetData(F.scopes[i].qBegin, &t0, sizeof(t0), 0)) continue;
			if (S_OK != HW.pContext->GetData(F.scopes[i].qEnd, &t1, sizeof(t1), 0)) continue;
			if (t1 < t0) continue;

			Stat& st = s_stats[F.scopes[i].name];
			st.ms += double(t1 - t0) / double(dj.Frequency) * 1000.0;
			st.hits++;
		}
		s_framesAccum++;
		if (s_framesAccum >= DUMP_INTERVAL)
			dump();
		return true;
	}

	void OnFrameBegin()
	{
		s_current = nullptr;

		//	Collect whatever is ready, independent of the enable state, so
		//	in-flight frames drain after the cvar is switched off.
		for (u32 f = 0; f < FRAME_RING; ++f)
			if (s_frames[f].pending)
				harvest(s_frames[f], false);

		if (!ps_r4_gpu_prof || s_broken || !HW.pDevice || !HW.pContext)
			return;

		if (!s_created)
		{
			if (!create_queries())
			{
				s_broken = true;
				Msg("! GpuProf: timestamp query creation failed, profiler disabled");
				return;
			}
			s_created = true;
		}

		Frame& F = s_frames[s_slot];
		if (F.pending && !harvest(F, true))
			return; // shouldn't happen (force_drop), stay off this frame

		F.count = 0;
		HW.pContext->Begin(F.qDisjoint);
		s_current = &F;
	}

	void OnFrameEnd()
	{
		if (!s_current)
			return;
		HW.pContext->End(s_current->qDisjoint);
		s_current->pending = TRUE;
		s_current = nullptr;
		s_slot = (s_slot + 1) % FRAME_RING;
	}

	int ScopeBegin(LPCWSTR name)
	{
		Frame* F = s_current;
		if (!F || F->count >= MAX_SCOPES)
			return -1;
		const int id = int(F->count++);
		F->scopes[id].name = name;
		HW.pContext->End(F->scopes[id].qBegin);
		return id;
	}

	void ScopeEnd(int id)
	{
		Frame* F = s_current;
		if (!F || id < 0)
			return;
		HW.pContext->End(F->scopes[id].qEnd);
	}
}

#endif // USE_DX11
