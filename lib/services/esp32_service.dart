import '../models/arm_frame.dart';
import 'bluetooth_service.dart';

/// Service adapter untuk ESP32
/// Beralih sepenuhnya ke Bluetooth Low Energy (BLE) untuk performa instan tanpa delay (zero-latency).
class Esp32Service {
  static ArmBluetoothService get _bt => ArmBluetoothService.instance;

  // Mengirim sudut ke semua servo secara bersamaan via BLE
  static Future<bool> sendFrame(String ipOrDevice, ArmFrame frame, {Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (_bt.isConnected) {
      return await _bt.sendFrame(frame);
    }
    return false;
  }

  // Mengirim sudut ke satu servo tertentu via BLE
  static Future<bool> sendSingleServo(String ipOrDevice, int servoNumber, int angle, {Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (_bt.isConnected) {
      return await _bt.sendSingleServo(servoNumber, angle);
    }
    return false;
  }

  // Mereset lengan ke posisi aman awal (Standby / Home: S1=0°, S2=90°, S3=90°)
  static Future<bool> resetHome(String ipOrDevice) async {
    if (_bt.isConnected) {
      return await _bt.resetHome();
    }
    return false;
  }

  // Cek koneksi dan status servo dari ESP32
  static Future<Map<String, dynamic>?> checkStatus(String ipOrDevice) async {
    if (_bt.isConnected) {
      return _bt.getCurrentAnglesMap();
    }
    return null;
  }
}
