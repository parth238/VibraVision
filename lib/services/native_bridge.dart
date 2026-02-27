import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

enum FaultType {
  healthy,
  unbalance,
  misalignment,
  looseness,
  unmeasurable,
  insufficientData,
}

class ProcessingResult {
  final double peakFrequency;
  final double peakMagnitude;
  final double confidence;
  final FaultType faultType;
  final List<double> frequencySpectrum;
  final double actualFps;

  ProcessingResult({
    required this.peakFrequency,
    required this.peakMagnitude,
    required this.confidence,
    required this.faultType,
    required this.frequencySpectrum,
    required this.actualFps,
  });

  double get peakRpm => peakFrequency * 60.0;
  // Physically guaranteed resolution of 512-point FFT
  double get frequencyResolution => actualFps / 512.0;
}

typedef InitializeNative = Void Function();
typedef InitializeDart = void Function();
typedef ResetScanNative = Void Function();
typedef ResetScanDart = void Function();
typedef ProcessFrameNative =
    Double Function(Pointer<Uint8>, Int32, Int32, Int32);
typedef ProcessFrameDart = double Function(Pointer<Uint8>, int, int, int);
typedef GetSampleCountNative = Int32 Function();
typedef GetSampleCountDart = int Function();

// Updated to accept Target RPM
typedef FinalizeScanNative =
    Pointer<Double> Function(Double, Double, Pointer<Int32>);
typedef FinalizeScanDart =
    Pointer<Double> Function(double, double, Pointer<Int32>);
typedef FreeBufferNative = Void Function(Pointer<Double>);
typedef FreeBufferDart = void Function(Pointer<Double>);

typedef SelfTestNative =
    Pointer<Double> Function(Double, Double, Pointer<Int32>);
typedef SelfTestDart = Pointer<Double> Function(double, double, Pointer<Int32>);

class NativeBridge {
  static final NativeBridge _instance = NativeBridge._internal();
  factory NativeBridge() => _instance;

  late DynamicLibrary _lib;
  late InitializeDart _initialize;
  late ResetScanDart _resetScan;
  late ProcessFrameDart _processFrame;
  late GetSampleCountDart _getSampleCount;
  late FinalizeScanDart _finalizeScan;
  late FreeBufferDart _freeBuffer;
  late SelfTestDart _runSelfTest;

  NativeBridge._internal() {
    _loadLibrary();
  }

  void _loadLibrary() {
    if (Platform.isAndroid) {
      _lib = DynamicLibrary.open('libvibravision.so');
    } else {
      _lib = DynamicLibrary.process();
    }

    _initialize = _lib
        .lookup<NativeFunction<InitializeNative>>('initialize')
        .asFunction();
    _resetScan = _lib
        .lookup<NativeFunction<ResetScanNative>>('resetScan')
        .asFunction();
    _processFrame = _lib
        .lookup<NativeFunction<ProcessFrameNative>>('processFrame')
        .asFunction();
    _getSampleCount = _lib
        .lookup<NativeFunction<GetSampleCountNative>>('getSampleCount')
        .asFunction();
    _finalizeScan = _lib
        .lookup<NativeFunction<FinalizeScanNative>>('finalizeScan')
        .asFunction();
    _freeBuffer = _lib
        .lookup<NativeFunction<FreeBufferNative>>('freeBuffer')
        .asFunction();
    _runSelfTest = _lib
        .lookup<NativeFunction<SelfTestNative>>('runSelfTest')
        .asFunction();
  }

  void initialize() => _initialize();
  void resetScan() => _resetScan();
  int getSampleCount() => _getSampleCount();

  double processFrame(Uint8List frameData, int width, int height, int stride) {
    final Pointer<Uint8> nativeData = malloc.allocate<Uint8>(frameData.length);
    nativeData.asTypedList(frameData.length).setAll(0, frameData);
    final double mapd = _processFrame(nativeData, width, height, stride);
    malloc.free(nativeData);
    return mapd;
  }

  /// High-level API to start a scan.
  /// This handles the scanning duration and returns the final result.
  Future<ProcessingResult> startProcessing({
    required int fps,
    int targetRpm = 0,
  }) async {
    resetScan();
    // Simulate a 5-second scanning period as suggested in the requirements.
    // In a real implementation, frames would be fed via processFrame during this time.
    await Future.delayed(const Duration(seconds: 5));
    return finalizeScan(fps.toDouble(), targetRpm: targetRpm.toDouble());
  }

  ProcessingResult finalizeScan(double actualFps, {double targetRpm = 0.0}) {
    final Pointer<Int32> sizePtr = malloc.allocate<Int32>(sizeOf<Int32>());
    final Pointer<Double> resultPtr = _finalizeScan(
      actualFps,
      targetRpm,
      sizePtr,
    );
    return _parseResultArray(resultPtr, sizePtr, actualFps);
  }

  ProcessingResult runSelfTest(double fps, double targetHz) {
    final Pointer<Int32> sizePtr = malloc.allocate<Int32>(sizeOf<Int32>());
    final Pointer<Double> resultPtr = _runSelfTest(fps, targetHz, sizePtr);
    return _parseResultArray(resultPtr, sizePtr, fps);
  }

  ProcessingResult _parseResultArray(
    Pointer<Double> resultPtr,
    Pointer<Int32> sizePtr,
    double actualFps,
  ) {
    if (resultPtr == nullptr) {
      malloc.free(sizePtr);
      throw Exception('FFT analysis failed');
    }

    int idx = 0;
    final double peakFreq = resultPtr[idx++];
    final double peakMag = resultPtr[idx++];
    final double confidence = resultPtr[idx++];
    final int faultIdx = resultPtr[idx++].toInt();

    FaultType fault = FaultType.healthy;
    if (faultIdx >= 0 && faultIdx < FaultType.values.length) {
      fault = FaultType.values[faultIdx];
    }

    final int spectrumSize = resultPtr[idx++].toInt();
    final List<double> spectrum = [];
    for (int i = 0; i < spectrumSize; i++) {
      spectrum.add(resultPtr[idx++]);
    }

    _freeBuffer(resultPtr);
    malloc.free(sizePtr);

    return ProcessingResult(
      peakFrequency: peakFreq,
      peakMagnitude: peakMag,
      confidence: confidence,
      faultType: fault,
      frequencySpectrum: spectrum,
      actualFps: actualFps,
    );
  }
}
