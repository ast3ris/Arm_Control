import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/arm_frame.dart';
import '../models/arm_recording.dart';

class RecordingStorage {
  static const String _storageKey = 'arm_recordings_list_v1';

  // Menyimpan seluruh daftar rekaman ke SharedPreferences
  static Future<void> saveRecordings(List<ArmRecording> recordings) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = recordings.map((rec) => rec.toJson()).toList();
    final jsonString = jsonEncode(jsonList);
    await prefs.setString(_storageKey, jsonString);
  }

  // Memuat seluruh daftar rekaman dari SharedPreferences
  static Future<List<ArmRecording>> loadRecordings() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);

    if (jsonString != null && jsonString.isNotEmpty) {
      try {
        final decoded = jsonDecode(jsonString) as List<dynamic>;
        final list = decoded
            .map((item) => ArmRecording.fromJson(item as Map<String, dynamic>))
            .toList();
        if (list.isNotEmpty) {
          return list;
        }
      } catch (e) {
        // Fallback jika parse gagal
      }
    }

    // Default jika belum ada rekaman yang tersimpan: Buat contoh rekaman awal
    final defaultList = _getDefaultRecordings();
    await saveRecordings(defaultList);
    return defaultList;
  }

  // Rekaman bawaan awal agar pengguna langsung punya contoh nyata
  static List<ArmRecording> _getDefaultRecordings() {
    return [
      ArmRecording(
        id: 'rec_demo_1',
        name: 'Demo Angkat & Putar',
        description: 'Gerakan dasar memutar base dan membuka/menutup box',
        isLoop: false,
        speedMultiplier: 1.0,
        frames: [
          ArmFrame(
            servo1: 0, // Box Tertutup
            servo2: 90, // Arm Joint Netral
            servo3: 90, // Base Tengah
            delayMs: 1000,
            note: 'Posisi Standby (Home)',
          ),
          ArmFrame(
            servo1: 30, // Buka Box
            servo2: 120, // Angkat Joint
            servo3: 45, // Putar Kiri
            delayMs: 1500,
            note: 'Putar Kiri & Buka Box',
          ),
          ArmFrame(
            servo1: 0, // Tutup Box
            servo2: 70, // Turunkan Joint
            servo3: 135, // Putar Kanan
            delayMs: 1500,
            note: 'Putar Kanan & Tutup Box',
          ),
          ArmFrame(
            servo1: 0, // Box Tutup
            servo2: 90, // Kembali Netral
            servo3: 90, // Base Tengah
            delayMs: 1000,
            note: 'Kembali Standby',
          ),
        ],
      ),
      ArmRecording(
        id: 'rec_demo_2',
        name: 'Pick & Place Sederhana',
        description: 'Simulasi mengambil benda di kiri dan memindahkan ke kanan',
        isLoop: false,
        speedMultiplier: 1.0,
        frames: [
          ArmFrame(
            servo1: 30, // Buka Box siap mengambil
            servo2: 60, // Turun menjangkau
            servo3: 40, // Hadap Kiri
            delayMs: 1200,
            note: 'Jangkau Objek Kiri',
          ),
          ArmFrame(
            servo1: 0, // Tutup Box menjepit
            servo2: 60,
            servo3: 40,
            delayMs: 1000,
            note: 'Jepit Objek (Tutup)',
          ),
          ArmFrame(
            servo1: 0,
            servo2: 110, // Angkat ke atas
            servo3: 40,
            delayMs: 1200,
            note: 'Angkat Objek ke Atas',
          ),
          ArmFrame(
            servo1: 0,
            servo2: 110,
            servo3: 140, // Putar ke Kanan
            delayMs: 1500,
            note: 'Bawa Putar ke Kanan',
          ),
          ArmFrame(
            servo1: 30, // Buka Box lepaskan benda
            servo2: 60, // Turunkan
            servo3: 140,
            delayMs: 1200,
            note: 'Lepaskan Objek di Kanan',
          ),
          ArmFrame(
            servo1: 0,
            servo2: 90,
            servo3: 90,
            delayMs: 1000,
            note: 'Kembali Netral',
          ),
        ],
      ),
    ];
  }
}
