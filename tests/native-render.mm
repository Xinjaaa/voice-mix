// Exercise the actual HAL callback against deterministic PCM buffers, without audio hardware.
#include "../native/macos/audio.mm"
#include <cassert>
#include <iostream>
int main() {
    @autoreleasepool {
        float source[512]; for (unsigned i=0;i<512;++i) source[i]=(i%2 ? -0.4f : 0.2f);
        float dest[512] = {};
        AudioBufferList input{1, {{2, sizeof(source), source}}};
        AudioBufferList output{1, {{2, sizeof(dest), dest}}};
        Session session; session.step=.01f; session.target=.25f;
        for(int i=0;i<4;++i) render(0,nullptr,&input,nullptr,&output,nullptr,&session);
        for(unsigned i=0;i<512;++i) assert(std::abs(dest[i]-source[i]*.25f)<1e-6);
        assert(std::abs(session.outputRms.load()/session.inputRms.load()-.25f)<1e-5);
        session.target=0;
        for(int i=0;i<4;++i) render(0,nullptr,&input,nullptr,&output,nullptr,&session);
        for(float sample:dest) assert(sample==0);
        assert(session.outputRms.load()==0);
        session.target=.5f;
        for(int i=0;i<4;++i) render(0,nullptr,&input,nullptr,&output,nullptr,&session);
        assert(std::abs(session.outputRms.load()/session.inputRms.load()-.5f)<1e-5);
        Session independent; independent.target=1;
        render(0,nullptr,&input,nullptr,&output,nullptr,&independent);
        for(unsigned i=0;i<512;++i) assert(dest[i]==source[i]);
        render(0,nullptr,nullptr,nullptr,&output,nullptr,&session);
        for(float sample:dest) assert(sample==0);
        assert(session.invalidBuffers.load()>0);
        // Planar data and bounds checks use the same per-channel accessor.
        struct Planar { UInt32 count; AudioBuffer buffers[2]; } planar{2,{{1,1024,source},{1,1024,source+256}}};
        auto *list=reinterpret_cast<AudioBufferList*>(&planar);
        assert(samplePointer(list,1,8)==source+264);
        assert(samplePointer(list,2,0)==nullptr);
        assert(samplePointer(list,0,256)==nullptr);
        std::cout << "Native render: quarter/half gain, mute, independent session, planar/bounds passed\n";
    }
}
