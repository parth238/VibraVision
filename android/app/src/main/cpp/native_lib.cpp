#include <stdint.h>
#include <vector>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <numeric>
#include <opencv2/opencv.hpp>
#include "dsp_core.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define FFI_EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))

static std::vector<double> signal_buffer;
static cv::Mat prev_gray;

FFI_EXPORT void initialize() {
    signal_buffer.clear();
    signal_buffer.reserve(1024);
}

FFI_EXPORT void resetScan() {
    signal_buffer.clear();
    prev_gray = cv::Mat();
}

// 1. Motion Extraction: MAPD (Mean Absolute Pixel Difference)
FFI_EXPORT double processFrame(uint8_t* input_bytes, int width, int height, int stride) {
    cv::Mat gray(height, width, CV_8UC1, input_bytes, stride);
    double mapd = 0.0;
    
    if (!prev_gray.empty()) {
        cv::Mat diff;
        cv::absdiff(gray, prev_gray, diff);
        mapd = cv::mean(diff)[0];
        signal_buffer.push_back(mapd);
    }
    
    gray.copyTo(prev_gray);
    return mapd;
}

FFI_EXPORT int32_t getSampleCount() {
    return static_cast<int32_t>(signal_buffer.size());
}

// 2. Pass to DSPCore and Serialize for Dart
FFI_EXPORT double* finalizeScan(double actual_fps, double target_rpm, int32_t* out_size) {
    if (signal_buffer.empty()) {
        *out_size = 0;
        return nullptr;
    }
    
    DSPCore dsp;
    ScanConfig config;
    config.actual_fps = actual_fps;
    config.target_rpm = target_rpm;
    
    DSPResult result = dsp.analyze(signal_buffer, config);
    
    std::vector<double> output;
    output.push_back(result.dominant_frequency);
    output.push_back(result.peak_amplitude);
    output.push_back(result.confidence);
    output.push_back(static_cast<double>(result.fault));
    
    output.push_back(static_cast<double>(result.spectrum.size()));
    for (double val : result.spectrum) {
        output.push_back(val);
    }
    
    double* result_array = (double*)malloc(output.size() * sizeof(double));
    std::copy(output.begin(), output.end(), result_array);
    
    *out_size = static_cast<int32_t>(output.size());
    return result_array;
}

// 3. The Honest Self-Test (Injects a perfect synthetic sine wave)
FFI_EXPORT double* runSelfTest(double fps, double target_hz, int32_t* out_size) {
    signal_buffer.clear();
    for(int i = 0; i < FFT_SIZE; i++) {
        double t = i / fps;
        signal_buffer.push_back(std::sin(2.0 * M_PI * target_hz * t));
    }
    return finalizeScan(fps, 0.0, out_size); // 0.0 RPM forces blind peak search
}

FFI_EXPORT void freeBuffer(double* ptr) {
    if (ptr != nullptr) free(ptr);
}