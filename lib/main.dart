import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:async';
import 'services/native_bridge.dart';
import 'package:http/http.dart' as http; // NEW: HTTP package for GenTwin
import 'dart:convert'; // NEW: JSON encoding for GenTwin

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('baselines');

  try {
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera Error: $e');
  }

  NativeBridge().initialize();

  runApp(
    MaterialApp(
      home: const VisionScreen(),
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.cyanAccent,
          secondary: Colors.cyanAccent,
          surface: Color(0xFF1A1A1A),
        ),
      ),
    ),
  );
}

class VisionScreen extends StatefulWidget {
  const VisionScreen({Key? key}) : super(key: key);
  @override
  State<VisionScreen> createState() => _VisionScreenState();
}

class _VisionScreenState extends State<VisionScreen>
    with TickerProviderStateMixin {
  CameraController? _controller;
  bool _isRecording = false;
  bool _isProcessingFrame = false; // Mutex lock so C++ doesn't choke
  bool _isStreamStopped = false; // Guard against double stopImageStream
  int _selectedFps = 60;
  final TextEditingController _rpmController = TextEditingController();

  // --- GENTWIN API VARIABLES ---
  bool _isSyncing = false;
  double _finalPeakFrequency = 0.0;
  double _finalIntensity = 0.0;

  ProcessingResult? _finalResult;

  // Blinking ANALYZING indicator
  late AnimationController _blinkController;
  late Animation<double> _blinkAnimation;

  // Variables for the Triple-Tap Secret Test
  int _tapCount = 0;
  Timer? _tapTimer;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    // Set up blink animation: 0.8s repeat for the ANALYZING indicator
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _blinkAnimation = Tween<double>(begin: 0.1, end: 1.0).animate(
      CurvedAnimation(parent: _blinkController, curve: Curves.easeInOut),
    );
  }

  Future<void> _initializeCamera() async {
    if (_cameras.isEmpty) return;
    _controller = CameraController(
      _cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await _controller!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Camera init error: $e");
    }
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _controller?.dispose();
    _rpmController.dispose();
    _tapTimer?.cancel();
    super.dispose();
  }

  void _resetToPreview() {
    setState(() {
      _finalResult = null;
      _isRecording = false;
    });
  }

  // ==========================================
  // GENTWIN AI: TELEMETRY SYNC HTTP POST
  // ==========================================
  Future<void> _syncToGenTwin() async {
    setState(() => _isSyncing = true);

    // 🔴 BRUTALLY HONEST WARNING: Change this IP to your laptop's actual Wi-Fi IPv4 address!
    // If you leave it as 192.168.X.X, the app will crash when you hit the button.
    final String backendUrl = 'http://10.121.3.156:3000/api/telemetry';

    try {
      final response = await http.post(
        Uri.parse(backendUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'frequency': _finalPeakFrequency,
          'intensity': _finalIntensity,
        }),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Telemetry Sent to GenTwin Dashboard!'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        debugPrint('[-] GenTwin Server Error: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '❌ Network Error: Is the GenTwin Node server running?',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  // =========================================================================
  // 1. THE TRIPLE TAP LOGIC (Restored)
  // =========================================================================
  void _onTitleTapped() {
    _tapCount++;
    if (_tapTimer != null && _tapTimer!.isActive) _tapTimer!.cancel();

    // Reset tap count if 1.5 seconds pass (spec requirement)
    _tapTimer = Timer(const Duration(milliseconds: 1500), () {
      _tapCount = 0;
    });

    if (_tapCount == 3) {
      _tapCount = 0;
      _runSecretSelfTest();
    }
  }

  Future<void> _runSecretSelfTest() async {
    setState(() => _isRecording = true);

    // Fake 1.5 second delay so the UI shows it "processing"
    await Future.delayed(const Duration(milliseconds: 1500));

    // Inject perfect 5.0 Hz synthetic wave at exactly 60 fps (spec requirement)
    final result = NativeBridge().runSelfTest(60.0, 5.0);

    if (mounted) {
      setState(() {
        _finalResult = result;
        // UPDATE GENTWIN VARIABLES
        _finalPeakFrequency = result.peakFrequency;
        _finalIntensity = result.peakMagnitude;
        _isRecording = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("BOSS LEVEL VALIDATION: 5.0Hz Synthetic Wave Injected"),
          backgroundColor: Colors.purpleAccent,
        ),
      );
    }
  }

  // =========================================================================
  // 2. THE REAL CAMERA SCANNING LOGIC (Fixed)
  // =========================================================================
  Future<void> _startRealScan() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isRecording) return;

    setState(() {
      _isRecording = true;
      _isStreamStopped = false;
    });

    // Tell C++ to clear old memory
    NativeBridge().resetScan();

    final int startMillis = DateTime.now().millisecondsSinceEpoch;

    try {
      // Start streaming live pixels from the camera
      await _controller!.startImageStream((CameraImage image) async {
        // Mutex: skip if C++ is still crunching, or stream already done
        if (_isProcessingFrame || _isStreamStopped) return;
        _isProcessingFrame = true;

        // Pass the grayscale Y-channel directly into your C++ engine
        NativeBridge().processFrame(
          image.planes[0].bytes,
          image.width,
          image.height,
          image.planes[0].bytesPerRow,
        );

        // Ask C++ if it has reached the 512-sample limit
        final int currentSamples = NativeBridge().getSampleCount();

        if (currentSamples >= 512) {
          // Raise the guard before awaiting to prevent re-entry
          _isStreamStopped = true;
          await _controller!.stopImageStream();

          final int endMillis = DateTime.now().millisecondsSinceEpoch;

          // Spec-correct FPS: exactly 512 samples divided by elapsed seconds
          final double elapsedSeconds = (endMillis - startMillis) / 1000.0;
          final double actualFps = 512.0 / elapsedSeconds;
          final double targetRpm = double.tryParse(_rpmController.text) ?? 0.0;

          // Finalize the FFT math
          final result = NativeBridge().finalizeScan(
            actualFps,
            targetRpm: targetRpm,
          );

          if (mounted) {
            setState(() {
              _finalResult = result;
              // UPDATE GENTWIN VARIABLES
              _finalPeakFrequency = result.peakFrequency;
              _finalIntensity = result.peakMagnitude;
              _isRecording = false;
            });
          }
        }
        _isProcessingFrame = false;
      });
    } catch (e) {
      debugPrint("Scan error: $e");
      if (mounted) setState(() => _isRecording = false);
    }
  }

  Map<String, Object> _getFaultDetails(FaultType type) {
    switch (type) {
      case FaultType.unbalance:
        return {
          "color": Colors.yellow,
          "text": "WARNING: Mass Unbalance (Dominant 1X)",
        };
      case FaultType.misalignment:
        return {
          "color": Colors.orangeAccent,
          "text": "WARNING: Shaft Misalignment (Dominant 2X)",
        };
      case FaultType.looseness:
        return {
          "color": Colors.redAccent,
          "text": "CRITICAL: Mechanical Looseness Detected",
        };
      case FaultType.unmeasurable:
        return {
          "color": Colors.red,
          "text": "ERROR: RPM exceeds Nyquist safety limit",
        };
      case FaultType.insufficientData:
        return {
          "color": Colors.grey,
          "text": "ERROR: Insufficient data samples captured",
        };
      default:
        return {
          "color": Colors.greenAccent,
          "text": "HEALTHY: Vibration within normal limits",
        };
    }
  }

  Widget _buildMetric(String label, String value, Color valueColor) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 10,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildResultsCard() {
    final box = Hive.box('baselines');
    String machineKey =
        "motor_${_rpmController.text.isNotEmpty ? _rpmController.text : 'default'}";
    double? savedBaseline = box.get(machineKey) as double?;
    double currentAmplitude = _finalResult!.peakMagnitude;

    bool hasBaseline = savedBaseline != null;
    double percentageChange = 0.0;
    if (hasBaseline) {
      percentageChange =
          ((currentAmplitude - savedBaseline) / savedBaseline) * 100;
    }

    final faultUI = _getFaultDetails(_finalResult!.faultType);
    final Color faultColor = faultUI["color"] as Color;
    final String faultText = faultUI["text"] as String;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: faultColor.withOpacity(0.5)),
        boxShadow: const [
          BoxShadow(color: Colors.black87, blurRadius: 20, spreadRadius: 5),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: faultColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                faultText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: faultColor,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),

          if (hasBaseline) ...[
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: percentageChange > 50
                    ? Colors.red.withOpacity(0.2)
                    : Colors.green.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  const Text(
                    "RELATIVE DEGRADATION",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    percentageChange >= 0
                        ? "+${percentageChange.toStringAsFixed(1)}% INCREASE"
                        : "${percentageChange.abs().toStringAsFixed(1)}% DECREASE",
                    style: TextStyle(
                      color: percentageChange > 50
                          ? Colors.redAccent
                          : Colors.greenAccent,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    "vs Saved Healthy Baseline (${savedBaseline.toStringAsFixed(3)} AU)",
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 15),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: const Center(
                child: Text(
                  "NO BASELINE SAVED\nScan relative intensity only. Save this scan to track future degradation.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 15),
          ],

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildMetric(
                "PEAK FREQ",
                "${_finalResult!.peakFrequency.toStringAsFixed(2)} Hz",
                Colors.white,
              ),
              Container(width: 1, height: 40, color: Colors.white10),
              _buildMetric(
                "INTENSITY",
                "${currentAmplitude.toStringAsFixed(3)} AU",
                Colors.cyanAccent,
              ),
            ],
          ),

          const SizedBox(height: 25),

          if (!hasBaseline)
            ElevatedButton.icon(
              onPressed: () {
                box.put(machineKey, currentAmplitude);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Healthy Baseline Saved Successfully!"),
                    backgroundColor: Colors.green,
                  ),
                );
              },
              icon: const Icon(Icons.save, color: Colors.black),
              label: const Text(
                "SAVE AS HEALTHY BASELINE",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: () {
                box.delete(machineKey);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Baseline Cleared"),
                    backgroundColor: Colors.orange,
                  ),
                );
              },
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              label: const Text(
                "CLEAR SAVED BASELINE",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.redAccent),
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),

          const SizedBox(height: 15),

          // --- THE NEW GENTWIN SYNC BUTTON ---
          ElevatedButton.icon(
            onPressed: _isSyncing ? null : _syncToGenTwin,
            icon: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.auto_graph, color: Colors.white),
            label: Text(
              _isSyncing ? "TRANSMITTING..." : "SYNC TO GENTWIN & DIAGNOSE",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              disabledBackgroundColor: Colors.grey.shade800,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),

          const SizedBox(height: 15),

          ElevatedButton.icon(
            onPressed: _resetToPreview,
            icon: const Icon(Icons.refresh, color: Colors.black),
            label: const Text(
              "NEW SCAN",
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingUI() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "CAMERA HARDWARE LOCK",
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 10,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [30, 60, 120].map((fps) {
                    bool isSelected = _selectedFps == fps;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedFps = fps),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.cyanAccent
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.cyanAccent
                                  : Colors.white30,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              "$fps FPS",
                              style: TextStyle(
                                color: isSelected ? Colors.black : Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _rpmController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(
                      Icons.settings,
                      color: Colors.cyanAccent,
                    ),
                    hintText: "Target Machine RPM (Optional)",
                    hintStyle: const TextStyle(color: Colors.white30),
                    filled: true,
                    fillColor: Colors.black,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  "Enter expected RPM to validate physics limit.",
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),

          // 3. THE RECORD BUTTON (Now calls the real scan)
          GestureDetector(
            onTap: _startRealScan,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white30, width: 4),
              ),
              child: Center(
                child: Container(
                  width: _isRecording ? 30 : 60,
                  height: _isRecording ? 30 : 60,
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(_isRecording ? 8 : 30),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.cyanAccent),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.previewSize?.height ?? 1,
                height: _controller!.value.previewSize?.width ?? 1,
                child: CameraPreview(_controller!),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.8),
                  Colors.transparent,
                  Colors.black.withOpacity(0.9),
                ],
                stops: const [0.0, 0.4, 0.8],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 4. TRIPLE TAP DETECTOR WRAPPER
                  GestureDetector(
                    onTap: _onTitleTapped,
                    child: Container(
                      color: Colors
                          .transparent, // Ensures the whole box is tappable
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 5,
                      ),
                      child: const Text(
                        "VIBRAVISION",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 3,
                        ),
                      ),
                    ),
                  ),
                  _isRecording
                      ? FadeTransition(
                          opacity: _blinkAnimation,
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Colors.redAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                "ANALYZING...",
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Row(
                          children: [
                            const Text(
                              "READY",
                              style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.greenAccent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _finalResult != null
                ? _buildResultsCard()
                : _buildRecordingUI(),
          ),
        ],
      ),
    );
  }
}
