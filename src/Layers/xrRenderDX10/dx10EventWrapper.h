#pragma once

#define PIX_EVENT(Name) dxPixEventWrapper pixEvent##Name(L#Name)

class dxPixEventWrapper
{
public:
    dxPixEventWrapper(LPCWSTR wszName);
    ~dxPixEventWrapper();
#ifdef USE_DX11
private:
    int m_timerId; // GPU profiler scope id, -1 when profiling disabled
#endif
};

#ifdef USE_DX11
//  very basic gpu profiler (enable with r__gpu_prof 1). Uses d3d11 timestamp queries via PIX_EVENT.
namespace GpuProf
{
	void OnFrameBegin();	// called from CBackend::OnFrameBegin
	void OnFrameEnd();		// called from CBackend::OnFrameEnd
	int ScopeBegin(LPCWSTR name);
	void ScopeEnd(int id);
}
#endif
