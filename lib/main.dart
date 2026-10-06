import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Kunci orientasi ke Landscape (Kiri & Kanan) untuk pengalaman cockpit optimal
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

  // Sudut Servo:
  // - Servo 1 (Pin 18): Pengangkat Box (0° = Tutup, 30° = Buka)
  // - Servo 2 (Pin 19): Arm Joint (0° - 180°)
  // - Servo 3 (Pin 21): Servo 360 Bawah (90 = STOP, 65 = Putar Kiri, 115 = Putar Kanan)
  double _angle1 = 0.0; // Pin 18: Pengangkat Box (Default 0° / Tertutup)
  double _angle2 = 90.0; // Pin 19: Arm Joint (Default 90°)
  double _angle3 = 90.0; // Pin 21: Status Sinyal Servo 360 (Default 90 / STOP)

  // VIRTUAL JOYSTICK (Servo 360 Bawah - Pin 21)
  // Menyimpan posisi knob dan sudut terakhir yang digerakkan (tidak balik ke tengah)
  double _joystickAngle = 0.0; // 0° s.d. 360° (0° = Depan / Atas)
  Offset _knobOffset = const Offset(0, -50); // Posisi relatif knob dari center
  bool _isJoystickActive = false;
  bool _isRotatingCW = false;
  bool _isRotatingCCW = false;
  double? _lastDragAngleRad;
  Timer? _joystickStopTimer;

  // Status Koneksi
  bool _isConnected = false;
  bool _isLoading = false;
  int _pingMs = 0;
  String _statusMessage = 'Belum terhubung ke ESP32';

  // Debounce timers untuk transmisi HTTP
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
    _joystickStopTimer?.cancel();
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
          if (data['s3'] != null) _angle3 = (data['s3'] as num).toDouble();
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

  // ==========================================
  // KONTROL SERVO 1 (PIN 18) - PENGANGKAT BOX
  // ==========================================
  void _setBoxAngle(double val) {
    final clamped = val.clamp(0.0, 180.0);
    setState(() {
      _angle1 = clamped;
    });

    _debounce1?.cancel();
    _debounce1 = Timer(const Duration(milliseconds: 30), () {
      _sendSingleServo(1, _angle1.toInt());
    });
  }

  void _openBox() {
    _setBoxAngle(30.0);
  }

  void _closeBox() {
    _setBoxAngle(0.0);
  }

  void _toggleBox() {
    if (_angle1 >= 15.0) {
      _closeBox();
    } else {
      _openBox();
    }
  }

  // ==========================================
  // KONTROL SERVO 2 (PIN 19) - ARM JOINT
  // ==========================================
  void _onArmJointChanged(double val) {
    final clamped = val.clamp(0.0, 180.0);
    setState(() {
      _angle2 = clamped;
    });

    _debounce2?.cancel();
    _debounce2 = Timer(const Duration(milliseconds: 35), () {
      _sendSingleServo(2, _angle2.toInt());
    });
  }

  // ==========================================
  // KONTROL SERVO 3 (PIN 21) - VIRTUAL JOYSTICK
  // ==========================================
  void _onJoystickPanStart(DragStartDetails details, Size size) {
    _joystickStopTimer?.cancel();
    final center = Offset(size.width / 2, size.height / 2);
    final touch = details.localPosition;
    final dx = touch.dx - center.dx;
    final dy = touch.dy - center.dy;
    final angle = math.atan2(dy, dx);
    _lastDragAngleRad = angle;

    setState(() {
      _isJoystickActive = true;
    });

    _updateJoystickFromTouch(dx, dy, size);
  }

  void _onJoystickPanUpdate(DragUpdateDetails details, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final touch = details.localPosition;
    final dx = touch.dx - center.dx;
    final dy = touch.dy - center.dy;

    _updateJoystickFromTouch(dx, dy, size);
  }

  void _updateJoystickFromTouch(double dx, double dy, Size size) {
    // Radius maksimum joystick knob agar tetap di dalam lingkaran
    final double maxR = (math.min(size.width, size.height) / 2) - 22;
    final double dist = math.sqrt(dx * dx + dy * dy);
    final double clampedDist = dist.clamp(12.0, maxR);
    final double angleRad = math.atan2(dy, dx);

    // Konversi ke derajat (0° = Atas/Depan, 90° = Kanan, 180° = Bawah, 270° = Kiri)
    double deg = (angleRad * 180.0 / math.pi + 90.0);
    deg = (deg % 360.0 + 360.0) % 360.0;

    // Posisi knob baru
    final newKnobOffset = Offset(
      math.cos(angleRad) * clampedDist,
      math.sin(angleRad) * clampedDist,
    );

    // Deteksi arah putaran (CW vs CCW)
    int speedCommand = 90;
    bool isCW = false;
    bool isCCW = false;

    if (_lastDragAngleRad != null) {
      double delta = angleRad - _lastDragAngleRad!;
      if (delta > math.pi) delta -= 2 * math.pi;
      if (delta < -math.pi) delta += 2 * math.pi;

      if (delta > 0.015) {
        // Berputar searah jarum jam (Kanan)
        speedCommand = 115;
        isCW = true;
      } else if (delta < -0.015) {
        // Berputar berlawanan jarum jam (Kiri)
        speedCommand = 65;
        isCCW = true;
      } else if (dist > 15) {
        // Defleksi horizontal langsung
        if (dx > 12) {
          speedCommand = 115;
          isCW = true;
        } else if (dx < -12) {
          speedCommand = 65;
          isCCW = true;
        }
      }
    }

    _lastDragAngleRad = angleRad;

    setState(() {
      _joystickAngle = deg;
      _knobOffset = newKnobOffset;
      _isRotatingCW = isCW;
      _isRotatingCCW = isCCW;
      _angle3 = speedCommand.toDouble();
    });

    if (speedCommand != 90) {
      _debounce3?.cancel();
      _debounce3 = Timer(const Duration(milliseconds: 25), () {
        _sendSingleServo(3, speedCommand);
      });

      // Otomatis STOP jika jari berhenti bergerak saat masih menempel
      _joystickStopTimer?.cancel();
      _joystickStopTimer = Timer(const Duration(milliseconds: 140), () {
        _stopJoystickServo();
      });
    }
  }

  void _onJoystickPanEnd(DragEndDetails details) {
    // Sesuai permintaan khusus user:
    // Virtual joystick robot arm TIDAK kembali ke tengah (center) setelah dilepas,
    // melainkan MENYIMPAN sudut dan posisi terakhir digerakkan!
    setState(() {
      _isJoystickActive = false;
      _isRotatingCW = false;
      _isRotatingCCW = false;
    });
    _lastDragAngleRad = null;
    _stopJoystickServo();
  }

  void _stopJoystickServo() {
    _joystickStopTimer?.cancel();
    _debounce3?.cancel();
    if (mounted) {
      setState(() {
        _isRotatingCW = false;
        _isRotatingCCW = false;
        _angle3 = 90.0;
      });
    }
    _sendSingleServo(3, 90); // 90 = STOP mutlak untuk servo 360

    // Konfirmasi stop kedua untuk memastikan tidak ada antrean paket tersisa
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!_isJoystickActive && mounted) {
        _sendSingleServo(3, 90);
      }
    });
  }

  // Nudge sudut virtual joystick secara manual
  void _nudgeJoystick(int direction) {
    // direction > 0: kanan (+15°), direction < 0: kiri (-15°)
    final int speed = direction > 0 ? 115 : 65;
    final newAngle =
        ((_joystickAngle + (direction * 15.0)) % 360.0 + 360.0) % 360.0;
    final rad = (newAngle - 90.0) * (math.pi / 180.0);
    const r = 50.0;

    setState(() {
      _joystickAngle = newAngle;
      _knobOffset = Offset(math.cos(rad) * r, math.sin(rad) * r);
      _isRotatingCW = direction > 0;
      _isRotatingCCW = direction < 0;
      _angle3 = speed.toDouble();
    });

    _sendSingleServo(3, speed);
    _joystickStopTimer?.cancel();
    _joystickStopTimer = Timer(const Duration(milliseconds: 200), () {
      _stopJoystickServo();
    });
  }

  void _resetJoystickToTop() {
    const rad = -math.pi / 2; // 0° = Atas/Depan
    const r = 50.0;
    setState(() {
      _joystickAngle = 0.0;
      _knobOffset = Offset(math.cos(rad) * r, math.sin(rad) * r);
      _angle3 = 90.0;
    });
    _stopJoystickServo();
  }

  Future<void> _resetAllToHome() async {
    setState(() {
      _angle1 = 0.0; // Box tertutup
      _angle2 = 90.0; // Arm joint tengah
      _angle3 = 90.0; // Servo 360 STOP
      _joystickAngle = 0.0;
      _knobOffset = const Offset(0, -50);
      _isRotatingCW = false;
      _isRotatingCCW = false;
    });

    _stopJoystickServo();

    final ip = _ipController.text.trim();
    if (ip.isNotEmpty) {
      try {
        final url = Uri.parse('http://$ip/set_all?s1=0&s2=90&s3=90');
        await http.get(url).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  void _showIpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131B2E),
        title: const Row(
          children: [
            Icon(Icons.settings_ethernet, color: Color(0xFF00F0FF)),
            SizedBox(width: 8),
            Text('Pengaturan IP ESP32'),
          ],
        ),
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
            TextButton.icon(
              icon: const Icon(Icons.wifi_tethering, size: 16),
              onPressed: () {
                _ipController.text = '192.168.4.1';
              },
              label: const Text('Gunakan Default Hotspot: 192.168.4.1'),
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
            // Top Status Bar (Cyber Cockpit Header)
            _buildTopBar(),

            // Main Cockpit Area (Landscape: Kiri, Tengah, Kanan)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8.0,
                  vertical: 4.0,
                ),
                child: Row(
                  children: [
                    // ==========================================
                    // 1. SISI KIRI: SERVO 360 BAWAH (Pin 21)
                    // Virtual Joystick Lingkaran (Sudut Tersimpan)
                    // ==========================================
                    Expanded(
                      flex: 4,
                      child: _buildJoystickControl(),
                    ),

                    const SizedBox(width: 8),

                    // ==========================================
                    // 2. SISI TENGAH: PENGANGKAT BOX (Pin 18)
                    // Kontrol Tombol Modern Buka 30° / Tutup 0°
                    // ==========================================
                    Expanded(
                      flex: 4,
                      child: _buildBoxLifterControl(),
                    ),

                    const SizedBox(width: 8),

                    // ==========================================
                    // 3. SISI KANAN: ARM JOINT (Pin 19)
                    // Vertical Fader / Volume Bar Slider
                    // ==========================================
                    Expanded(
                      flex: 3,
                      child: _buildVolumeBarControl(
                        servoNum: 2,
                        pin: 19,
                        title: 'PIN 19',
                        subtitle: 'ARM JOINT',
                        angle: _angle2,
                        activeColor: const Color(0xFF00E676),
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

  // ==========================================
  // HEADER STATUS BAR
  // ==========================================
  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        color: Color(0xFF101726),
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bool isCompact = constraints.maxWidth < 720;
          return Row(
            children: [
              const Icon(Icons.precision_manufacturing, color: Color(0xFF00F0FF), size: 16),
              const SizedBox(width: 4),
              Text(
                isCompact ? 'ARM' : 'ARM COCKPIT',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 6),

              // Status Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isConnected ? '${_pingMs}ms' : 'OFFLINE',
                      style: TextStyle(
                        fontSize: 9.0,
                        fontWeight: FontWeight.bold,
                        color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _statusMessage,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 9.0, color: Colors.white54),
                ),
              ),

              const SizedBox(width: 4),

              // IP Info
              InkWell(
                onTap: _showIpDialog,
                borderRadius: BorderRadius.circular(5),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi, size: 10, color: Color(0xFF00F0FF)),
                      const SizedBox(width: 3),
                      Text(
                        _ipController.text,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 4),

              // Refresh Button
              SizedBox(
                height: 24,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _checkConnection,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00F0FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  icon: _isLoading
                      ? const SizedBox(
                          width: 9,
                          height: 9,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.black,
                          ),
                        )
                      : const Icon(Icons.refresh, size: 11),
                  label: const Text(
                    'Cek',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              const SizedBox(width: 4),

              // Reset All Button
              SizedBox(
                height: 24,
                child: OutlinedButton.icon(
                  onPressed: _resetAllToHome,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFFFB703)),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  icon: const Icon(Icons.home, size: 11, color: Color(0xFFFFB703)),
                  label: const Text(
                    'Reset',
                    style: TextStyle(
                      fontSize: 10,
                      color: Color(0xFFFFB703),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ==========================================
  // WIDGET 1: VIRTUAL JOYSTICK LINGKARAN (PIN 21 - SERVO 360 BAWAH)
  // Menahan sudut terakhir tanpa reset ke tengah!
  // ==========================================
  Widget _buildJoystickControl() {
    String statusText = '■ DIAM (PWM: ${_angle3.toInt()})';
    Color statusColor = const Color(0xFF00E676);

    if (_isRotatingCW) {
      statusText = '▶ PUTAR KANAN (${_angle3.toInt()})';
      statusColor = const Color(0xFFFFB703);
    } else if (_isRotatingCCW) {
      statusText = '◀ PUTAR KIRI (${_angle3.toInt()})';
      statusColor = const Color(0xFFFFB703);
    } else if (_isJoystickActive) {
      statusText = '● DITAHAN (${_joystickAngle.toInt()}°)';
      statusColor = const Color(0xFF00F0FF);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isJoystickActive || _isRotatingCW || _isRotatingCCW
              ? const Color(0xFFFFB703).withValues(alpha: 0.8)
              : const Color(0xFFFFB703).withValues(alpha: 0.35),
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
              const Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.explore,
                      color: Color(0xFFFFB703),
                      size: 15,
                    ),
                    SizedBox(width: 4),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PIN 21 - JOYSTICK',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Color(0xFFFFB703),
                              fontWeight: FontWeight.w900,
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            'SERVO 360 BAWAH',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 7.5,
                              color: Colors.white54,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // Sudut Terakhir Tersimpan
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF090D16),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: _isJoystickActive
                        ? const Color(0xFFFFB703)
                        : const Color(0xFF00E676),
                  ),
                ),
                child: Text(
                  '${_joystickAngle.toInt()}°',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: _isJoystickActive
                        ? const Color(0xFFFFB703)
                        : const Color(0xFF00E676),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 2),

          // Status Teks
          Text(
            statusText,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
              color: statusColor,
              letterSpacing: 0.5,
            ),
          ),

          const SizedBox(height: 2),

          // AREA JOYSTICK LINGKARAN INTERAKTIF
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double diameter = math.min(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                final size = Size(diameter, diameter);

                return Center(
                  child: GestureDetector(
                    onPanStart: (d) => _onJoystickPanStart(d, size),
                    onPanUpdate: (d) => _onJoystickPanUpdate(d, size),
                    onPanEnd: _onJoystickPanEnd,
                    onPanCancel: () => _onJoystickPanEnd(DragEndDetails()),
                    child: SizedBox(
                      width: diameter,
                      height: diameter,
                      child: CustomPaint(
                        size: size,
                        painter: CircularJoystickPainter(
                          angleDegrees: _joystickAngle,
                          knobOffset: _knobOffset,
                          isActive: _isJoystickActive,
                          isRotatingCW: _isRotatingCW,
                          isRotatingCCW: _isRotatingCCW,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 2),

          // Quick Action Buttons
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _steerQuickBtn(
                  '◀ Kiri',
                  () => _nudgeJoystick(-1),
                  _isRotatingCCW,
                ),
                const SizedBox(width: 4),
                _steerQuickBtn(
                  '■ STOP',
                  _stopJoystickServo,
                  !_isJoystickActive && !_isRotatingCW && !_isRotatingCCW,
                ),
                const SizedBox(width: 4),
                _steerQuickBtn(
                  '▲ 0°',
                  _resetJoystickToTop,
                  _joystickAngle.toInt() == 0,
                ),
                const SizedBox(width: 4),
                _steerQuickBtn(
                  'Kanan ▶',
                  () => _nudgeJoystick(1),
                  _isRotatingCW,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // WIDGET 2: PENGANGKAT BOX (PIN 18)
  // Tombol Buka 30° / Tutup 0° dengan Desain Modern
  // ==========================================
  Widget _buildBoxLifterControl() {
    final bool isOpen = _angle1 >= 15.0;
    final Color cardColor = const Color(0xFF00F0FF);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cardColor.withValues(alpha: isOpen ? 0.8 : 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: cardColor.withValues(alpha: isOpen ? 0.12 : 0.05),
            blurRadius: 10,
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
              const Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.inventory_2_rounded,
                      color: Color(0xFF00F0FF),
                      size: 15,
                    ),
                    SizedBox(width: 4),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PIN 18 - ANGKAT BOX',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Color(0xFF00F0FF),
                              fontWeight: FontWeight.w900,
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            'LIFTER SERVO (0° - 30°)',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 7.5,
                              color: Colors.white54,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // Status Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF090D16),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: isOpen
                        ? const Color(0xFFFFB703)
                        : const Color(0xFF00E676),
                  ),
                ),
                child: Text(
                  isOpen ? 'BUKA (${_angle1.toInt()}°)' : 'TUTUP (0°)',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: isOpen
                        ? const Color(0xFFFFB703)
                        : const Color(0xFF00E676),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 2),

          // Visualizer Animasi Mekanisme Angkat Box (0° s.d. 30°)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Center(
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                      painter: BoxLifterPainter(
                        angle: _angle1,
                        isOpen: isOpen,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 3),

          // TOMBOL UTAMA MODERN: TOGGLE SMART ACTION BUTTON
          SizedBox(
            width: double.infinity,
            height: 34,
            child: ElevatedButton.icon(
              onPressed: _toggleBox,
              style: ElevatedButton.styleFrom(
                backgroundColor: isOpen
                    ? const Color(0xFF00E676)
                    : const Color(0xFF00F0FF),
                foregroundColor: Colors.black,
                elevation: 4,
                shadowColor: isOpen
                    ? const Color(0xFF00E676).withValues(alpha: 0.5)
                    : const Color(0xFF00F0FF).withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: Icon(
                isOpen
                    ? Icons.keyboard_double_arrow_down_rounded
                    : Icons.keyboard_double_arrow_up_rounded,
                size: 18,
                color: Colors.black,
              ),
              label: Text(
                isOpen ? 'TURUNKAN BOX (TUTUP 0°)' : 'ANGKAT BOX (BUKA 30°)',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

          const SizedBox(height: 3),

          // TOMBOL DEDIKASI TERPISAH (BUKA 30° & TUTUP 0°)
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 25,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      backgroundColor: isOpen
                          ? const Color(0xFFFFB703).withValues(alpha: 0.25)
                          : Colors.transparent,
                      side: BorderSide(
                        color: isOpen
                            ? const Color(0xFFFFB703)
                            : Colors.white24,
                        width: isOpen ? 1.5 : 1.0,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onPressed: _openBox,
                    icon: Icon(
                      Icons.arrow_upward_rounded,
                      size: 13,
                      color: isOpen ? const Color(0xFFFFB703) : Colors.white70,
                    ),
                    label: Text(
                      'BUKA 30°',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isOpen
                            ? const Color(0xFFFFB703)
                            : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 25,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      backgroundColor: !isOpen
                          ? const Color(0xFF00E676).withValues(alpha: 0.25)
                          : Colors.transparent,
                      side: BorderSide(
                        color: !isOpen
                            ? const Color(0xFF00E676)
                            : Colors.white24,
                        width: !isOpen ? 1.5 : 1.0,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onPressed: _closeBox,
                    icon: Icon(
                      Icons.arrow_downward_rounded,
                      size: 13,
                      color: !isOpen ? const Color(0xFF00E676) : Colors.white70,
                    ),
                    label: Text(
                      'TUTUP 0°',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: !isOpen
                            ? const Color(0xFF00E676)
                            : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 3),

          // Micro Adjust Trim Presets
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _tinyBtn('-2°', () => _setBoxAngle(_angle1 - 2)),
                const SizedBox(width: 3),
                _tinyPreset(
                  '0° (Tutup)',
                  _closeBox,
                  _angle1.toInt() == 0,
                  const Color(0xFF00E676),
                ),
                const SizedBox(width: 3),
                _tinyPreset(
                  '15° (Separuh)',
                  () => _setBoxAngle(15),
                  _angle1.toInt() == 15,
                  const Color(0xFF00F0FF),
                ),
                const SizedBox(width: 3),
                _tinyPreset(
                  '30° (Buka)',
                  _openBox,
                  _angle1.toInt() == 30,
                  const Color(0xFFFFB703),
                ),
                const SizedBox(width: 3),
                _tinyBtn('+2°', () => _setBoxAngle(_angle1 + 2)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // WIDGET 3: VERTICAL EQUALIZER / VOLUME BAR (PIN 19 - ARM JOINT)
  // ==========================================
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
        border: Border.all(color: activeColor.withValues(alpha: 0.35)),
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: activeColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 7.5,
                        color: Colors.white54,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
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
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: activeColor,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 3),

          // Fader Slider Vertikal
          Expanded(
            child: Row(
              children: [
                // Skala Derajat
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('180°', style: TextStyle(fontSize: 7.5, color: activeColor)),
                      const Text('135°', style: TextStyle(fontSize: 6.5, color: Colors.white38)),
                      const Text('90°', style: TextStyle(fontSize: 7.5, color: Colors.white70, fontWeight: FontWeight.bold)),
                      const Text('45°', style: TextStyle(fontSize: 6.5, color: Colors.white38)),
                      Text('0°', style: TextStyle(fontSize: 7.5, color: activeColor)),
                    ],
                  ),
                ),

                const SizedBox(width: 4),

                // Slider
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final double h = math.max(30.0, constraints.maxHeight);
                      return Center(
                        child: RotatedBox(
                          quarterTurns: 3, // Putar vertikal ke atas
                          child: SizedBox(
                            width: h,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 8,
                                activeTrackColor: activeColor,
                                inactiveTrackColor: const Color(0xFF090D16),
                                thumbColor: Colors.white,
                                overlayColor: activeColor.withValues(alpha: 0.2),
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
                                onChanged: (val) => _onArmJointChanged(val),
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

          // Tombol Presets
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _tinyBtn('-5°', () => _onArmJointChanged(angle - 5)),
                const SizedBox(width: 3),
                _tinyPreset(
                  '0°',
                  () => _onArmJointChanged(0),
                  angle.toInt() == 0,
                  activeColor,
                ),
                const SizedBox(width: 3),
                _tinyPreset(
                  '45°',
                  () => _onArmJointChanged(45),
                  angle.toInt() == 45,
                  activeColor,
                ),
                const SizedBox(width: 3),
                _tinyPreset(
                  '90°',
                  () => _onArmJointChanged(90),
                  angle.toInt() == 90,
                  activeColor,
                ),
                const SizedBox(width: 3),
                _tinyPreset(
                  '135°',
                  () => _onArmJointChanged(135),
                  angle.toInt() == 135,
                  activeColor,
                ),
                const SizedBox(width: 3),
                _tinyPreset(
                  '180°',
                  () => _onArmJointChanged(180),
                  angle.toInt() == 180,
                  activeColor,
                ),
                const SizedBox(width: 3),
                _tinyBtn('+5°', () => _onArmJointChanged(angle + 5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // HELPER BUTTONS
  // ==========================================
  Widget _tinyBtn(String label, VoidCallback onPressed) {
    return SizedBox(
      height: 22,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          side: const BorderSide(color: Colors.white24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: const TextStyle(fontSize: 9.5, color: Colors.white70),
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
      height: 22,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 5),
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
            fontSize: 9.5,
            fontWeight: FontWeight.bold,
            color: isSelected ? activeColor : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _steerQuickBtn(String label, VoidCallback onPressed, bool isSelected) {
    return SizedBox(
      height: 24,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          backgroundColor: isSelected
              ? const Color(0xFFFFB703).withValues(alpha: 0.25)
              : Colors.transparent,
          side: BorderSide(
            color: isSelected ? const Color(0xFFFFB703) : Colors.white24,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: isSelected ? const Color(0xFFFFB703) : Colors.white70,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// CUSTOM PAINTER 1: VIRTUAL JOYSTICK LINGKARAN (PIN 21)
// Dilengkapi garis radar, deretan skala sudut, vektor arah, & knob tersimpan
// ============================================================================
class CircularJoystickPainter extends CustomPainter {
  final double angleDegrees; // 0° s.d. 360° (0° = Top / North)
  final Offset knobOffset;
  final bool isActive;
  final bool isRotatingCW;
  final bool isRotatingCCW;

  CircularJoystickPainter({
    required this.angleDegrees,
    required this.knobOffset,
    required this.isActive,
    required this.isRotatingCW,
    required this.isRotatingCCW,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = (math.min(size.width, size.height) / 2) - 4;
    final primaryColor = isActive || isRotatingCW || isRotatingCCW
        ? const Color(0xFFFFB703)
        : const Color(0xFF00F0FF);

    // 1. Background Pad
    final bgPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF162035),
          const Color(0xFF0A0F1D),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: maxR));
    canvas.drawCircle(center, maxR, bgPaint);

    // 2. Lingkaran Radar Konsentris
    final radarPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, maxR * 0.35, radarPaint);
    canvas.drawCircle(center, maxR * 0.70, radarPaint);

    // 3. Garis Silang Crosshairs
    final crossPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(center.dx - maxR, center.dy),
      Offset(center.dx + maxR, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxR),
      Offset(center.dx, center.dy + maxR),
      crossPaint,
    );

    // 4. Skala Derajat & Ticks Melingkar (0° s.d. 360°)
    for (int deg = 0; deg < 360; deg += 15) {
      final rad = (deg - 90) * (math.pi / 180.0);
      final isMajor = deg % 45 == 0;
      final isCardinal = deg % 90 == 0;
      final double tickLen = isCardinal ? 9.0 : (isMajor ? 6.0 : 3.5);

      final p1 = Offset(
        center.dx + math.cos(rad) * (maxR - tickLen),
        center.dy + math.sin(rad) * (maxR - tickLen),
      );
      final p2 = Offset(
        center.dx + math.cos(rad) * maxR,
        center.dy + math.sin(rad) * maxR,
      );

      final tickPaint = Paint()
        ..color = isCardinal
            ? primaryColor
            : (isMajor ? Colors.white60 : Colors.white24)
        ..strokeWidth = isCardinal ? 2.0 : 1.0;
      canvas.drawLine(p1, p2, tickPaint);
    }

    // 5. Border Lingkaran Luar dengan Glow
    final borderPaint = Paint()
      ..color = primaryColor.withValues(alpha: isActive ? 0.9 : 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isActive ? 2.5 : 1.8;
    canvas.drawCircle(center, maxR, borderPaint);

    // 6. Vektor Garis Penunjuk Sudut dari Center ke Posisi Knob
    final knobCenter = center + knobOffset;
    final vectorPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          primaryColor.withValues(alpha: 0.2),
          primaryColor.withValues(alpha: 0.8),
        ],
      ).createShader(Rect.fromPoints(center, knobCenter))
      ..strokeWidth = 2.0;
    canvas.drawLine(center, knobCenter, vectorPaint);

    // Indikator Titik Pusat (Origin)
    final originPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.5, originPaint);

    // 7. JOYSTICK KNOB (Thumb Stick)
    // Tampil gagah dengan efek metallic cybernetic & LED indikator
    const double knobRadius = 18.0;

    // Glow bayangan knob
    final knobShadowPaint = Paint()
      ..color = primaryColor.withValues(alpha: isActive ? 0.35 : 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(knobCenter, knobRadius + 3, knobShadowPaint);

    // Body Knob
    final knobBodyPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF2C3E5A),
          const Color(0xFF0F1728),
        ],
      ).createShader(Rect.fromCircle(center: knobCenter, radius: knobRadius));
    canvas.drawCircle(knobCenter, knobRadius, knobBodyPaint);

    // Ring Rim Knob
    final knobRimPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(knobCenter, knobRadius, knobRimPaint);

    // LED Tengah Knob
    final ledPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(knobCenter, 4.5, ledPaint);
  }

  @override
  bool shouldRepaint(covariant CircularJoystickPainter oldDelegate) {
    return oldDelegate.angleDegrees != angleDegrees ||
        oldDelegate.knobOffset != knobOffset ||
        oldDelegate.isActive != isActive ||
        oldDelegate.isRotatingCW != isRotatingCW ||
        oldDelegate.isRotatingCCW != isRotatingCCW;
  }
}

// ============================================================================
// CUSTOM PAINTER 2: VISUALISASI MEKANISME PENGANGKAT BOX (PIN 18)
// Menampilkan schematic robotic lift arm box (0° tertutup s.d. 30° terangkat)
// ============================================================================
class BoxLifterPainter extends CustomPainter {
  final double angle; // 0.0 s.d. 30.0+
  final bool isOpen;

  BoxLifterPainter({
    required this.angle,
    required this.isOpen,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final primaryColor = isOpen ? const Color(0xFFFFB703) : const Color(0xFF00F0FF);

    // Koordinat Engsel Putar (Pivot Hinge)
    final pivotX = size.width * 0.22;
    final pivotY = size.height * 0.78;
    final pivot = Offset(pivotX, pivotY);

    // 1. Rel / Dudukan Dasar Bawah
    final baseLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.08, pivotY + 8),
      Offset(size.width * 0.92, pivotY + 8),
      baseLinePaint,
    );

    // Garis Arsir Cyber di Dudukan Bawah
    final hatchPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1.5;
    for (double x = size.width * 0.12; x < size.width * 0.88; x += 12) {
      canvas.drawLine(Offset(x, pivotY + 8), Offset(x - 6, pivotY + 16), hatchPaint);
    }

    // 2. Busur Indikator Derajat (0° s.d. 30°)
    const double arcRadius = 60.0;
    final arcPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final double sweepRad = -(angle * (math.pi / 180.0));
    canvas.drawArc(
      Rect.fromCircle(center: pivot, radius: arcRadius),
      0,
      sweepRad,
      false,
      arcPaint,
    );

    // Garis Referensi Maksimum 30°
    final maxRad = -30.0 * (math.pi / 180.0);
    final maxLinePaint = Paint()
      ..color = const Color(0xFFFFB703).withValues(alpha: 0.3)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      pivot,
      Offset(
        pivot.dx + math.cos(maxRad) * (arcRadius + 16),
        pivot.dy + math.sin(maxRad) * (arcRadius + 16),
      ),
      maxLinePaint,
    );

    // 3. Silinder Piston Hidrolik Pengangkat
    final cylinderBase = Offset(pivotX + (size.width * 0.28), pivotY + 6);
    final armRad = -(angle * (math.pi / 180.0));
    final pistonArmAttach = Offset(
      pivot.dx + math.cos(armRad) * (size.width * 0.42),
      pivot.dy + math.sin(armRad) * (size.width * 0.42),
    );

    // Batang Silinder Hidrolik
    final cylinderPaint = Paint()
      ..color = const Color(0xFF334155)
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(cylinderBase, pistonArmAttach, cylinderPaint);

    // Rod Chrome Piston Hidrolik
    final rodPaint = Paint()
      ..color = primaryColor
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(cylinderBase, pistonArmAttach, rodPaint);

    // 4. Lengan & Kotak Box Terangkat (Bisa berputar sesuai sudut _angle1)
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(armRad);

    // Balok Lengan Utama Penyangga Box
    final double armLength = size.width * 0.58;
    final armPaint = Paint()
      ..color = const Color(0xFF1E293B)
      ..strokeWidth = 8.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(armLength, 0), armPaint);

    // Border Neon Lengan
    final armBorderPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset.zero, Offset(armLength, 0), armBorderPaint);

    // Badan Kotak / Box Container
    final double boxWidth = size.width * 0.32;
    const double boxHeight = 28.0;
    final boxRect = Rect.fromLTWH(
      size.width * 0.22,
      -boxHeight - 4,
      boxWidth,
      boxHeight,
    );

    final boxFillPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          primaryColor.withValues(alpha: 0.18),
          const Color(0xFF0F172A),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(boxRect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(5)),
      boxFillPaint,
    );

    final boxBorderPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(5)),
      boxBorderPaint,
    );

    // Ikon / Striping Box
    final boxStripePaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.6)
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(boxRect.left + 8, boxRect.center.dy),
      Offset(boxRect.right - 8, boxRect.center.dy),
      boxStripePaint,
    );

    canvas.restore();

    // 5. Engsel Poros Pivot (Baut Hinge Bercahaya)
    final hingeGlowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(pivot, 9.0, hingeGlowPaint);

    final hingePaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pivot, 7.0, hingePaint);

    final hingeBorder = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(pivot, 7.0, hingeBorder);

    final hingeCenter = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pivot, 2.5, hingeCenter);

    // 6. Label Sudut 30° MAX & Derajat Terbuka
    final textSpan = TextSpan(
      text: '${angle.toInt()}°',
      style: TextStyle(
        color: primaryColor,
        fontWeight: FontWeight.bold,
        fontSize: 12,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(pivot.dx + (arcRadius * 0.75), pivot.dy - (arcRadius * 0.75) - 10),
    );
  }

  @override
  bool shouldRepaint(covariant BoxLifterPainter oldDelegate) {
    return oldDelegate.angle != angle || oldDelegate.isOpen != isOpen;
  }
}
