#ifndef DSP_CORE_H
#define DSP_CORE_H

#define _USE_MATH_DEFINES
#include <vector>
#include <cmath>
#include <complex>
#include <algorithm>
#include <numeric>
#include <string>

const int FFT_SIZE = 512;

// Data Models matching your Executive Summary
struct ScanConfig {
    double actual_fps;
    double target_rpm;
};

enum FaultType {
    NO_FAULT = 0,
    UNBALANCE = 1,
    MISALIGNMENT = 2,
    LOOSENESS = 3,
    UNMEASURABLE = 4,
    INSUFFICIENT_DATA = 5
};

struct DSPResult {
    FaultType fault;
    double dominant_frequency;
    double peak_amplitude;
    double confidence;
    std::string message;
    std::vector<double> spectrum;
};

class DSPCore {
private:
    // 1. Core FFT Implementation (Cooley-Tukey 1D)
    void computeFFT(std::vector<std::complex<double>>& x) {
        int n = x.size();
        if (n <= 1) return;

        std::vector<std::complex<double>> even(n / 2), odd(n / 2);
        for (int i = 0; i < n / 2; ++i) {
            even[i] = x[i * 2];
            odd[i] = x[i * 2 + 1];
        }

        computeFFT(even);
        computeFFT(odd);

        for (int k = 0; k < n / 2; ++k) {
            std::complex<double> t = std::polar(1.0, -2.0 * M_PI * k / n) * odd[k];
            x[k] = even[k] + t;
            x[k + n / 2] = even[k] - t;
        }
    }

    // 2. Quadratic Sub-Bin Interpolation (Solves the quantization trap)
    double interpolatePeak(const std::vector<double>& spectrum, int peak_bin) {
        if (peak_bin <= 0 || peak_bin >= spectrum.size() - 1) return peak_bin;
        
        double alpha = spectrum[peak_bin - 1];
        double beta = spectrum[peak_bin];
        double gamma = spectrum[peak_bin + 1];
        
        if (alpha <= 0 || gamma <= 0 || beta <= alpha || beta <= gamma) {
            return peak_bin; // No clear peak to interpolate
        }
        
        double delta = 0.5 * (alpha - gamma) / (alpha - 2.0 * beta + gamma);
        return peak_bin + delta;
    }

    // Helper to find peak in a ±2 bin window
    double findPeakAmplitude(const std::vector<double>& spectrum, int expected_bin, int& actual_peak_bin) {
        double max_amp = 0.0;
        actual_peak_bin = expected_bin;
        int start = std::max(1, expected_bin - 2);
        int end = std::min((int)spectrum.size() - 1, expected_bin + 2);
        
        for (int i = start; i <= end; i++) {
            if (spectrum[i] > max_amp) {
                max_amp = spectrum[i];
                actual_peak_bin = i;
            }
        }
        return max_amp;
    }

public:
    DSPResult analyze(const std::vector<double>& raw_signal, ScanConfig config) {
        DSPResult result;
        result.spectrum.resize(FFT_SIZE / 2, 0.0);

        if (raw_signal.size() < FFT_SIZE) {
            result.fault = INSUFFICIENT_DATA;
            result.message = "Need at least " + std::to_string(FFT_SIZE) + " frames.";
            return result;
        }

        // Extract the last 512 samples
        std::vector<double> signal(raw_signal.end() - FFT_SIZE, raw_signal.end());
        
        // Remove DC Bias
        double mean = std::accumulate(signal.begin(), signal.end(), 0.0) / FFT_SIZE;
        
        std::vector<std::complex<double>> complex_signal(FFT_SIZE);
        for (int i = 0; i < FFT_SIZE; i++) {
            // Apply Hann Window
            double multiplier = 0.5 * (1.0 - std::cos(2.0 * M_PI * i / (FFT_SIZE - 1)));
            complex_signal[i] = std::complex<double>((signal[i] - mean) * multiplier, 0.0);
        }

        // Execute FFT
        computeFFT(complex_signal);

        // Calculate Magnitude Spectrum (Normalized)
        double noise_sum = 0.0;
        for (int k = 0; k < FFT_SIZE / 2; k++) {
            result.spectrum[k] = std::abs(complex_signal[k]) / (FFT_SIZE / 2.0);
            noise_sum += result.spectrum[k];
        }

        double freq_resolution = config.actual_fps / FFT_SIZE;
        double nyquist = config.actual_fps / 2.0;

        // If target RPM is 0 (like in Self-Test), just find the absolute max peak
        if (config.target_rpm <= 0) {
            int max_bin = 1;
            double max_val = 0;
            for(int i = 1; i < FFT_SIZE/2; i++){
                if(result.spectrum[i] > max_val){
                    max_val = result.spectrum[i];
                    max_bin = i;
                }
            }
            double exact_bin = interpolatePeak(result.spectrum, max_bin);
            result.dominant_frequency = exact_bin * freq_resolution;
            result.peak_amplitude = max_val;
            result.fault = NO_FAULT;
            result.message = "Self-Test / Blind Scan Complete";
            return result;
        }

        // HARMONIC ANALYSIS based on Target RPM
        double f_1x = config.target_rpm / 60.0;
        
        if (f_1x >= nyquist * 0.85) {
            result.fault = UNMEASURABLE;
            result.message = "RPM exceeds Nyquist safety limit. Increase FPS.";
            return result;
        }

        int bin_1x_expected = std::round(f_1x / freq_resolution);
        int bin_2x_expected = std::round((f_1x * 2.0) / freq_resolution);
        int bin_3x_expected = std::round((f_1x * 3.0) / freq_resolution);

        int actual_bin_1x, actual_bin_2x, actual_bin_3x;
        double amp_1x = findPeakAmplitude(result.spectrum, bin_1x_expected, actual_bin_1x);
        double amp_2x = findPeakAmplitude(result.spectrum, bin_2x_expected, actual_bin_2x);
        double amp_3x = findPeakAmplitude(result.spectrum, bin_3x_expected, actual_bin_3x);

        // Calculate baseline noise floor (excluding the harmonic bins)
        double noise_floor = (noise_sum - amp_1x - amp_2x - amp_3x) / (FFT_SIZE / 2.0 - 3);
        if (noise_floor <= 0.0001) noise_floor = 0.0001;

        double r_1x = amp_1x / noise_floor;
        double r_2x = amp_2x / noise_floor;
        double r_3x = amp_3x / noise_floor;

        // Apply Sub-Bin Interpolation to the fundamental peak
        double exact_bin_1x = interpolatePeak(result.spectrum, actual_bin_1x);
        result.dominant_frequency = exact_bin_1x * freq_resolution;
        result.peak_amplitude = amp_1x;

        // Physics-Based ISO-style Fault Rules
        if (r_1x > 5.0 && r_2x < 3.0 && r_3x < 3.0) {
            result.fault = UNBALANCE;
            result.message = "WARNING: Mass Unbalance Detected (High 1X)";
        } else if (r_2x > r_1x && r_2x > 5.0) {
            result.fault = MISALIGNMENT;
            result.message = "WARNING: Shaft Misalignment (Dominant 2X)";
        } else if (r_1x > 3.0 && r_2x > 3.0 && r_3x > 3.0) {
            result.fault = LOOSENESS;
            result.message = "CRITICAL: Mechanical Looseness (Harmonic Forest)";
        } else {
            result.fault = NO_FAULT;
            result.message = "HEALTHY: Vibration within normal limits.";
        }

        return result;
    }
};

#endif // DSP_CORE_H