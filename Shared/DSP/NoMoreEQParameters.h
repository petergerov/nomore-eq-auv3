// NoMore EQ — parameter addresses shared by the C++ kernel and the Objective-C AU.
#pragma once

enum {
    NMEQParamRecover   = 0,  // %    0 … 100   lift masked / buried bands
    NMEQParamTame      = 1,  // %    0 … 100   pull down dominant / resonant bands
    NMEQParamBias      = 2,  // %  -100 … 100  shift the balance toward taming (-) or recovering (+)
    NMEQParamBrighten  = 3,  // %  -100 … 100  tilt the overall balance dark (-) / bright (+)
    NMEQParamLowFreq   = 4,  // Hz   20 … 2000  lower edge of the processed range
    NMEQParamHighFreq  = 5,  // Hz 1000 … 20000 upper edge of the processed range
    NMEQParamOutput    = 6,  // dB  -12 … 12   output gain
    NMEQParamSidechain = 7,  // 0/1            analyze the sidechain input (bus 1) instead of the main input
    NMEQParamBands     = 8,  // 0/1/2          32, 48 or 64 bands
    NMEQParamCount     = 9
};

static const float NMEQParamMin[NMEQParamCount]     = {   0.f,   0.f, -100.f, -100.f,   20.f,  1000.f, -12.f, 0.f, 0.f };
static const float NMEQParamMax[NMEQParamCount]     = { 100.f, 100.f,  100.f,  100.f, 2000.f, 20000.f,  12.f, 1.f, 2.f };
static const float NMEQParamDefault[NMEQParamCount] = {  40.f,  40.f,    0.f,    0.f,   30.f, 18000.f,   0.f, 0.f, 0.f };
