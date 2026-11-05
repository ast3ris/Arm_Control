import 'arm_frame.dart';

// Model data untuk satu Rekaman Gerakan Arm (terdiri dari urutan frame)
class ArmRecording {
  String id;
  String name;
  String description;
  List<ArmFrame> frames;
  bool isLoop;
  double speedMultiplier; // Kecepatan pemutaran: 0.5x, 1.0x, 1.5x, 2.0x
  DateTime updatedAt;

  ArmRecording({
    required this.id,
    required this.name,
    this.description = '',
    List<ArmFrame>? frames,
    this.isLoop = false,
    this.speedMultiplier = 1.0,
    DateTime? updatedAt,
  })  : frames = frames ?? [],
        updatedAt = updatedAt ?? DateTime.now();

  int get frameCount => frames.length;

  // Total durasi teoritis rekaman dalam detik
  double get totalDurationSeconds {
    if (frames.isEmpty) return 0;
    final totalMs = frames.fold<int>(0, (sum, f) => sum + f.delayMs);
    final multiplier = speedMultiplier <= 0 ? 1.0 : speedMultiplier;
    return (totalMs / 1000.0) / multiplier;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'frames': frames.map((f) => f.toJson()).toList(),
    'isLoop': isLoop,
    'speedMultiplier': speedMultiplier,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ArmRecording.fromJson(Map<String, dynamic> json) => ArmRecording(
    id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
    name: json['name'] as String? ?? 'Rekaman Baru',
    description: json['description'] as String? ?? '',
    frames: (json['frames'] as List<dynamic>?)
            ?.map((f) => ArmFrame.fromJson(f as Map<String, dynamic>))
            .toList() ??
        [],
    isLoop: json['isLoop'] as bool? ?? false,
    speedMultiplier: (json['speedMultiplier'] as num?)?.toDouble() ?? 1.0,
    updatedAt: json['updatedAt'] != null
        ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
        : DateTime.now(),
  );

  ArmRecording copyWith({
    String? id,
    String? name,
    String? description,
    List<ArmFrame>? frames,
    bool? isLoop,
    double? speedMultiplier,
    DateTime? updatedAt,
  }) {
    return ArmRecording(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      frames: frames != null
          ? frames.map((f) => f.copyWith()).toList()
          : this.frames.map((f) => f.copyWith()).toList(),
      isLoop: isLoop ?? this.isLoop,
      speedMultiplier: speedMultiplier ?? this.speedMultiplier,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
