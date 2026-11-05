import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/arm_frame.dart';

class ArmBluetoothService {
  // Singleton
  static final ArmBluetoothService instance = ArmBluetoothService._internal();
  ArmBluetoothService._internal();

  // UUID Nordic UART Service (NUS) - Standar ESP32 Low Latency
  static const String nusServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String nusRxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // Flutter -> ESP32
  static const String nusTxUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // ESP32 -> Flutter

  // State Notifiers
  final ValueNotifier<bool> isConnectedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isConnectingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isScanningNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String> statusMessageNotifier = ValueNotifier<String>('Bluetooth Siap');
  final ValueNotifier<int> pingMsNotifier = ValueNotifier<int>(0);
  final ValueNotifier<BluetoothDevice?> connectedDeviceNotifier = ValueNotifier<BluetoothDevice?>(null);
  final ValueNotifier<ArmFrame> currentAnglesNotifier = ValueNotifier<ArmFrame>(
    ArmFrame(servo1: 0, servo2: 90, servo3: 90),
  );

  // Status Notifier Conveyor (Mode: STOP, RUN, AUTO)
  final ValueNotifier<String> conveyorModeNotifier = ValueNotifier<String>('STOP');
  final ValueNotifier<int> conveyorRunMsNotifier = ValueNotifier<int>(170);
  final ValueNotifier<int> conveyorStopSecNotifier = ValueNotifier<int>(3);
  final ValueNotifier<int> conveyorSpeedNotifier = ValueNotifier<int>(255);

  bool get isConnected => isConnectedNotifier.value;
  bool get isConnecting => isConnectingNotifier.value;
  BluetoothDevice? get connectedDevice => connectedDeviceNotifier.value;

  // Active Connection References
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic;
  BluetoothCharacteristic? _txCharacteristic;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<int>>? _txDataSub;
  StreamSubscription<bool>? _scanSub;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      if (!await FlutterBluePlus.isSupported) {
        statusMessageNotifier.value = 'Bluetooth tidak didukung pada platform ini';
        return;
      }

      // Monitor adapter state
      FlutterBluePlus.adapterState.listen((state) {
        if (state != BluetoothAdapterState.on && isConnected) {
          _handleDisconnect();
        }
      });

      // Monitor scanning state
      _scanSub = FlutterBluePlus.isScanning.listen((scanning) {
        isScanningNotifier.value = scanning;
      });

      // Auto connect ke perangkat terakhir atau perangkat yang sudah terhubung di Android
      _tryAutoReconnect();
    } catch (_) {
      // Menangani environment widget test atau platform tanpa adapter BLE
    }
  }

  // Mendapatkan daftar perangkat yang sudah terpasang (paired/bonded) di HP Android
  // atau sedang terkoneksi di tingkat sistem OS Android
  Future<List<BluetoothDevice>> getBondedAndSystemDevices() async {
    final List<BluetoothDevice> all = [];
    try {
      final bonded = await FlutterBluePlus.bondedDevices;
      all.addAll(bonded);
    } catch (_) {}

    try {
      final system = await FlutterBluePlus.systemDevices([Guid(nusServiceUuid)]);
      for (final dev in system) {
        if (!all.any((d) => d.remoteId == dev.remoteId)) {
          all.add(dev);
        }
      }
    } catch (_) {}

    return all;
  }

  Future<void> _tryAutoReconnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastDeviceId = prefs.getString('last_esp32_device_id');

      // 1. Cek apakah ada perangkat yang sudah terpasang/terhubung di sistem HP
      final known = await getBondedAndSystemDevices();

      BluetoothDevice? target;

      // Prioritas 1: Perangkat dengan ID terakhir
      if (lastDeviceId != null && lastDeviceId.isNotEmpty) {
        for (final d in known) {
          if (d.remoteId.str == lastDeviceId) {
            target = d;
            break;
          }
        }
      }

      // Prioritas 2: Perangkat yang mengandung kata ESP32, Servo, atau Arm
      if (target == null) {
        for (final d in known) {
          final name = d.platformName.toLowerCase();
          if (name.contains('esp32') || name.contains('servo') || name.contains('arm')) {
            target = d;
            break;
          }
        }
      }

      // Jika ditemukan perangkat yang sudah di-pair di Android Settings, langsung hubungkan ke aplikasi!
      if (target != null) {
        final devName = target.platformName.isNotEmpty ? target.platformName : target.remoteId.str;
        statusMessageNotifier.value = 'Menghubungkan otomatis ke $devName...';
        final success = await connect(target);
        if (success) return;
      }

      // Prioritas 3: Scan aktif dan sambungkan otomatis jika mendeteksi ESP32_Servo_Arm di sekitar
      if (!isConnected) {
        StreamSubscription<List<ScanResult>>? autoConnectSub;
        autoConnectSub = FlutterBluePlus.scanResults.listen((results) async {
          if (isConnected || isConnecting) {
            autoConnectSub?.cancel();
            return;
          }
          for (final r in results) {
            final name = r.device.platformName.toLowerCase();
            final adv = r.advertisementData.advName.toLowerCase();
            final isMatch = (lastDeviceId != null && r.device.remoteId.str == lastDeviceId) ||
                name.contains('esp32') ||
                name.contains('servo') ||
                name.contains('arm') ||
                adv.contains('esp32') ||
                adv.contains('servo') ||
                adv.contains('arm');

            if (isMatch) {
              autoConnectSub?.cancel();
              await stopScan();
              debugPrint('[BLE] Auto-connect menemukan perangkat: ${r.device.platformName} (${r.device.remoteId})');
              await connect(r.device);
              break;
            }
          }
        });

        await startScan(timeout: const Duration(seconds: 5));
        await Future.delayed(const Duration(seconds: 5));
        autoConnectSub.cancel();
      }
    } catch (_) {}
  }

  Future<void> startScan({Duration timeout = const Duration(seconds: 5)}) async {
    if (isScanningNotifier.value) return;

    try {
      // Pastikan Bluetooth nyala
      final adapter = await FlutterBluePlus.adapterState.first;
      if (adapter != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {}
      }

      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (e) {
      statusMessageNotifier.value = 'Gagal memindai: $e';
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  Future<bool> connect(BluetoothDevice device) async {
    await stopScan();

    if (_device != null && _device!.remoteId == device.remoteId && isConnected && _rxCharacteristic != null) {
      return true;
    }

    // Putus koneksi lama jika perangkat berbeda
    if (_device != null && _device!.remoteId != device.remoteId) {
      await disconnect();
    }

    isConnectingNotifier.value = true;
    final devName = device.platformName.isNotEmpty ? device.platformName : device.remoteId.str;
    statusMessageNotifier.value = 'Menghubungkan ke $devName...';

    try {
      // Jika belum terhubung ke GATT aplikasi, hubungkan
      if (!device.isConnected) {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 8),
          autoConnect: false,
        );
      }

      _device = device;
      connectedDeviceNotifier.value = device;

      // Pantau status koneksi perangkat
      _connStateSub?.cancel();
      _connStateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnect();
        }
      });

      // Minta prioritas koneksi tinggi (Android ConnectionPriority.high) untuk zero latency (<15ms)
      try {
        await device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
      } catch (_) {}

      // Minta MTU lebih besar agar komunikasi data lancar tanpa pemotongan paket
      try {
        await device.requestMtu(512);
      } catch (_) {}

      // Temukan service & characteristic
      final services = await device.discoverServices();
      _rxCharacteristic = null;
      _txCharacteristic = null;

      final normalizedNusService = nusServiceUuid.replaceAll('-', '').toLowerCase();
      final normalizedNusRx = nusRxUuid.replaceAll('-', '').toLowerCase();
      final normalizedNusTx = nusTxUuid.replaceAll('-', '').toLowerCase();

      for (final service in services) {
        final sUuid = service.uuid.toString().replaceAll('-', '').toLowerCase();
        if (sUuid == normalizedNusService) {
          for (final char in service.characteristics) {
            final cUuid = char.uuid.toString().replaceAll('-', '').toLowerCase();
            if (cUuid == normalizedNusRx) {
              _rxCharacteristic = char;
            } else if (cUuid == normalizedNusTx) {
              _txCharacteristic = char;
            }
          }
        }
      }

      // Fallback: Jika tidak ditemukan service NUS spesifik, cari characteristic dengan properti write
      if (_rxCharacteristic == null) {
        for (final service in services) {
          for (final char in service.characteristics) {
            if (char.properties.write || char.properties.writeWithoutResponse) {
              _rxCharacteristic = char;
              break;
            }
          }
          if (_rxCharacteristic != null) break;
        }
      }

      // Fallback TX: cari characteristic notify pertama
      if (_txCharacteristic == null) {
        for (final service in services) {
          for (final char in service.characteristics) {
            if (char.properties.notify || char.properties.indicate) {
              _txCharacteristic = char;
              break;
            }
          }
          if (_txCharacteristic != null) break;
        }
      }

      debugPrint('[BLE] Layanan ditemukan: RX=$_rxCharacteristic, TX=$_txCharacteristic');

      if (_rxCharacteristic == null) {
        throw Exception('Karakteristik kontrol (RX) tidak ditemukan pada perangkat ESP32.');
      }

      // Aktifkan notifikasi pada TX jika ada
      if (_txCharacteristic != null && (_txCharacteristic!.properties.notify || _txCharacteristic!.properties.indicate)) {
        try {
          await _txCharacteristic!.setNotifyValue(true);
          _txDataSub?.cancel();
          _txDataSub = _txCharacteristic!.onValueReceived.listen((bytes) {
            _handleIncomingData(bytes);
          });
        } catch (e) {
          debugPrint('[BLE] Gagal aktifkan notify TX: $e');
        }
      }

      isConnectedNotifier.value = true;
      isConnectingNotifier.value = false;
      statusMessageNotifier.value = 'Terhubung ke $devName';

      // Simpan ID untuk auto-reconnect
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_esp32_device_id', device.remoteId.str);
      await prefs.setString('last_esp32_device_name', devName);

      // Minta status sudut servo awal dari ESP32
      await requestStatus();

      return true;
    } catch (e) {
      _handleDisconnect();
      statusMessageNotifier.value = 'Gagal menghubungkan: $e';
      return false;
    } finally {
      isConnectingNotifier.value = false;
    }
  }

  void _handleDisconnect() {
    _connStateSub?.cancel();
    _connStateSub = null;
    _txDataSub?.cancel();
    _txDataSub = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _device = null;
    connectedDeviceNotifier.value = null;
    isConnectedNotifier.value = false;
    isConnectingNotifier.value = false;
    statusMessageNotifier.value = 'Bluetooth Terputus';
    conveyorModeNotifier.value = 'STOP';
  }

  Future<void> disconnect() async {
    try {
      if (_device != null) {
        await _device!.disconnect();
      }
    } catch (_) {}
    _handleDisconnect();
  }

  void _handleIncomingData(List<int> bytes) {
    if (bytes.isEmpty) return;
    try {
      final msg = utf8.decode(bytes).trim();
      if (msg.startsWith('STATUS:')) {
        final parts = msg.split(':');
        if (parts.length >= 4) {
          final s1 = int.tryParse(parts[1]) ?? 30;
          final s2 = int.tryParse(parts[2]) ?? 90;
          final s3 = int.tryParse(parts[3]) ?? 90;
          currentAnglesNotifier.value = ArmFrame(
            servo1: s1.clamp(0, 180),
            servo2: s2.clamp(0, 180),
            servo3: s3.clamp(0, 180),
          );
        }
      } else if (msg.startsWith('CV_STATUS:')) {
        final parts = msg.split(':');
        if (parts.length >= 5) {
          final modeCode = int.tryParse(parts[1]) ?? 0;
          conveyorModeNotifier.value = modeCode == 1 ? 'RUN' : (modeCode == 2 ? 'AUTO' : 'STOP');
          conveyorRunMsNotifier.value = int.tryParse(parts[2]) ?? 170;
          conveyorStopSecNotifier.value = int.tryParse(parts[3]) ?? 3;
          conveyorSpeedNotifier.value = int.tryParse(parts[4]) ?? 255;
        }
      }
    } catch (_) {}
  }

  // ==========================================================================
  // PENGIRIMAN DATA KE ROBOT (SUPER CEPAT / ZERO-DELAY)
  // ==========================================================================
  Future<bool> _sendRawString(String command) async {
    if (!isConnected || _rxCharacteristic == null) {
      debugPrint('[BLE TX] Batal kirim (${command.trim()}): isConnected=$isConnected, rxChar=$_rxCharacteristic');
      return false;
    }

    final bytes = utf8.encode(command);
    final stopwatch = Stopwatch()..start();

    try {
      debugPrint('[BLE TX] Mengirim: ${command.trim()}');
      // Prioritaskan writeWithoutResponse untuk latency instan (<10ms)
      if (_rxCharacteristic!.properties.writeWithoutResponse) {
        await _rxCharacteristic!.write(bytes, withoutResponse: true);
      } else {
        await _rxCharacteristic!.write(bytes, withoutResponse: false);
      }
      stopwatch.stop();
      pingMsNotifier.value = stopwatch.elapsedMilliseconds;
      return true;
    } catch (e) {
      try {
        debugPrint('[BLE TX] Fallback standard write karena: $e');
        await _rxCharacteristic!.write(bytes, withoutResponse: false);
        stopwatch.stop();
        pingMsNotifier.value = stopwatch.elapsedMilliseconds;
        return true;
      } catch (err) {
        debugPrint('[BLE TX] Gagal kirim perintah: $err');
        return false;
      }
    }
  }

  // Pengiriman cepat khusus realtime stream tanpa logging berulang & zero overhead
  Future<bool> _sendFast(String command) async {
    if (!isConnected || _rxCharacteristic == null) {
      return false;
    }

    final bytes = utf8.encode(command);
    try {
      if (_rxCharacteristic!.properties.writeWithoutResponse) {
        await _rxCharacteristic!.write(bytes, withoutResponse: true);
      } else {
        await _rxCharacteristic!.write(bytes, withoutResponse: false);
      }
      return true;
    } catch (_) {
      try {
        await _rxCharacteristic!.write(bytes, withoutResponse: false);
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  // Kirim perintah satu servo dengan latensi ultra rendah (0ms overhead) untuk realtime streaming
  Future<bool> sendSingleServoFast(int servoNumber, int angle) async {
    final clamped = angle.clamp(0, 180);
    return await _sendFast('S:$servoNumber:$clamped\n');
  }

  // Kirim perintah satu servo (Pin 1, 2, 3)
  Future<bool> sendSingleServo(int servoNumber, int angle) async {
    final clamped = angle.clamp(0, 180);
    final success = await _sendRawString('S:$servoNumber:$clamped\n');
    if (success) {
      final curr = currentAnglesNotifier.value;
      if (servoNumber == 1) {
        currentAnglesNotifier.value = curr.copyWith(servo1: clamped);
      } else if (servoNumber == 2) {
        currentAnglesNotifier.value = curr.copyWith(servo2: clamped);
      } else if (servoNumber == 3) {
        currentAnglesNotifier.value = curr.copyWith(servo3: clamped);
      }
    }
    return success;
  }

  // Kirim semua servo sekaligus (untuk playback rekaman frame)
  Future<bool> sendFrame(ArmFrame frame) async {
    final s1 = frame.servo1.clamp(0, 180);
    final s2 = frame.servo2.clamp(0, 180);
    final s3 = frame.servo3.clamp(0, 180);
    final success = await _sendRawString('ALL:$s1:$s2:$s3\n');
    if (success) {
      currentAnglesNotifier.value = frame;
    }
    return success;
  }

  // Reset semua servo ke posisi aman awal (Standby / Home)
  Future<bool> resetHome() async {
    final success = await _sendRawString('HOME\n');
    if (success) {
      currentAnglesNotifier.value = ArmFrame(servo1: 0, servo2: 90, servo3: 90);
    }
    return success;
  }

  // Minta status sudut servo saat ini dari ESP32
  Future<void> requestStatus() async {
    await _sendRawString('STATUS\n');
  }

  // Mengambil sudut servo terakhir
  Map<String, dynamic> getCurrentAnglesMap() {
    final frame = currentAnglesNotifier.value;
    return {
      'status': isConnected ? 'online' : 'offline',
      's1': frame.servo1,
      's2': frame.servo2,
      's3': frame.servo3,
    };
  }

  // ==========================================================================
  // KONTROL CONVEYOR (ESP-NOW WIRELESS FORWARDING)
  // ==========================================================================
  Future<bool> sendConveyorRun() async {
    final success = await _sendRawString('CV:RUN\n');
    if (success) {
      conveyorModeNotifier.value = 'RUN';
    }
    return success;
  }

  Future<bool> sendConveyorStop() async {
    final success = await _sendRawString('CV:STOP\n');
    if (success) {
      conveyorModeNotifier.value = 'STOP';
    }
    return success;
  }

  Future<bool> sendConveyorAuto({required int runMs, required int stopSec}) async {
    final safeRun = runMs > 0 ? runMs : 170;
    final safeStop = stopSec > 0 ? stopSec : 3;
    final success = await _sendRawString('CV:AUTO:$safeRun:$safeStop\n');
    if (success) {
      conveyorModeNotifier.value = 'AUTO';
      conveyorRunMsNotifier.value = safeRun;
      conveyorStopSecNotifier.value = safeStop;
    }
    return success;
  }

  Future<bool> sendConveyorSpeed(int speed) async {
    final clamped = speed.clamp(0, 255);
    final success = await _sendRawString('CV:SPEED:$clamped\n');
    if (success) {
      conveyorSpeedNotifier.value = clamped;
    }
    return success;
  }

  void dispose() {
    _connStateSub?.cancel();
    _txDataSub?.cancel();
    _scanSub?.cancel();
  }
}
