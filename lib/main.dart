import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/auto_mode_page.dart';
import 'services/bluetooth_service.dart';
import 'widgets/bluetooth_dialog.dart';
import 'widgets/conveyor_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      title: 'Robot Arm Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8), // Sky Blue (clean & modern)
          secondary: Color(0xFFF59E0B), // Amber
          surface: Color(0xFF1E293B), // Slate 800
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
  final ArmBluetoothService _bt = ArmBluetoothService.instance;

  // Sudut Servo:
  // - Servo 1 (Pin 18): Pengangkat Box
  //   * BUKA = 30° (Servo mengangkat)
  //   * TUTUP = 0° (Servo menutup)
  static const int kAngleBuka = 30;
  static const int kAngleTutup = 0;
  double _angle1 = kAngleTutup.toDouble(); // Default tertutup (0°)

  // - Servo 2 (Pin 26): Arm Joint (0° s.d. 180°)
  double _angle2 = 90.0;
  bool _isArmJointDragging = false;
  int? _lastSentAngle2;
  int? _pendingAngle2;
  bool _isSendingJoint = false;
  Timer? _streamTimer2;

  // - Servo 3 (Pin 21): Servo Bawah 180° (Base Rotation, 0° s.d. 180°)
  //   * KIRI = 0°
  //   * TENGAH = 90°
  //   * KANAN = 180°
  double _angle3 = 90.0; // Default posisi tengah (90°)
  bool _isBaseDragging = false;
  int? _lastSentAngle3;
  int? _pendingAngle3;
  bool _isSendingBase = false;
  Timer? _streamTimer3;

  // Interval pengiriman streaming realtime (50Hz = 20ms, standar servo PWM & BLE)
  static const int _kStreamIntervalMs = 20;

  // Status Koneksi
  bool _isConnected = false;
  int _pingMs = 0;
  String _statusMessage = 'Belum terhubung ke Bluetooth';

  @override
  void initState() {
    super.initState();
    _bt.init();
    _bt.isConnectedNotifier.addListener(_onBtStateChanged);
    _bt.pingMsNotifier.addListener(_onBtPingChanged);
    _bt.statusMessageNotifier.addListener(_onBtStatusChanged);
    _bt.currentAnglesNotifier.addListener(_onBtAnglesChanged);
    _syncWithBt();
  }

  void _syncWithBt() {
    _isConnected = _bt.isConnected;
    _pingMs = _bt.pingMsNotifier.value;
    _statusMessage = _bt.statusMessageNotifier.value;
  }

  void _onBtStateChanged() {
    if (!mounted) return;
    setState(() {
      _isConnected = _bt.isConnected;
    });
  }

  void _onBtPingChanged() {
    if (!mounted) return;
    setState(() {
      _pingMs = _bt.pingMsNotifier.value;
    });
  }

  void _onBtStatusChanged() {
    if (!mounted) return;
    setState(() {
      _statusMessage = _bt.statusMessageNotifier.value;
    });
  }

  void _onBtAnglesChanged() {
    if (!mounted) return;
    final f = _bt.currentAnglesNotifier.value;
    setState(() {
      _angle1 = f.servo1.toDouble();
      // Jangan timpa sudut jika user sedang aktif menggeser kontroler
      if (!_isArmJointDragging) {
        _angle2 = f.servo2.toDouble();
      }
      if (!_isBaseDragging) {
        _angle3 = f.servo3.toDouble();
      }
    });
  }

  @override
  void dispose() {
    _streamTimer2?.cancel();
    _streamTimer3?.cancel();
    _bt.isConnectedNotifier.removeListener(_onBtStateChanged);
    _bt.pingMsNotifier.removeListener(_onBtPingChanged);
    _bt.statusMessageNotifier.removeListener(_onBtStatusChanged);
    _bt.currentAnglesNotifier.removeListener(_onBtAnglesChanged);
    super.dispose();
  }

  void _openBluetoothDialog() {
    BluetoothDialog.show(context);
  }

  Future<void> _sendSingleServo(int servoNumber, int angle) async {
    final success = await _bt.sendSingleServo(servoNumber, angle);
    if (mounted) {
      setState(() {
        _isConnected = _bt.isConnected;
        _pingMs = _bt.pingMsNotifier.value;
        final displayAngle = servoNumber == 3 ? _angle3.toInt() : angle;
        _statusMessage = success
            ? 'Servo $servoNumber: $displayAngle° (${_pingMs}ms)'
            : 'Belum Terhubung ke ESP32';
      });
    }
  }

  // ==========================================
  // KONTROL SERVO 1 (PIN 18) - PENGANGKAT BOX
  // BUKA = 30°, TUTUP = 0°
  // ==========================================
  bool get _isBoxOpen => _angle1 >= 15.0; // >= 15° dianggap posisi Buka (30°)

  void _openBox() {
    setState(() {
      _angle1 = kAngleBuka.toDouble();
    });
    _sendSingleServo(1, kAngleBuka);
  }

  void _closeBox() {
    setState(() {
      _angle1 = kAngleTutup.toDouble();
    });
    _sendSingleServo(1, kAngleTutup);
  }

  void _toggleBox() {
    if (_isBoxOpen) {
      _closeBox();
    } else {
      _openBox();
    }
  }

  // ==========================================
  // REAL-TIME STREAMING: KONTROL SERVO 2 (PIN 26) - ARM JOINT
  // ==========================================
  void _onArmJointChanged(double val) {
    final clamped = val.clamp(0.0, 180.0);
    final targetInt = clamped.round();

    if (_angle2 != clamped) {
      setState(() {
        _angle2 = clamped;
      });
    }

    _streamJointServo(targetInt);
  }

  void _streamJointServo(int targetInt) {
    _pendingAngle2 = targetInt;

    if (_isSendingJoint || (_streamTimer2 != null && _streamTimer2!.isActive)) {
      return;
    }

    _dispatchJointServo();
  }

  Future<void> _dispatchJointServo() async {
    if (_pendingAngle2 == null) return;
    final angleToSend = _pendingAngle2!;
    _pendingAngle2 = null;

    if (angleToSend == _lastSentAngle2) {
      return;
    }

    _isSendingJoint = true;
    _lastSentAngle2 = angleToSend;

    try {
      await _bt.sendSingleServoFast(2, angleToSend);
    } finally {
      _isSendingJoint = false;

      _streamTimer2?.cancel();
      _streamTimer2 = Timer(const Duration(milliseconds: _kStreamIntervalMs), () {
        if (_pendingAngle2 != null && _pendingAngle2 != _lastSentAngle2) {
          _dispatchJointServo();
        }
      });
    }
  }

  void _finishJointServoStream() {
    final finalInt = _angle2.round();
    _pendingAngle2 = finalInt;
    _streamTimer2?.cancel();
    _dispatchJointServo();
    _sendSingleServo(2, finalInt);
  }

  // ==========================================
  // REAL-TIME STREAMING: KONTROL SERVO 3 (PIN 21) - SERVO BAWAH (180°)
  // 0ms delay saat pertama kali disentuh/digerakkan, streaming kontinu ~50Hz
  // selama kontrol belum dilepas (tidak menunggu jari dilepas agar langsung bergerak!).
  // ==========================================
  void _onBaseAngleChanged(double val) {
    final clamped = val.clamp(0.0, 180.0);
    final targetInt = clamped.round();

    if (_angle3 != clamped) {
      setState(() {
        _angle3 = clamped;
      });
    }

    _streamBaseServo(targetInt);
  }

  void _streamBaseServo(int targetInt) {
    _pendingAngle3 = targetInt;

    // Jika sedang dalam proses kirim BLE atau dalam interval 20ms,
    // biarkan siklus pengiriman yang mengeksekusi _pendingAngle3 terbaru.
    if (_isSendingBase || (_streamTimer3 != null && _streamTimer3!.isActive)) {
      return;
    }

    // Kirim sekarang juga (0ms delay pada awal pergerakan!)
    _dispatchBaseServo();
  }

  Future<void> _dispatchBaseServo() async {
    if (_pendingAngle3 == null) return;
    final angleToSend = _pendingAngle3!;
    _pendingAngle3 = null;

    if (angleToSend == _lastSentAngle3) {
      return;
    }

    _isSendingBase = true;
    _lastSentAngle3 = angleToSend;

    try {
      await _bt.sendSingleServoFast(3, angleToSend);
    } finally {
      _isSendingBase = false;

      // Jadwalkan pengiriman target selanjutnya setelah 20ms jika posisi terus bergerak
      _streamTimer3?.cancel();
      _streamTimer3 = Timer(const Duration(milliseconds: _kStreamIntervalMs), () {
        if (_pendingAngle3 != null && _pendingAngle3 != _lastSentAngle3) {
          _dispatchBaseServo();
        }
      });
    }
  }

  void _finishBaseServoStream() {
    final finalInt = _angle3.round();
    _pendingAngle3 = finalInt;
    _streamTimer3?.cancel();
    _dispatchBaseServo();
    _sendSingleServo(3, finalInt);
  }

  void _handleBaseDialTouch(Offset localPos, Size size) {
    // Pusat pivot busur derajat setengah lingkaran
    final center = Offset(size.width / 2, size.height * 0.82);
    final dx = localPos.dx - center.dx;
    final dy = localPos.dy - center.dy;

    // Jika sentuhan di bawah garis horizontal pivot
    if (dy >= 0) {
      if (dx < 0) {
        _onBaseAngleChanged(0.0);
      } else {
        _onBaseAngleChanged(180.0);
      }
      return;
    }

    // atan2(dy, dx) menghasilkan rentang -pi (kiri/0°) sampai 0 (kanan/180°)
    final touchRad = math.atan2(dy, dx);
    final deg = (touchRad + math.pi) * 180.0 / math.pi;
    _onBaseAngleChanged(deg.clamp(0.0, 180.0));
  }

  Future<void> _resetAllToHome() async {
    _streamTimer2?.cancel();
    _streamTimer3?.cancel();
    _pendingAngle2 = null;
    _pendingAngle3 = null;
    _lastSentAngle2 = 90;
    _lastSentAngle3 = 90;
    setState(() {
      _angle1 = kAngleTutup.toDouble(); // Box tertutup (0°)
      _angle2 = 90.0; // Arm joint tegak lurus (90°)
      _angle3 = 90.0; // Servo bawah posisi tengah (90°)
    });
    await _bt.resetHome();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Column(
          children: [
            // 1. TOP HEADER (Simple, Clean, Responsive)
            _buildTopBar(),

            // 1.5 CONNECTION BANNER (Status jika offline/menghubungkan)
            _buildConnectionBanner(),

            // 2. MAIN COCKPIT: 3 EQUAL, CLEAN ERGONOMIC COLUMNS
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // SISI KIRI: SERVO BAWAH 180° (PIN 21 - BASE)
                    Expanded(
                      flex: 4,
                      child: _buildBaseServoCard(),
                    ),

                    const SizedBox(width: 10),

                    // SISI TENGAH: PENGANGKAT BOX (PIN 18)
                    Expanded(
                      flex: 4,
                      child: _buildBoxLifterCard(),
                    ),

                    const SizedBox(width: 10),

                    // SISI KANAN: ARM JOINT (PIN 26)
                    Expanded(
                      flex: 3,
                      child: _buildArmJointCard(),
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
  // TOP BAR: CLEAN & UNCLUTTERED
  // ==========================================
  Widget _buildTopBar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isCompact = constraints.maxWidth < 750;
        return Container(
          padding: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 12, vertical: 6),
          decoration: const BoxDecoration(
            color: Color(0xFF131B2E),
            border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
          ),
          child: Row(
            children: [
              // Judul Aplikasi
              Text(
                isCompact ? 'ARM' : 'ARM CONTROLLER',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                  fontSize: 13,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),

              // Status Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _isConnected
                      ? Colors.green.withValues(alpha: 0.15)
                      : Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
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
                    const SizedBox(width: 4),
                    Text(
                      _isConnected ? '${_pingMs}ms' : 'Offline',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _statusMessage,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 10, color: Colors.white54),
                ),
              ),

              // Tombol Bluetooth
              InkWell(
                onTap: _openBluetoothDialog,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                  decoration: BoxDecoration(
                    color: _isConnected
                        ? const Color(0xFF0284C7).withValues(alpha: 0.2)
                        : const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _isConnected ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                      width: 0.9,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_searching_rounded,
                        size: 13,
                        color: _isConnected ? const Color(0xFF38BDF8) : Colors.white70,
                      ),
                      if (!isCompact) ...[
                        const SizedBox(width: 4),
                        Text(
                          _isConnected
                              ? (_bt.connectedDevice?.platformName.isNotEmpty == true
                                  ? _bt.connectedDevice!.platformName
                                  : 'ESP32 BLE')
                              : 'Konek BT',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _isConnected ? const Color(0xFF38BDF8) : Colors.white70,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 5),

              // Tombol Scan / Refresh Bluetooth
              ValueListenableBuilder<bool>(
                valueListenable: _bt.isScanningNotifier,
                builder: (context, scanning, _) {
                  return IconButton(
                    onPressed: scanning ? _bt.stopScan : () => _bt.startScan(),
                    iconSize: 15,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      side: const BorderSide(color: Color(0xFF334155)),
                    ),
                    icon: scanning
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                          )
                        : const Icon(Icons.refresh, color: Colors.white70),
                    tooltip: 'Pindai Bluetooth',
                  );
                },
              ),

              const SizedBox(width: 5),

              // Reset All Button
              OutlinedButton(
                onPressed: _resetAllToHome,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 26),
                  side: const BorderSide(color: Color(0xFF334155)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: const Text(
                  'Reset',
                  style: TextStyle(fontSize: 10, color: Colors.white70),
                ),
              ),

              const SizedBox(width: 5),

              // Tombol Kontrol Conveyor (ESP-NOW Wireless)
              ValueListenableBuilder<String>(
                valueListenable: _bt.conveyorModeNotifier,
                builder: (context, cvMode, _) {
                  final bool isRunning = cvMode == 'RUN';
                  final bool isAuto = cvMode == 'AUTO';

                  Color btnBg = const Color(0xFF1E293B);
                  Color borderColor = const Color(0xFF334155);
                  Color textColor = Colors.white70;
                  Color iconColor = Colors.white54;

                  if (isRunning) {
                    btnBg = const Color(0xFF10B981).withValues(alpha: 0.2);
                    borderColor = const Color(0xFF10B981);
                    textColor = const Color(0xFF10B981);
                    iconColor = const Color(0xFF10B981);
                  } else if (isAuto) {
                    btnBg = const Color(0xFFF59E0B).withValues(alpha: 0.2);
                    borderColor = const Color(0xFFF59E0B);
                    textColor = const Color(0xFFF59E0B);
                    iconColor = const Color(0xFFF59E0B);
                  }

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onTap: () => ConveyorControlDialog.show(context),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                          decoration: BoxDecoration(
                            color: btnBg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: borderColor, width: 0.9),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.swap_horiz_rounded, size: 13, color: iconColor),
                              const SizedBox(width: 4),
                              Text(
                                isAuto
                                    ? (isCompact ? 'CV:AUTO' : 'CV: AUTO (${_bt.conveyorStopSecNotifier.value}s)')
                                    : (isRunning ? (isCompact ? 'CV:RUN' : 'CV: RUN') : (isCompact ? 'CV' : 'Conveyor')),
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: textColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (isRunning || isAuto) ...[
                        const SizedBox(width: 3),
                        IconButton(
                          onPressed: () => _bt.sendConveyorStop(),
                          iconSize: 13,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0xFFEF4444).withValues(alpha: 0.2),
                            side: const BorderSide(color: Color(0xFFEF4444), width: 0.8),
                          ),
                          icon: const Icon(Icons.stop_rounded, color: Color(0xFFEF4444)),
                          tooltip: 'Stop Conveyor',
                        ),
                      ],
                    ],
                  );
                },
              ),

              const SizedBox(width: 5),

              // Tombol Beralih ke Halaman Mode Otomatis
              FilledButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => AutoModePage(
                        initialConnected: _isConnected,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.auto_mode_rounded, size: 13),
                label: Text(
                  isCompact ? 'Auto' : 'Otomatis',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFA855F7), // Futuristic purple neon
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  minimumSize: const Size(0, 26),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================
  // CONNECTION STATUS BANNER
  // Memberikan peringatan visual instan jika BLE belum terhubung
  // ==========================================
  Widget _buildConnectionBanner() {
    return ValueListenableBuilder<bool>(
      valueListenable: _bt.isConnectingNotifier,
      builder: (context, isConnecting, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: _bt.isConnectedNotifier,
          builder: (context, isConnected, _) {
            if (isConnected) return const SizedBox.shrink();

            if (isConnecting) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3.5),
                color: const Color(0xFF0284C7).withValues(alpha: 0.15),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.8, color: Color(0xFF38BDF8)),
                    ),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Sedang menghubungkan ke ESP32...',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: Color(0xFF38BDF8), fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              );
            }

            return InkWell(
              onTap: _openBluetoothDialog,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3.5),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  border: const Border(
                    bottom: BorderSide(color: Colors.amber, width: 0.6),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 13, color: Colors.amber),
                    SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'Bluetooth belum terhubung ke ESP32. Ketuk di sini untuk menghubungkan.',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ==========================================
  // PANEL 1: SERVO BAWAH 180° (PIN 21 - BASE)
  // ==========================================
  Widget _buildBaseServoCard() {
    String directionLabel;
    if (_angle3 < 85) {
      directionLabel = 'Kiri (${(90 - _angle3).toInt()}°)';
    } else if (_angle3 > 95) {
      directionLabel = 'Kanan (${(_angle3 - 90).toInt()}°)';
    } else {
      directionLabel = 'Tengah (Netral)';
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF151E2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF243247)),
      ),
      child: Column(
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Servo Bawah (180°)',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Pin 21 • Base Rotation',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 9, color: Colors.white54),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // Sudut Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF38BDF8)),
                ),
                child: Text(
                  '${_angle3.toInt()}°',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 4),

          // Status Arah Gerakan
          Text(
            'Posisi: $directionLabel',
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white70,
              fontWeight: FontWeight.w500,
            ),
          ),

          // DIAL BUSUR 180 DERAJAT INTERAKTIF
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double w = constraints.maxWidth;
                final double h = constraints.maxHeight;
                return GestureDetector(
                  onPanStart: (d) {
                    setState(() => _isBaseDragging = true);
                    _handleBaseDialTouch(d.localPosition, Size(w, h));
                  },
                  onPanUpdate: (d) => _handleBaseDialTouch(d.localPosition, Size(w, h)),
                  onPanEnd: (_) {
                    setState(() => _isBaseDragging = false);
                    _finishBaseServoStream();
                  },
                  onPanCancel: () {
                    setState(() => _isBaseDragging = false);
                    _finishBaseServoStream();
                  },
                  onTapDown: (d) {
                    setState(() => _isBaseDragging = true);
                    _handleBaseDialTouch(d.localPosition, Size(w, h));
                  },
                  onTapUp: (_) {
                    setState(() => _isBaseDragging = false);
                    _finishBaseServoStream();
                  },
                  onTapCancel: () {
                    setState(() => _isBaseDragging = false);
                    _finishBaseServoStream();
                  },
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: CustomPaint(
                      painter: Base180DialPainter(
                        angle: _angle3,
                        isInteracting: _isBaseDragging,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 4),

          // Tombol Preset Cepat (5 tombol rapi, konsisten dengan Arm Joint)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _pillButton(
                  '◀ Kiri',
                  () => _onBaseAngleChanged(_angle3 - 5),
                ),
                const SizedBox(width: 4),
                _pillButton(
                  '0°',
                  () => _onBaseAngleChanged(0),
                  isSelected: _angle3.toInt() == 0,
                ),
                const SizedBox(width: 4),
                _pillButton(
                  '90°',
                  () => _onBaseAngleChanged(90),
                  isSelected: _angle3.toInt() == 90,
                ),
                const SizedBox(width: 4),
                _pillButton(
                  '180°',
                  () => _onBaseAngleChanged(180),
                  isSelected: _angle3.toInt() == 180,
                ),
                const SizedBox(width: 4),
                _pillButton(
                  'Kanan ▶',
                  () => _onBaseAngleChanged(_angle3 + 5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // PANEL 2: PENGANGKAT BOX (PIN 18)
  // BUKA = 30°, TUTUP = 0°
  // ==========================================
  Widget _buildBoxLifterCard() {
    final bool isOpen = _isBoxOpen;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF151E2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isOpen
              ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
              : const Color(0xFF243247),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pengangkat Box',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Pin 18 • 0°/30°',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 9, color: Colors.white54),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // Status Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isOpen
                      ? const Color(0xFF0284C7).withValues(alpha: 0.2)
                      : const Color(0xFF334155).withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isOpen
                        ? const Color(0xFF38BDF8)
                        : Colors.white24,
                  ),
                ),
                child: Text(
                  isOpen ? 'TERBUKA (30°)' : 'TERTUTUP (0°)',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    color: isOpen ? const Color(0xFF38BDF8) : Colors.white70,
                  ),
                ),
              ),
            ],
          ),

          // Area Visual Status Sederhana (Clean & Modern Icon State)
          Expanded(
            child: Center(
              child: Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOpen
                      ? const Color(0xFF0284C7).withValues(alpha: 0.15)
                      : const Color(0xFF1E293B),
                  border: Border.all(
                    color: isOpen ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                    width: 2,
                  ),
                ),
                child: Icon(
                  isOpen
                      ? Icons.keyboard_double_arrow_up_rounded
                      : Icons.keyboard_double_arrow_down_rounded,
                  size: 44,
                  color: isOpen ? const Color(0xFF38BDF8) : Colors.white38,
                ),
              ),
            ),
          ),

          // 1. TOMBOL TOGGLE UTAMA
          SizedBox(
            height: 38,
            child: FilledButton.icon(
              onPressed: _toggleBox,
              style: FilledButton.styleFrom(
                backgroundColor: isOpen
                    ? const Color(0xFF334155) // Warna kalem saat ingin menutup
                    : const Color(0xFF0284C7), // Warna aksi utama saat ingin membuka
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: Icon(
                isOpen ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                size: 18,
              ),
              label: Text(
                isOpen ? 'TUTUP BOX (0°)' : 'BUKA BOX (30°)',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // 2. DUA TOMBOL DEDIKASI JELAS (BUKA & TUTUP)
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: OutlinedButton(
                    onPressed: _openBox,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: isOpen
                          ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                          : Colors.transparent,
                      side: BorderSide(
                        color: isOpen ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                        width: isOpen ? 1.5 : 1.0,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: Text(
                      'Buka (30°)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isOpen ? const Color(0xFF38BDF8) : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: OutlinedButton(
                    onPressed: _closeBox,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: !isOpen
                          ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                          : Colors.transparent,
                      side: BorderSide(
                        color: !isOpen ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                        width: !isOpen ? 1.5 : 1.0,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: Text(
                      'Tutup (0°)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: !isOpen ? const Color(0xFF38BDF8) : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================
  // PANEL 3: ARM JOINT (PIN 26)
  // ==========================================
  Widget _buildArmJointCard() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF151E2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF243247)),
      ),
      child: Column(
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Arm Joint',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Pin 26 • Sudut',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 9, color: Colors.white54),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF10B981)),
                ),
                child: Text(
                  '${_angle2.toInt()}°',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF10B981),
                  ),
                ),
              ),
            ],
          ),

          // Slider Vertikal
          Expanded(
            child: Row(
              children: [
                // Skala Derajat
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('180°', style: TextStyle(fontSize: 8, color: Colors.white54)),
                      Text('90°', style: TextStyle(fontSize: 8, color: Colors.white70, fontWeight: FontWeight.bold)),
                      Text('0°', style: TextStyle(fontSize: 8, color: Colors.white54)),
                    ],
                  ),
                ),
                const SizedBox(width: 4),

                // Slider Fader
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final double h = math.max(30.0, constraints.maxHeight);
                      return Center(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SizedBox(
                            width: h,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 6,
                                activeTrackColor: const Color(0xFF10B981),
                                inactiveTrackColor: const Color(0xFF0F172A),
                                thumbColor: Colors.white,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 8,
                                ),
                              ),
                              child: Slider(
                                value: _angle2,
                                min: 0,
                                max: 180,
                                divisions: 180,
                                onChangeStart: (_) =>
                                    setState(() => _isArmJointDragging = true),
                                onChanged: (val) => _onArmJointChanged(val),
                                onChangeEnd: (val) {
                                  setState(() => _isArmJointDragging = false);
                                  _finishJointServoStream();
                                },
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

          // Preset Cepat
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _pillButton(
                  '-5°',
                  () => _onArmJointChanged(_angle2 - 5),
                ),
                const SizedBox(width: 3),
                _pillButton(
                  '0°',
                  () => _onArmJointChanged(0),
                  isSelected: _angle2.toInt() == 0,
                ),
                const SizedBox(width: 3),
                _pillButton(
                  '90°',
                  () => _onArmJointChanged(90),
                  isSelected: _angle2.toInt() == 90,
                ),
                const SizedBox(width: 3),
                _pillButton(
                  '180°',
                  () => _onArmJointChanged(180),
                  isSelected: _angle2.toInt() == 180,
                ),
                const SizedBox(width: 3),
                _pillButton(
                  '+5°',
                  () => _onArmJointChanged(_angle2 + 5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper Button Sederhana
  Widget _pillButton(String label, VoidCallback onPressed, {bool isSelected = false}) {
    return SizedBox(
      height: 24,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          backgroundColor: isSelected
              ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
              : Colors.transparent,
          side: BorderSide(
            color: isSelected ? const Color(0xFF38BDF8) : const Color(0xFF334155),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5),
          ),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? const Color(0xFF38BDF8) : Colors.white70,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// BASE 180° DIAL PAINTER
// Desain busur setengah lingkaran futuristik (180° Swivel Gauge)
// Menampilkan posisi sudut base servo (0° Kiri - 90° Tengah - 180° Kanan)
// ============================================================================
class Base180DialPainter extends CustomPainter {
  final double angle; // 0.0 s.d. 180.0
  final bool isInteracting;

  Base180DialPainter({
    required this.angle,
    required this.isInteracting,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.82);
    final maxRadius = math.min(size.width / 2 - 14.0, size.height * 0.74);
    final trackRadius = maxRadius - 10.0;

    if (trackRadius <= 10) return;

    const startAngle = math.pi;
    const sweepAngle = math.pi;

    // 1. Rel Lintasan Busur 180 Derajat
    final trackPaint = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: trackRadius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    // Garis Batas Halus (Inner & Outer Boundary)
    final boundaryPaint = Paint()
      ..color = const Color(0xFF334155).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: trackRadius - 5.5),
      startAngle,
      sweepAngle,
      false,
      boundaryPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: trackRadius + 5.5),
      startAngle,
      sweepAngle,
      false,
      boundaryPaint,
    );

    // 2. Busur Aktif (Active Arc) dari Kiri (0°) hingga sudut saat ini
    final double currentSweep = (angle / 180.0).clamp(0.0, 1.0) * math.pi;
    if (currentSweep > 0.02) {
      final activeGlowPaint = Paint()
        ..color = const Color(0xFF38BDF8).withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: trackRadius),
        startAngle,
        currentSweep,
        false,
        activeGlowPaint,
      );

      final activePaint = Paint()
        ..color = const Color(0xFF38BDF8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10.0
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: trackRadius),
        startAngle,
        currentSweep,
        false,
        activePaint,
      );
    }

    // 3. Ticks Garis Sudut Setiap 15°
    final majorTickPaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.5;
    final minorTickPaint = Paint()
      ..color = const Color(0xFF475569)
      ..strokeWidth = 1.0;

    for (int deg = 0; deg <= 180; deg += 15) {
      final double rad = math.pi + (deg / 180.0) * math.pi;
      final bool isMajor = (deg % 45 == 0);
      final double innerR = isMajor ? trackRadius - 16.0 : trackRadius - 12.0;
      final double outerR = trackRadius - 7.0;

      final p1 = Offset(center.dx + math.cos(rad) * innerR, center.dy + math.sin(rad) * innerR);
      final p2 = Offset(center.dx + math.cos(rad) * outerR, center.dy + math.sin(rad) * outerR);
      canvas.drawLine(p1, p2, isMajor ? majorTickPaint : minorTickPaint);
    }

    // 4. Label Teks Derajat: 0°, 90°, 180°
    _drawText(canvas, '0°', Offset(center.dx - trackRadius - 2, center.dy + 8), const TextStyle(fontSize: 9, color: Colors.white54, fontWeight: FontWeight.bold));
    _drawText(canvas, '90°', Offset(center.dx, center.dy - trackRadius - 14), const TextStyle(fontSize: 9, color: Color(0xFF38BDF8), fontWeight: FontWeight.bold));
    _drawText(canvas, '180°', Offset(center.dx + trackRadius + 2, center.dy + 8), const TextStyle(fontSize: 9, color: Colors.white54, fontWeight: FontWeight.bold));

    // 5. Garis Penunjuk dari Pivot ke Posisi Knob
    final double currentRad = math.pi + (angle / 180.0) * math.pi;
    final knobCenter = Offset(
      center.dx + math.cos(currentRad) * trackRadius,
      center.dy + math.sin(currentRad) * trackRadius,
    );

    final needlePaint = Paint()
      ..color = (isInteracting ? const Color(0xFF38BDF8) : const Color(0xFF38BDF8).withValues(alpha: 0.6))
      ..strokeWidth = 2.0;
    canvas.drawLine(center, knobCenter, needlePaint);

    // 6. Hub Lingkaran Tengah
    final hubBasePaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 12.0, hubBasePaint);

    final hubBorderPaint = Paint()
      ..color = const Color(0xFF334155)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, 12.0, hubBorderPaint);

    final hubDotPaint = Paint()
      ..color = isInteracting ? const Color(0xFF38BDF8) : const Color(0xFF64748B)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 4.0, hubDotPaint);

    // 7. Knob Indikator Interaktif
    const double knobRadius = 12.0;
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(knobCenter.translate(0, 2), knobRadius, shadowPaint);

    final knobPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(knobCenter, knobRadius, knobPaint);

    final rimPaint = Paint()
      ..color = isInteracting ? const Color(0xFF38BDF8) : const Color(0xFF7DD3FC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(knobCenter, knobRadius, rimPaint);

    final dotPaint = Paint()
      ..color = isInteracting ? const Color(0xFF38BDF8) : Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(knobCenter, 4.0, dotPaint);
  }

  void _drawText(Canvas canvas, String text, Offset position, TextStyle style) {
    final textSpan = TextSpan(text: text, style: style);
    final textPainter = TextPainter(
      text: textSpan,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    final offset = Offset(
      position.dx - textPainter.width / 2,
      position.dy - textPainter.height / 2,
    );
    textPainter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant Base180DialPainter oldDelegate) {
    return oldDelegate.angle != angle || oldDelegate.isInteracting != isInteracting;
  }
}
