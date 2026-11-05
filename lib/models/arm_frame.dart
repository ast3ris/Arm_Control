// Model data untuk setiap Frame dalam sebuah Rekaman Arm
class ArmFrame {
  int servo1; // Servo 1 (Pin 18) Pengangkat Box: 30° (Buka) atau 0° (Tutup)
  int servo2; // Servo 2 (Pin 26) Arm Joint: 0° - 180°
  int servo3; // Servo 3 (Pin 21) Servo Bawah Base: 0° - 180°
  int delayMs; // Durasi jeda di frame ini sebelum pindah ke frame berikutnya (milidetik)
  String note; // Catatan posisi, misal: "Buka Box & Ambil"

  ArmFrame({
    this.servo1 = 0,
    this.servo2 = 90,
    this.servo3 = 90,
    this.delayMs = 1000,
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
    'servo1': servo1,
    'servo2': servo2,
    'servo3': servo3,
    'delayMs': delayMs,
    'note': note,
  };

  factory ArmFrame.fromJson(Map<String, dynamic> json) => ArmFrame(
    servo1: (json['servo1'] as num?)?.toInt() ?? 0,
    servo2: (json['servo2'] as num?)?.toInt() ?? 90,
    servo3: (json['servo3'] as num?)?.toInt() ?? 90,
    delayMs: (json['delayMs'] as num?)?.toInt() ?? 1000,
    note: json['note'] as String? ?? '',
  );

  ArmFrame copyWith({
    int? servo1,
    int? servo2,
    int? servo3,
    int? delayMs,
    String? note,
  }) {
    return ArmFrame(
      servo1: servo1 ?? this.servo1,
      servo2: servo2 ?? this.servo2,
      servo3: servo3 ?? this.servo3,
      delayMs: delayMs ?? this.delayMs,
      note: note ?? this.note,
    );
  }
}
