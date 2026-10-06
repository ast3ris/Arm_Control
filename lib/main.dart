import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Kunci orientasi ke Landscape (Kiri & Kanan)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const ServoCockpitApp());
}

class ServoCockpitApp extends StatelessWidget {
  const ServoCockpitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Robotic Arm Cockpit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF090D16),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F0FF),
          secondary: Color(0xFFFFB703),
          surface: Color(0xFF131B2E),
        ),
      ),
      home: const CockpitDashboard(),
    );
  }
}

class CockpitDashboard extends StatefulWidget {
  const CockpitDashboard({super.key});

  @override
  State<CockpitDashboard> createState() => _CockpitDashboardState();
}

class _CockpitDashboardState extends State<CockpitDashboard> {
  final TextEditingController _ipController = TextEditingController(
    text: '192.168.4.1',
  );

  // Sudut tiap servo (0 - 180)
  double _angle1 = 90.0; // Pin 18: Volume Bar Kiri
  double _angle2 = 90.0; // Pin 19: Volume Bar Kanan
  double _angle3 = 90.0; // Pin 21: Servo 3 (Tengah)

  // Sudut Setir Mobil: -180° (Full Kiri) s.d. +180° (Full Kanan), 0° = Lurus/Center
  double _steerAngle = 0.0;
  double? _lastTouchAngle;
  Timer? _steerStopTimer;
  Timer? _steerReturnTimer;
  bool _isSteerRotating = false;

  bool _isConnected = false;
  bool _isLoading = false;
  int _pingMs = 0;
  String _statusMessage = 'Belum terhubung ke ESP32';

  Timer? _debounce1;
  Timer? _debounce2;
  Timer? _debounce3;

  @override
  void initState() {
    super.initState();
    _loadSavedIp();
  }

  @override
  void dispose() {
    _debounce1?.cancel();
    _debounce2?.cancel();
    _debounce3?.cancel();
    _steerStopTimer?.cancel();
    _steerReturnTimer?.cancel();
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('esp32_ip');
    if (savedIp != null && savedIp.isNotEmpty) {
      _ipController.text = savedIp;
    }
    _checkConnection();
  }

  Future<void> _saveIp(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('esp32_ip', ip);
  }

  Future<void> _checkConnection() async {
    String ip = _ipController.text.replaceAll(',', '.').trim();
    if (ip.isEmpty) {
      ip = '192.168.4.1';
      _ipController.text = ip;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Menghubungkan ke $ip...';
    });

    final stopwatch = Stopwatch()..start();
    try {
      final url = Uri.parse('http://$ip/status');
      final res = await http.get(url).timeout(const Duration(seconds: 2));
      stopwatch.stop();

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _isConnected = true;
          _pingMs = stopwatch.elapsedMilliseconds;
          if (data['s1'] != null) _angle1 = (data['s1'] as num).toDouble();
          if (data['s2'] != null) _angle2 = (data['s2'] as num).toDouble();
          if (data['s3'] != null) {
            _angle3 = (data['s3'] as num).toDouble();
            _steerAngle = (((_angle3 - 90.0) / 90.0) * 180.0).clamp(
              -180.0,
              180.0,
            );
          }
          _statusMessage = 'Online (${_pingMs}ms)';
        });
        _saveIp(ip);
      } else {
        setState(() {
          _isConnected = false;
          _statusMessage = 'HTTP ${res.statusCode}';
        });
      }
    } catch (_) {
      setState(() {
        _isConnected = false;
        _statusMessage = 'Gagal Konek ke $ip';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _sendSingleServo(int servoNumber, int angle) async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    try {
      final stopwatch = Stopwatch()..start();
      final url = Uri.parse('http://$ip/set?servo=$servoNumber&angle=$angle');
      final res = await http
          .get(url)
          .timeout(const Duration(milliseconds: 1500));
      stopwatch.stop();

      if (res.statusCode == 200) {
        setState(() {
          _isConnected = true;
          _pingMs = stopwatch.elapsedMilliseconds;
          _statusMessage = 'Servo $servoNumber: $angle° (${_pingMs}ms)';
        });
      }
    } catch (_) {
      setState(() {
        _isConnected = false;
        _statusMessage = 'Terputus';
      });
    }
  }

  void _onServoChanged(int servoNum, double val) {
    final clamped = val.clamp(0.0, 180.0);
    setState(() {
      if (servoNum == 1) _angle1 = clamped;
      if (servoNum == 2) _angle2 = clamped;
      if (servoNum == 3) {
        _angle3 = clamped;
        _steerAngle = (((_angle3 - 90.0) / 90.0) * 180.0).clamp(-180.0, 180.0);
      }
    });

    if (servoNum == 1) {
      _debounce1?.cancel();
      _debounce1 = Timer(const Duration(milliseconds: 40), () {
        _sendSingleServo(1, _angle1.toInt());
      });
    } else if (servoNum == 2) {
      _debounce2?.cancel();
      _debounce2 = Timer(const Duration(milliseconds: 40), () {
        _sendSingleServo(2, _angle2.toInt());
      });
    } else if (servoNum == 3) {
      _debounce3?.cancel();
      _debounce3 = Timer(const Duration(milliseconds: 40), () {
        _sendSingleServo(3, _angle3.toInt());
      });
    }
  }

  // Dipanggil saat jari menggerakkan setir: servo berputar mengikuti arah gerakan setir
  void _onSteerMove(double deltaDegrees) {
    if (deltaDegrees.abs() < 0.15) return;
    _steerReturnTimer?.cancel();

    final updatedSteer = (_steerAngle + deltaDegrees).clamp(-180.0, 180.0);

    setState(() {
      _steerAngle = updatedSteer;
      _isSteerRotating = true;
    });

    // deltaDegrees > 0: Putar Kanan (kecepatan 115)
    // deltaDegrees < 0: Putar Kiri (kecepatan 65)
    final int speedCommand = deltaDegrees > 0 ? 115 : 65;

    _debounce3?.cancel();
    _debounce3 = Timer(const Duration(milliseconds: 25), () {
      _sendSingleServo(3, speedCommand);
    });

    // Otomatis STOP jika jari berhenti bergerak selama 140ms
    _steerStopTimer?.cancel();
    _steerStopTimer = Timer(const Duration(milliseconds: 140), () {
      _stopSteeringServo();
    });
  }

  // Hentikan servo seketika (kirim 90) saat setir berhenti digerakkan
  void _stopSteeringServo() {
    _steerStopTimer?.cancel();
    _steerReturnTimer?.cancel();
    _debounce3?.cancel();
    if (_isSteerRotating) {
      setState(() {
        _isSteerRotating = false;
      });
    }
    _sendSingleServo(3, 90); // 90 adalah perintah STOP mutlak untuk servo 360

    // Konfirmasi stop kedua setelah 120ms agar pasti berhenti tanpa sisa antrean paket
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!_isSteerRotating && mounted) {
        _sendSingleServo(3, 90);
      }
    });
  }

  // Mengatur setir kembali ke posisi Lurus (0°) lalu berhenti total
  void _resetSteeringToCenter() {
    _steerStopTimer?.cancel();
    _steerReturnTimer?.cancel();
    _debounce3?.cancel();

    final double startAngle = _steerAngle;

    // Jika setir sudah di posisi 0° (atau sangat dekat dengan 0°), langsung hentikan motor (STOP)
    if (startAngle.abs() < 1.0) {
      setState(() {
        _steerAngle = 0.0;
        _angle3 = 90.0;
        _isSteerRotating = false;
      });
      _stopSteeringServo();
      return;
    }

    // Arah putar balik: jika sebelumnya belok kanan (>0), putar balik ke kiri (65)
    // jika sebelumnya belok kiri (<0), putar balik ke kanan (115)
    final int returnSpeed = startAngle > 0 ? 65 : 115;

    // Hitung durasi putar balik proporsional sudut (sekitar 4.2ms per derajat, max 800ms)
    final int returnDurationMs = (startAngle.abs() * 4.2).round().clamp(80, 800);

    setState(() {
      _isSteerRotating = true;
    });

    // Kirim perintah putar balik ke ESP32
    _sendSingleServo(3, returnSpeed);

    // Animasi visual setir berputar kembali ke 0°
    final startTime = DateTime.now();
    _steerReturnTimer = Timer.periodic(const Duration(milliseconds: 25), (timer) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final progress = (elapsed / returnDurationMs).clamp(0.0, 1.0);

      if (progress >= 1.0) {
        timer.cancel();
        setState(() {
          _steerAngle = 0.0;
          _angle3 = 90.0;
          _isSteerRotating = false;
        });
        // KRUSIAL: Setelah kembali ke 0°, kirim sinyal 90 agar motor servo BERHENTI!
        _stopSteeringServo();
      } else {
        setState(() {
          _steerAngle = startAngle * (1.0 - progress);
        });
      }
    });
  }

  // Putar sesaat (untuk tombol step)
  void _steerStep(int direction) {
    // direction > 0: kanan, direction < 0: kiri
    final int speed = direction > 0 ? 115 : 65;
    setState(() {
      _steerAngle = (_steerAngle + (direction * 15)).clamp(-180.0, 180.0);
      _isSteerRotating = true;
    });
    _sendSingleServo(3, speed);
    _steerStopTimer?.cancel();
    _steerStopTimer = Timer(const Duration(milliseconds: 220), () {
      _stopSteeringServo();
    });
  }

  Future<void> _resetAllToHome() async {
    setState(() {
      _angle1 = 90.0;
      _angle2 = 90.0;
      _angle3 = 0.0;
      _steerAngle = 0.0;
      _isSteerRotating = false;
    });
    _sendSingleServo(3, 0);
    final ip = _ipController.text.trim();
    if (ip.isNotEmpty) {
      try {
        final url = Uri.parse('http://$ip/set_all?s1=90&s2=90&s3=0');
        await http.get(url).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  void _showIpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131B2E),
        title: const Text('Pengaturan IP ESP32'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ipController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'IP Address',
                hintText: '192.168.4.1',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                _ipController.text = '192.168.4.1';
              },
              child: const Text('Gunakan Default Hotspot: 192.168.4.1'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00F0FF),
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _checkConnection();
            },
            child: const Text('Simpan & Cek'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Column(
          children: [
            // Top Status Bar (Compact Header)
            _buildTopBar(),

            // Main Cockpit Area (Landscape: Kiri, Tengah, Kanan)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10.0,
                  vertical: 4.0,
                ),
                child: Row(
                  children: [
                    // SISI KIRI: SERVO 1 (Pin 18) - Volume Bar
                    Expanded(
                      flex: 3,
                      child: _buildVolumeBarControl(
                        servoNum: 1,
                        pin: 18,
                        title: 'PIN 18',
                        subtitle: 'BASE ARM',
                        angle: _angle1,
                        activeColor: const Color(0xFF00F0FF), // Neon Cyan
                      ),
                    ),

                    const SizedBox(width: 10),

                    // TENGAH: SERVO 3 (Pin 21) - SETIR MOBIL INTERAKTIF
                    Expanded(flex: 5, child: _buildSteeringWheelControl()),

                    const SizedBox(width: 10),

                    // SISI KANAN: SERVO 2 (Pin 19) - Volume Bar
                    Expanded(
                      flex: 3,
                      child: _buildVolumeBarControl(
                        servoNum: 2,
                        pin: 19,
                        title: 'PIN 19',
                        subtitle: 'ARM JOINT',
                        angle: _angle2,
                        activeColor: const Color(0xFF00E676), // Neon Green
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Header Ringkas untuk Landscape
  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: const BoxDecoration(
        color: Color(0xFF101726),
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          // Logo & Title
          const Icon(Icons.speed, color: Color(0xFF00F0FF), size: 18),
          const SizedBox(width: 6),
          const Text(
            'ARM COCKPIT',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              fontSize: 13,
            ),
          ),

          const SizedBox(width: 14),

          // Status Koneksi Indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _isConnected
                  ? Colors.green.withValues(alpha: 0.15)
                  : Colors.red.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _isConnected ? 'ONLINE (${_pingMs}ms)' : 'OFFLINE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _statusMessage,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
          ),

          const Spacer(),

          // IP Info & Tombol Setting
          InkWell(
            onTap: _showIpDialog,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                children: [
                  const Icon(Icons.wifi, size: 12, color: Color(0xFF00F0FF)),
                  const SizedBox(width: 4),
                  Text(
                    _ipController.text,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.settings, size: 10, color: Colors.white54),
                ],
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Tombol Refresh / Cek
          SizedBox(
            height: 26,
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : _checkConnection,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00F0FF),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              icon: _isLoading
                  ? const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.refresh, size: 12),
              label: const Text(
                'Cek',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Tombol Reset Semua ke 90°
          SizedBox(
            height: 26,
            child: OutlinedButton.icon(
              onPressed: _resetAllToHome,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFFFB703)),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              icon: const Icon(Icons.home, size: 12, color: Color(0xFFFFB703)),
              label: const Text(
                'Reset',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFFFFB703),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // WIDGET 1 & 3: Vertical Volume Bar Slider (Untuk Pin 18 & Pin 21)
  Widget _buildVolumeBarControl({
    required int servoNum,
    required int pin,
    required String title,
    required String subtitle,
    required double angle,
    required Color activeColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: activeColor.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: activeColor.withValues(alpha: 0.05),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        children: [
          // Header Judul
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: activeColor,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 8,
                      color: Colors.white54,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              // Sudut Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF090D16),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: activeColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  '${angle.toInt()}°',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: activeColor,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 3),

          // Bagian Slider Vertikal Volume Bar
          Expanded(
            child: Row(
              children: [
                // Skala / Garis Ticks Equalizer
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '180°',
                        style: TextStyle(fontSize: 8, color: activeColor),
                      ),
                      const Text(
                        '135°',
                        style: TextStyle(fontSize: 7, color: Colors.white38),
                      ),
                      const Text(
                        '90°',
                        style: TextStyle(
                          fontSize: 8,
                          color: Colors.white70,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        '45°',
                        style: TextStyle(fontSize: 7, color: Colors.white38),
                      ),
                      Text(
                        '0°',
                        style: TextStyle(fontSize: 8, color: activeColor),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 4),

                // Fader Slider Vertikal
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final double h = math.max(30.0, constraints.maxHeight);
                      return Center(
                        child: RotatedBox(
                          quarterTurns: 3, // Putar jadi vertikal ke atas
                          child: SizedBox(
                            width: h,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 8,
                                activeTrackColor: activeColor,
                                inactiveTrackColor: const Color(0xFF090D16),
                                thumbColor: Colors.white,
                                overlayColor: activeColor.withValues(
                                  alpha: 0.2,
                                ),
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 8,
                                  elevation: 2,
                                ),
                              ),
                              child: Slider(
                                value: angle,
                                min: 0,
                                max: 180,
                                divisions: 180,
                                onChanged: (val) =>
                                    _onServoChanged(servoNum, val),
                                onChangeEnd: (val) =>
                                    _sendSingleServo(servoNum, val.toInt()),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 3),

          // Tombol Cepat (0°, 90°, 180°) & Fine Tune
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _tinyBtn('-5°', () => _onServoChanged(servoNum, angle - 5)),
                const SizedBox(width: 3),
                _tinyPreset(
                  '0°',
                  () => _onServoChanged(servoNum, 0),
                  angle.toInt() == 0,
                  activeColor,
                ),
                const SizedBox(width: 3),
                _tinyPreset(
                  '90°',
                  () => _onServoChanged(servoNum, 90),
                  angle.toInt() == 90,
                  activeColor,
                ),
                const SizedBox(width: 3),
                _tinyPreset(
                  '180°',
                  () => _onServoChanged(servoNum, 180),
                  angle.toInt() == 180,
                  activeColor,
                ),
                const SizedBox(width: 3),
                _tinyBtn('+5°', () => _onServoChanged(servoNum, angle + 5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // WIDGET 2: SETIR MOBIL INTERAKTIF (Untuk Pin 21)
  Widget _buildSteeringWheelControl() {
    // Sudut rotasi visual setir (-180° s.d. +180°)
    final double rotationRadian = _steerAngle * (math.pi / 180.0);

    String steerStatus = '■ BERHENTI (STOP)';
    Color steerStatusColor = const Color(0xFF00E676); // Hijau (Diam)
    if (_isSteerRotating) {
      if (_steerAngle >= 0) {
        steerStatus = '▶ BERPUTAR KANAN...';
        steerStatusColor = const Color(0xFFFFB703);
      } else {
        steerStatus = '◀ BERPUTAR KIRI...';
        steerStatusColor = const Color(0xFFFFB703);
      }
    } else {
      if (_steerAngle == 0) {
        steerStatus = '▲ LURUS (0°) - BERHENTI';
        steerStatusColor = Colors.white70;
      } else {
        steerStatus = '■ SUDUT ${_steerAngle.toInt()}° - BERHENTI';
        steerStatusColor = const Color(0xFF00E676);
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isSteerRotating
              ? const Color(0xFFFFB703).withValues(alpha: 0.8)
              : const Color(0xFFFFB703).withValues(alpha: 0.4),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFFB703).withValues(alpha: 0.08),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        children: [
          // Header Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.directions_car,
                    color: Color(0xFFFFB703),
                    size: 15,
                  ),
                  SizedBox(width: 4),
                  Text(
                    'PIN 21 - STEERING',
                    style: TextStyle(
                      color: Color(0xFFFFB703),
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF090D16),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: _isSteerRotating
                        ? const Color(0xFFFFB703)
                        : const Color(0xFF00E676),
                  ),
                ),
                child: Text(
                  _isSteerRotating
                      ? '${_steerAngle.toInt()}° [MUTAR]'
                      : '${_steerAngle.toInt()}° [STOP]',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: _isSteerRotating
                        ? const Color(0xFFFFB703)
                        : const Color(0xFF00E676),
                  ),
                ),
              ),
            ],
          ),

          // Indikator Arah Belok
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.0),
            child: Text(
              steerStatus,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: steerStatusColor,
                letterSpacing: 0.8,
              ),
            ),
          ),

          // SETIR MOBIL YANG BISA DIPUTAR (CIRCULAR ROTATION GESTURE)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double wheelSize = math.max(
                  30.0,
                  math.min(constraints.maxWidth, constraints.maxHeight) - 4,
                );
                return Center(
                  child: GestureDetector(
                    onPanStart: (details) {
                      _steerReturnTimer?.cancel();
                      final center = Offset(wheelSize / 2, wheelSize / 2);
                      final touch = details.localPosition;
                      _lastTouchAngle = math.atan2(
                        touch.dy - center.dy,
                        touch.dx - center.dx,
                      );
                    },
                    onPanUpdate: (details) {
                      final center = Offset(wheelSize / 2, wheelSize / 2);
                      final touch = details.localPosition;
                      final currentTouchAngle = math.atan2(
                        touch.dy - center.dy,
                        touch.dx - center.dx,
                      );
                      if (_lastTouchAngle != null) {
                        double delta = currentTouchAngle - _lastTouchAngle!;
                        if (delta > math.pi) delta -= 2 * math.pi;
                        if (delta < -math.pi) delta += 2 * math.pi;

                        double deltaDegrees = delta * (180.0 / math.pi);
                        _onSteerMove(deltaDegrees);
                      }
                      _lastTouchAngle = currentTouchAngle;
                    },
                    onPanEnd: (_) {
                      _lastTouchAngle = null;
                      _stopSteeringServo();
                    },
                    onPanCancel: () {
                      _lastTouchAngle = null;
                      _stopSteeringServo();
                    },
                    child: Transform.rotate(
                      angle: rotationRadian,
                      child: Container(
                        width: wheelSize,
                        height: wheelSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.6),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Image.asset(
                                'assets/steering_wheel.jpg',
                                width: wheelSize,
                                height: wheelSize,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return _buildVectorSteeringWheel(wheelSize);
                                },
                              ),
                              // Klakson Tengah: Tap untuk Lurus / Center (0°) dan putar servo ke 0
                              GestureDetector(
                                onTap: _resetSteeringToCenter,
                                child: Container(
                                  width: wheelSize * 0.28,
                                  height: wheelSize * 0.28,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.transparent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 3),

          // Tombol Kontrol Cepat Setir
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _steerQuickBtn(
                  '◀ Putar Kiri',
                  () => _steerStep(-1),
                  false,
                ),
                const SizedBox(width: 4),
                _steerQuickBtn(
                  '■ STOP',
                  () => _stopSteeringServo(),
                  !_isSteerRotating,
                ),
                const SizedBox(width: 4),
                _steerQuickBtn(
                  '▲ Lurus (0°)',
                  _resetSteeringToCenter,
                  _steerAngle.toInt() == 0,
                ),
                const SizedBox(width: 4),
                _steerQuickBtn(
                  'Putar Kanan ▶',
                  () => _steerStep(1),
                  false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Fallback Custom Painted Steering Wheel jika image loading
  Widget _buildVectorSteeringWheel(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFFFB703), width: 6),
        color: const Color(0xFF1E293B),
      ),
      child: Center(
        child: Container(
          width: size * 0.4,
          height: size * 0.4,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF090D16),
          ),
          child: const Center(
            child: Icon(Icons.rotate_right, color: Color(0xFFFFB703), size: 28),
          ),
        ),
      ),
    );
  }

  Widget _tinyBtn(String label, VoidCallback onPressed) {
    return SizedBox(
      height: 24,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          side: const BorderSide(color: Colors.white24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.white70),
        ),
      ),
    );
  }

  Widget _tinyPreset(
    String label,
    VoidCallback onPressed,
    bool isSelected,
    Color activeColor,
  ) {
    return SizedBox(
      height: 24,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          backgroundColor: isSelected
              ? activeColor.withValues(alpha: 0.2)
              : Colors.transparent,
          side: BorderSide(color: isSelected ? activeColor : Colors.white24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: isSelected ? activeColor : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _steerQuickBtn(String label, VoidCallback onPressed, bool isSelected) {
    return SizedBox(
      height: 26,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor: isSelected
              ? const Color(0xFFFFB703).withValues(alpha: 0.25)
              : Colors.transparent,
          side: BorderSide(
            color: isSelected ? const Color(0xFFFFB703) : Colors.white24,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isSelected ? const Color(0xFFFFB703) : Colors.white70,
          ),
        ),
      ),
    );
  }
}
