import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/bluetooth_service.dart';

class BluetoothDialog extends StatefulWidget {
  const BluetoothDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (ctx) => const BluetoothDialog(),
    );
  }

  @override
  State<BluetoothDialog> createState() => _BluetoothDialogState();
}

class _BluetoothDialogState extends State<BluetoothDialog> {
  final ArmBluetoothService _bt = ArmBluetoothService.instance;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  List<BluetoothDevice> _bondedDevices = [];

  @override
  void initState() {
    super.initState();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) setState(() => _adapterState = state);
    });

    _loadBondedDevices();

    // Mulai scan otomatis saat dialog dibuka jika belum terhubung
    if (!_bt.isConnected) {
      _bt.startScan();
    }
  }

  Future<void> _loadBondedDevices() async {
    final list = await _bt.getBondedAndSystemDevices();
    if (mounted) {
      setState(() {
        _bondedDevices = list;
      });
    }
  }

  @override
  void dispose() {
    _adapterSub?.cancel();
    super.dispose();
  }

  bool _isRobotArmDeviceName(String name) {
    final lower = name.toLowerCase();
    return lower.contains('esp32') || lower.contains('servo') || lower.contains('arm');
  }

  bool _isRobotArmScanResult(ScanResult r) {
    final name = r.device.platformName;
    final advName = r.advertisementData.advName;
    return _isRobotArmDeviceName(name) || _isRobotArmDeviceName(advName);
  }

  Future<void> _connectToDevice(BluetoothDevice device, String name) async {
    final success = await _bt.connect(device);
    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Berhasil terhubung ke $name!'),
            backgroundColor: const Color(0xFF10B981),
            duration: const Duration(seconds: 2),
          ),
        );
        Navigator.pop(context);
      } else {
        final errMsg = _bt.statusMessageNotifier.value;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✕ Gagal terhubung: $errMsg'),
            backgroundColor: const Color(0xFFEF4444),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;

    return Dialog(
      backgroundColor: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF334155), width: 1.2),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: isLandscape ? size.width * 0.12 : 16,
        vertical: 16,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: size.height * (isLandscape ? 0.92 : 0.80),
          maxWidth: 640,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Dialog
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF38BDF8), width: 0.8),
                    ),
                    child: const Icon(Icons.bluetooth_searching_rounded, color: Color(0xFF38BDF8), size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Koneksi Bluetooth Robot Arm',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          'Pilih perangkat ESP32 untuk menghubungkan ke aplikasi',
                          style: TextStyle(fontSize: 11, color: Colors.white60),
                        ),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: _bt.isScanningNotifier,
                    builder: (context, scanning, _) {
                      return IconButton(
                        tooltip: scanning ? 'Hentikan Pindai' : 'Pindai Ulang',
                        onPressed: () {
                          _loadBondedDevices();
                          if (scanning) {
                            _bt.stopScan();
                          } else {
                            _bt.startScan();
                          }
                        },
                        icon: scanning
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                              )
                            : const Icon(Icons.refresh_rounded, color: Color(0xFF38BDF8)),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Tutup',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // Peringatan jika Bluetooth HP belum nyala
              if (_adapterState != BluetoothAdapterState.on && _adapterState != BluetoothAdapterState.unknown)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber, width: 0.8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bluetooth_disabled, color: Colors.amber, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Bluetooth HP belum aktif. Mohon nyalakan Bluetooth Anda.',
                          style: TextStyle(fontSize: 11.5, color: Colors.white),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          try {
                            FlutterBluePlus.turnOn();
                          } catch (_) {}
                        },
                        child: const Text('Aktifkan', style: TextStyle(color: Colors.amber, fontSize: 12)),
                      ),
                    ],
                  ),
                ),

              // Status Perangkat Terhubung Saat Ini
              ValueListenableBuilder<bool>(
                valueListenable: _bt.isConnectedNotifier,
                builder: (context, connected, _) {
                  if (!connected) return const SizedBox.shrink();
                  final dev = _bt.connectedDevice;
                  final devName = dev?.platformName.isNotEmpty == true ? dev!.platformName : 'ESP32_Servo_Arm';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF10B981), width: 0.8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Terhubung ke $devName (Aktif)',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF10B981),
                                ),
                              ),
                              ValueListenableBuilder<int>(
                                valueListenable: _bt.pingMsNotifier,
                                builder: (context, ping, _) {
                                  return Text(
                                    'Latensi: ${ping}ms • Siap Kontrol Bebas Delay',
                                    style: const TextStyle(fontSize: 10, color: Colors.white70),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            await _bt.disconnect();
                            _loadBondedDevices();
                            setState(() {});
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            side: const BorderSide(color: Colors.redAccent, width: 0.8),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                            minimumSize: const Size(0, 28),
                          ),
                          child: const Text('Putuskan', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ),
                  );
                },
              ),

              // List of Devices
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // BAGIAN 1: PERANGKAT YANG SUDAH TERPASANG / TERHUBUNG DI HP (BONDED / SYSTEM)
                      if (_bondedDevices.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.phonelink_ring_rounded, size: 13, color: Color(0xFF38BDF8)),
                              const SizedBox(width: 5),
                              const Text(
                                'Perangkat Tersambung / Terpasang di HP:',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF38BDF8),
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${_bondedDevices.length} Perangkat',
                                style: const TextStyle(fontSize: 10, color: Colors.white38),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        ..._bondedDevices.map((dev) {
                          final name = dev.platformName.isNotEmpty ? dev.platformName : 'Perangkat Bluetooth';
                          final isArm = _isRobotArmDeviceName(name);
                          final isCurrent = _bt.connectedDevice?.remoteId == dev.remoteId && _bt.isConnected;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? const Color(0xFF0284C7).withValues(alpha: 0.15)
                                  : isArm
                                      ? const Color(0xFF1E293B)
                                      : const Color(0xFF161F30),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isCurrent
                                    ? const Color(0xFF38BDF8)
                                    : isArm
                                        ? const Color(0xFF0284C7)
                                        : const Color(0xFF334155),
                                width: isArm || isCurrent ? 1.2 : 0.6,
                              ),
                            ),
                            child: ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                              leading: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: isArm ? const Color(0xFF38BDF8).withValues(alpha: 0.2) : Colors.white10,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isArm ? Icons.precision_manufacturing_rounded : Icons.bluetooth,
                                  color: isArm ? const Color(0xFF38BDF8) : Colors.white60,
                                  size: 18,
                                ),
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: isArm ? FontWeight.bold : FontWeight.w500,
                                        color: isArm ? Colors.white : Colors.white70,
                                      ),
                                    ),
                                  ),
                                  if (isArm) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFA855F7).withValues(alpha: 0.3),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: const Color(0xFFA855F7), width: 0.6),
                                      ),
                                      child: const Text(
                                        'ROBOT ARM',
                                        style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFFD8B4FE)),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                '${dev.remoteId.str} • Terdaftar di HP',
                                style: const TextStyle(fontSize: 10, color: Colors.white38),
                              ),
                              trailing: ValueListenableBuilder<bool>(
                                valueListenable: _bt.isConnectingNotifier,
                                builder: (context, connecting, _) {
                                  if (isCurrent) {
                                    return const Chip(
                                      label: Text('Aktif di App', style: TextStyle(fontSize: 9.5, color: Colors.white)),
                                      backgroundColor: Color(0xFF059669),
                                      padding: EdgeInsets.zero,
                                      visualDensity: VisualDensity.compact,
                                    );
                                  }

                                  return FilledButton(
                                    onPressed: connecting ? null : () => _connectToDevice(dev, name),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: isArm ? const Color(0xFF0284C7) : const Color(0xFF334155),
                                      padding: const EdgeInsets.symmetric(horizontal: 10),
                                      minimumSize: const Size(60, 30),
                                    ),
                                    child: const Text('Sambungkan', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                  );
                                },
                              ),
                            ),
                          );
                        }),
                        const Divider(color: Color(0xFF334155), height: 16),
                      ],

                      // BAGIAN 2: HASIL PEMINDAIAN BLE BARU (SCAN RESULTS)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Hasil Pindai Baru (Nearby BLE):',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white70,
                              ),
                            ),
                            ValueListenableBuilder<bool>(
                              valueListenable: _bt.isScanningNotifier,
                              builder: (context, scanning, _) {
                                return Text(
                                  scanning ? 'Memindai...' : 'Selesai',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: scanning ? const Color(0xFF38BDF8) : Colors.white38,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),

                      StreamBuilder<List<ScanResult>>(
                        stream: _bt.scanResults,
                        builder: (context, snapshot) {
                          final results = snapshot.data ?? [];

                          // Filter out devices already listed in bonded list
                          final filtered = results.where((r) {
                            return !_bondedDevices.any((b) => b.remoteId == r.device.remoteId);
                          }).toList();

                          filtered.sort((a, b) {
                            final aIsArm = _isRobotArmScanResult(a);
                            final bIsArm = _isRobotArmScanResult(b);
                            if (aIsArm && !bIsArm) return -1;
                            if (!aIsArm && bIsArm) return 1;
                            return b.rssi.compareTo(a.rssi);
                          });

                          if (filtered.isEmpty && _bondedDevices.isEmpty) {
                            return ValueListenableBuilder<bool>(
                              valueListenable: _bt.isScanningNotifier,
                              builder: (context, scanning, _) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          scanning ? Icons.radar_rounded : Icons.bluetooth_searching_rounded,
                                          size: 36,
                                          color: Colors.white24,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          scanning
                                              ? 'Mencari "ESP32_Servo_Arm"...'
                                              : 'Tidak ada perangkat ditemukan.\nPastikan ESP32 telah dinyalakan & firmware BLE telah di-upload.',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 11.5, color: Colors.white54),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          }

                          return Column(
                            children: filtered.map((item) {
                              final isArm = _isRobotArmScanResult(item);
                              final name = item.device.platformName.isNotEmpty
                                  ? item.device.platformName
                                  : (item.advertisementData.advName.isNotEmpty
                                      ? item.advertisementData.advName
                                      : 'Perangkat Tanpa Nama');

                              final isCurrent = _bt.connectedDevice?.remoteId == item.device.remoteId && _bt.isConnected;

                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                decoration: BoxDecoration(
                                  color: isCurrent
                                      ? const Color(0xFF0284C7).withValues(alpha: 0.15)
                                      : isArm
                                          ? const Color(0xFF1E293B)
                                          : const Color(0xFF161F30),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isCurrent
                                        ? const Color(0xFF38BDF8)
                                        : isArm
                                            ? const Color(0xFF0284C7).withValues(alpha: 0.6)
                                            : const Color(0xFF334155),
                                    width: isArm || isCurrent ? 1.2 : 0.6,
                                  ),
                                ),
                                child: ListTile(
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                  leading: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: isArm ? const Color(0xFF38BDF8).withValues(alpha: 0.2) : Colors.white10,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      isArm ? Icons.precision_manufacturing_rounded : Icons.bluetooth,
                                      color: isArm ? const Color(0xFF38BDF8) : Colors.white60,
                                      size: 18,
                                    ),
                                  ),
                                  title: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          name,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: isArm ? FontWeight.bold : FontWeight.w500,
                                            color: isArm ? Colors.white : Colors.white70,
                                          ),
                                        ),
                                      ),
                                      if (isArm) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFA855F7).withValues(alpha: 0.3),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: const Color(0xFFA855F7), width: 0.6),
                                          ),
                                          child: const Text(
                                            'ROBOT ARM',
                                            style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFFD8B4FE)),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  subtitle: Text(
                                    '${item.device.remoteId.str} • Sinyal: ${item.rssi} dBm',
                                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                                  ),
                                  trailing: ValueListenableBuilder<bool>(
                                    valueListenable: _bt.isConnectingNotifier,
                                    builder: (context, connecting, _) {
                                      if (isCurrent) {
                                        return const Chip(
                                          label: Text('Aktif di App', style: TextStyle(fontSize: 9.5, color: Colors.white)),
                                          backgroundColor: Color(0xFF059669),
                                          padding: EdgeInsets.zero,
                                          visualDensity: VisualDensity.compact,
                                        );
                                      }

                                      return FilledButton(
                                        onPressed: connecting ? null : () => _connectToDevice(item.device, name),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: isArm ? const Color(0xFF0284C7) : const Color(0xFF334155),
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          minimumSize: const Size(60, 30),
                                        ),
                                        child: const Text('Konek', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                      );
                                    },
                                  ),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
