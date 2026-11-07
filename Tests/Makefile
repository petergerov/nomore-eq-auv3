CXX ?= clang++
CXXFLAGS = -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter
FRAMEWORKS = -framework Accelerate -framework AudioToolbox
BUILD = ../build/tests

.PHONY: test clean

test: $(BUILD)/dsp_test
	$(BUILD)/dsp_test $(ARGS)

$(BUILD)/dsp_test: dsp_test.cpp $(wildcard ../Shared/DSP/*)
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) dsp_test.cpp -o $@ $(FRAMEWORKS)

clean:
	rm -rf $(BUILD)
