import 'package:flutter/material.dart';
import '../services/bluetooth_service.dart';

class ConveyorControlDialog extends StatefulWidget {
  const ConveyorControlDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => const ConveyorControlDialog(),
    );
  }

  @override
  State<ConveyorControlDialog> createState() => _ConveyorControlDialogState();
}

class _ConveyorControlDialogState extends State<ConveyorControlDialog> {
  final ArmBluetoothService _bt = ArmBluetoothService.instance;

  late TextEditingController _runMsCtrl;
  late TextEditingController _stopSecCtrl;
  late double _speedVal;

  @override
  void initState() {
    super.initState();
    _runMsCtrl = TextEditingController(text: _bt.conveyorRunMsNotifier.value.toString());
    _stopSecCtrl = TextEditingController(text: _bt.conveyorStopSecNotifier.value.toString());
    _speedVal = _bt.conveyorSpeedNotifier.value.toDouble();
  }

  @override
  void dispose() {
    _runMsCtrl.dispose();
    _stopSecCtrl.dispose();
    super.dispose();
  }

  Future<void> _startManualRun() async {
    final ok = await _bt.sendConveyorRun();
    if (!mounted) return;
    if (!ok && !_bt.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✕ ESP32 belum terhubung via Bluetooth'),
          backgroundColor: Color(0xFFEF4444),
          duration: Duration(milliseconds: 1500),
        ),
      );
    }
  }

  Future<void> _stopConveyor() async {
    await _bt.sendConveyorStop();
  }

  Future<void> _startAutoCycle() async {
    final runMs = int.tryParse(_runMsCtrl.text.trim()) ?? 170;
    final stopSec = int.tryParse(_stopSecCtrl.text.trim()) ?? 3;

    final ok = await _bt.sendConveyorAuto(
      runMs: runMs > 0 ? runMs : 170,
      stopSec: stopSec > 0 ? stopSec : 3,
    );

    if (!mounted) return;
    if (!ok && !_bt.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✕ ESP32 belum terhubung via Bluetooth'),
          backgroundColor: Color(0xFFEF4444),
          duration: Duration(milliseconds: 1500),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ Mode Otomatis Aktif! (Jalan: ${runMs}ms | Jeda: ${stopSec}s)'),
          backgroundColor: const Color(0xFF10B981),
          duration: const Duration(milliseconds: 1800),
        ),
      );
    }
  }

  Future<void> _changeSpeed(double val) async {
    setState(() {
      _speedVal = val;
    });
    await _bt.sendConveyorSpeed(val.round());
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0F172A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF334155), width: 1.2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 680,
          maxHeight: 350,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Header Bar
              _buildHeader(),
              const SizedBox(height: 10),

              // 2. Konten Utama: 2 Kolom (Manual di Kiri, Otomatis di Kanan)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Kolom Kiri: Kontrol Manual & Kecepatan
                    Expanded(
                      flex: 5,
                      child: _buildManualAndSpeedColumn(),
                    ),

                    const SizedBox(width: 12),

                    // Kolom Kanan: Mode Otomatis Berulang
                    Expanded(
                      flex: 6,
                      child: _buildAutoCycleColumn(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF38BDF8), width: 1),
          ),
          child: const Icon(Icons.swap_horiz_rounded, size: 18, color: Color(0xFF38BDF8)),
        ),
        const SizedBox(width: 8),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'KONTROL MOTOR CONVEYOR',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: Colors.white,
                ),
              ),
              Text(
                'ESP32 Receiver (ESP-NOW Wireless) • GPIO 16, 17, 18, 19',
                style: TextStyle(fontSize: 10, color: Colors.white54),
              ),
            ],
          ),
        ),
        // Live Status Mode Notifier
        ValueListenableBuilder<String>(
          valueListenable: _bt.conveyorModeNotifier,
          builder: (context, mode, _) {
            Color badgeBg;
            Color badgeBorder;
            Color badgeText;
            String label;

            if (mode == 'RUN') {
              badgeBg = const Color(0xFF10B981).withValues(alpha: 0.2);
              badgeBorder = const Color(0xFF10B981);
              badgeText = const Color(0xFF10B981);
              label = 'RUNNING';
            } else if (mode == 'AUTO') {
              badgeBg = const Color(0xFFF59E0B).withValues(alpha: 0.2);
              badgeBorder = const Color(0xFFF59E0B);
              badgeText = const Color(0xFFF59E0B);
              label = 'AUTO CYCLE';
            } else {
              badgeBg = const Color(0xFF64748B).withValues(alpha: 0.2);
              badgeBorder = const Color(0xFF64748B);
              badgeText = const Color(0xFF94A3B8);
              label = 'STOPPED';
            }

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: badgeBorder, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: badgeText,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: badgeText),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(width: 6),
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white70),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          tooltip: 'Tutup',
        ),
      ],
    );
  }

  // Kolom Kiri: Kontrol Manual & Kecepatan Motor
  Widget _buildManualAndSpeedColumn() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.touch_app_rounded, size: 14, color: Color(0xFF38BDF8)),
              SizedBox(width: 5),
              Text(
                'Kontrol Manual',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Tombol Manual RUN & STOP
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _startManualRun,
                  icon: const Icon(Icons.play_arrow_rounded, size: 15),
                  label: const Text('RUN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _stopConveyor,
                  icon: const Icon(Icons.stop_rounded, size: 15),
                  label: const Text('STOP', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),
          const Divider(color: Color(0xFF334155), height: 1),
          const SizedBox(height: 8),

          // Slider Kecepatan PWM
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Kecepatan Motor (PWM):',
                style: TextStyle(fontSize: 10, color: Colors.white70),
              ),
              Text(
                '${((_speedVal / 255) * 100).round()}% (${_speedVal.round()})',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: const Color(0xFF38BDF8),
              inactiveTrackColor: const Color(0xFF334155),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: _speedVal,
              min: 50,
              max: 255,
              divisions: 41,
              onChanged: (v) => setState(() => _speedVal = v),
              onChangeEnd: _changeSpeed,
            ),
          ),

          // Preset Cepat Kecepatan
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _presetSpeedButton('50%', 128),
              _presetSpeedButton('75%', 192),
              _presetSpeedButton('100%', 255),
            ],
          ),
        ],
      ),
    );
  }

  Widget _presetSpeedButton(String label, int value) {
    final bool isSelected = _speedVal.round() == value;
    return InkWell(
      onTap: () => _changeSpeed(value.toDouble()),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF38BDF8).withValues(alpha: 0.25) : const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? const Color(0xFF38BDF8) : const Color(0xFF334155),
            width: 0.9,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.bold,
            color: isSelected ? const Color(0xFF38BDF8) : Colors.white70,
          ),
        ),
      ),
    );
  }

  // Kolom Kanan: Mode Otomatis Berulang (Auto Cycle)
  Widget _buildAutoCycleColumn() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.loop_rounded, size: 14, color: Color(0xFFF59E0B)),
              SizedBox(width: 5),
              Expanded(
                child: Text(
                  'Mode Siklus Otomatis (Auto Cycle)',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // 1. Input Durasi Jalan
          Row(
            children: [
              const Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Durasi Jalan:', style: TextStyle(fontSize: 10, color: Colors.white70)),
                    Text('Waktu conveyor aktif', style: TextStyle(fontSize: 8.5, color: Colors.white38)),
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                child: SizedBox(
                  height: 28,
                  child: TextField(
                    controller: _runMsCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                    decoration: InputDecoration(
                      suffixText: 'ms',
                      suffixStyle: const TextStyle(fontSize: 9, color: Colors.white54),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Chip Preset Durasi Jalan
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _runPresetChip('100ms', 100),
              _runPresetChip('170ms', 170),
              _runPresetChip('250ms', 250),
              _runPresetChip('500ms', 500),
            ],
          ),

          const SizedBox(height: 8),

          // 2. Input Jeda Berhenti Sebelum Jalan Otomatis
          Row(
            children: [
              const Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Jeda Berhenti:', style: TextStyle(fontSize: 10, color: Colors.white70)),
                    Text('Jarak detik sebelum jalan lagi', style: TextStyle(fontSize: 8.5, color: Colors.white38)),
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                child: SizedBox(
                  height: 28,
                  child: TextField(
                    controller: _stopSecCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                    decoration: InputDecoration(
                      suffixText: 'detik',
                      suffixStyle: const TextStyle(fontSize: 9, color: Colors.white54),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Chip Preset Jeda Berhenti
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _stopPresetChip('1 dtk', 1),
              _stopPresetChip('2 dtk', 2),
              _stopPresetChip('3 dtk', 3),
              _stopPresetChip('5 dtk', 5),
            ],
          ),

          const Spacer(),

          // Tombol Mulai Siklus Otomatis
          ValueListenableBuilder<String>(
            valueListenable: _bt.conveyorModeNotifier,
            builder: (context, mode, _) {
              final bool isAuto = mode == 'AUTO';

              if (isAuto) {
                return FilledButton.icon(
                  onPressed: _stopConveyor,
                  icon: const Icon(Icons.stop_rounded, size: 14),
                  label: const Text('HENTIKAN SIKLUS OTOMATIS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                );
              }

              return FilledButton.icon(
                onPressed: _startAutoCycle,
                icon: const Icon(Icons.play_circle_fill_rounded, size: 14),
                label: const Text('MULAI SIKLUS OTOMATIS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B),
                  foregroundColor: const Color(0xFF0F172A),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _runPresetChip(String label, int ms) {
    return InkWell(
      onTap: () {
        setState(() {
          _runMsCtrl.text = ms.toString();
        });
      },
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF334155), width: 0.8),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 8.5, color: Colors.white70),
        ),
      ),
    );
  }

  Widget _stopPresetChip(String label, int sec) {
    return InkWell(
      onTap: () {
        setState(() {
          _stopSecCtrl.text = sec.toString();
        });
      },
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF334155), width: 0.8),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 8.5, color: Colors.white70),
        ),
      ),
    );
  }
}

