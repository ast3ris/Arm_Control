import 'dart:async';
import 'package:flutter/material.dart';
import '../models/arm_frame.dart';
import '../models/arm_recording.dart';
import '../services/bluetooth_service.dart';
import '../services/recording_storage.dart';
import '../widgets/bluetooth_dialog.dart';

class AutoModePage extends StatefulWidget {
  final String? initialIp;
  final bool initialConnected;

  const AutoModePage({
    super.key,
    this.initialIp,
    this.initialConnected = false,
  });

  @override
  State<AutoModePage> createState() => _AutoModePageState();
}

class _AutoModePageState extends State<AutoModePage> {
  final ArmBluetoothService _bt = ArmBluetoothService.instance;
  late bool _isConnected;
  bool _isLoading = true;

  // Daftar rekaman
  List<ArmRecording> _recordings = [];
  int _selectedRecIndex = 0;
  int _selectedFrameIndex = 0;

  // Status Pemutaran (Playback)
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _stopRequested = false;
  int _currentPlayingIndex = -1;

  // Buffer edit untuk frame yang sedang dipilih
  int _editS1 = 0;
  int _editS2 = 90;
  int _editS3 = 90;
  int _editDelayMs = 1000;
  final TextEditingController _noteController = TextEditingController();

  // Scroll controller
  final ScrollController _frameListScrollController = ScrollController();

  ArmRecording get _currentRec {
    if (_recordings.isEmpty) {
      return ArmRecording(id: 'default', name: 'Rekaman Kosong');
    }
    if (_selectedRecIndex >= _recordings.length) {
      _selectedRecIndex = 0;
    }
    return _recordings[_selectedRecIndex];
  }

  ArmFrame? get _selectedFrame {
    if (_currentRec.frames.isEmpty) return null;
    if (_selectedFrameIndex >= _currentRec.frames.length) {
      _selectedFrameIndex = _currentRec.frames.length - 1;
    }
    if (_selectedFrameIndex < 0) return null;
    return _currentRec.frames[_selectedFrameIndex];
  }

  @override
  void initState() {
    super.initState();
    _isConnected = _bt.isConnected;
    _bt.isConnectedNotifier.addListener(_onBtConnectionChanged);
    _loadAllRecordings();
  }

  void _onBtConnectionChanged() {
    if (!mounted) return;
    setState(() {
      _isConnected = _bt.isConnected;
    });
  }

  @override
  void dispose() {
    _stopRequested = true;
    _bt.isConnectedNotifier.removeListener(_onBtConnectionChanged);
    _noteController.dispose();
    _frameListScrollController.dispose();
    super.dispose();
  }

  // ==========================================================================
  // KONEKSI BLUETOOTH
  // ==========================================================================
  void _showBluetoothDialog() {
    BluetoothDialog.show(context);
  }

  // ==========================================================================
  // STORAGE & DATA SYNC
  // ==========================================================================
  Future<void> _loadAllRecordings() async {
    setState(() => _isLoading = true);
    final list = await RecordingStorage.loadRecordings();
    if (!mounted) return;
    setState(() {
      _recordings = list;
      _selectedRecIndex = 0;
      _selectedFrameIndex = 0;
      _isLoading = false;
      _syncEditBufferWithSelectedFrame();
    });
  }

  Future<void> _saveCurrentState({bool showFeedback = false}) async {
    await RecordingStorage.saveRecordings(_recordings);
    if (showFeedback && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✓ Rekaman tersimpan ke memori!'),
          duration: Duration(milliseconds: 1200),
          backgroundColor: Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _syncEditBufferWithSelectedFrame() {
    final frame = _selectedFrame;
    if (frame != null) {
      setState(() {
        _editS1 = frame.servo1;
        _editS2 = frame.servo2;
        _editS3 = frame.servo3;
        _editDelayMs = frame.delayMs;
        _noteController.text = frame.note;
      });
    }
  }

  void _applyEditBufferToSelectedFrame() {
    final frame = _selectedFrame;
    if (frame != null) {
      setState(() {
        frame.servo1 = _editS1;
        frame.servo2 = _editS2;
        frame.servo3 = _editS3;
        frame.delayMs = _editDelayMs;
        frame.note = _noteController.text.trim();
        _currentRec.updatedAt = DateTime.now();
      });
      _saveCurrentState();
    }
  }

  // ==========================================================================
  // MANAJEMEN FRAME
  // ==========================================================================
  void _addNewFrame({bool duplicateCurrent = false}) {
    if (_isPlaying) return;

    ArmFrame newFrame;
    if (duplicateCurrent && _selectedFrame != null) {
      newFrame = _selectedFrame!.copyWith(
        note: '${_selectedFrame!.note} (Salin)',
      );
    } else {
      newFrame = ArmFrame(
        servo1: _editS1,
        servo2: _editS2,
        servo3: _editS3,
        delayMs: _editDelayMs,
        note: 'Frame ${_currentRec.frames.length + 1}',
      );
    }

    setState(() {
      _currentRec.frames.add(newFrame);
      _selectedFrameIndex = _currentRec.frames.length - 1;
      _syncEditBufferWithSelectedFrame();
    });
    _saveCurrentState();

    Future.delayed(const Duration(milliseconds: 100), () {
      if (_frameListScrollController.hasClients) {
        _frameListScrollController.animateTo(
          _frameListScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _deleteFrame(int index) {
    if (_isPlaying) return;
    if (_currentRec.frames.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Minimal harus ada 1 frame dalam rekaman.'),
          backgroundColor: Color(0xFFEF4444),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _currentRec.frames.removeAt(index);
      if (_selectedFrameIndex >= _currentRec.frames.length) {
        _selectedFrameIndex = _currentRec.frames.length - 1;
      }
      _syncEditBufferWithSelectedFrame();
    });
    _saveCurrentState();
  }

  void _moveFrame(int oldIndex, int newIndex) {
    if (_isPlaying) return;
    if (newIndex < 0 || newIndex >= _currentRec.frames.length) return;

    setState(() {
      final item = _currentRec.frames.removeAt(oldIndex);
      _currentRec.frames.insert(newIndex, item);
      _selectedFrameIndex = newIndex;
      _syncEditBufferWithSelectedFrame();
    });
    _saveCurrentState();
  }

  void _showSetFrameCountDialog() {
    if (_isPlaying) return;
    final int currentCount = _currentRec.frames.length;
    int targetCount = currentCount;
    final controller = TextEditingController(text: currentCount.toString());

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.tune_rounded, color: Color(0xFF38BDF8), size: 18),
              SizedBox(width: 8),
              Text(
                'Atur Jumlah Frame',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saat ini terdapat $currentCount frame. Tentukan total frame rekaman:',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filledTonal(
                      onPressed: () {
                        if (targetCount > 1) {
                          setDialogState(() {
                            targetCount--;
                            controller.text = targetCount.toString();
                          });
                        }
                      },
                      icon: const Icon(Icons.remove, size: 18),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 75,
                      child: TextField(
                        controller: controller,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                        ),
                        onChanged: (val) {
                          final parsed = int.tryParse(val);
                          if (parsed != null && parsed >= 1 && parsed <= 50) {
                            setDialogState(() => targetCount = parsed);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton.filledTonal(
                      onPressed: () {
                        if (targetCount < 50) {
                          setDialogState(() {
                            targetCount++;
                            controller.text = targetCount.toString();
                          });
                        }
                      },
                      icon: const Icon(Icons.add, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    targetCount > currentCount
                        ? '+ Menambahkan ${targetCount - currentCount} frame baru'
                        : targetCount < currentCount
                            ? '- Memangkas ${currentCount - targetCount} frame terakhir'
                            : 'Jumlah frame tetap sama',
                    style: TextStyle(
                      fontSize: 11,
                      color: targetCount == currentCount ? Colors.white38 : const Color(0xFF38BDF8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                final count = int.tryParse(controller.text) ?? targetCount;
                if (count >= 1 && count <= 50) {
                  _applyFrameCountChange(count);
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Terapkan'),
            ),
          ],
        ),
      ),
    );
  }

  void _applyFrameCountChange(int newCount) {
    if (newCount == _currentRec.frames.length) return;

    setState(() {
      if (newCount > _currentRec.frames.length) {
        final last = _currentRec.frames.isNotEmpty
            ? _currentRec.frames.last
            : ArmFrame();
        final toAdd = newCount - _currentRec.frames.length;
        for (int i = 0; i < toAdd; i++) {
          _currentRec.frames.add(last.copyWith(
            note: 'Frame ${_currentRec.frames.length + 1}',
          ));
        }
      } else {
        _currentRec.frames = _currentRec.frames.sublist(0, newCount);
        if (_selectedFrameIndex >= newCount) {
          _selectedFrameIndex = newCount - 1;
        }
      }
      _syncEditBufferWithSelectedFrame();
    });
    _saveCurrentState(showFeedback: true);
  }

  // ==========================================================================
  // MANAJEMEN BANYAK REKAMAN
  // ==========================================================================
  void _createNewRecordingDialog() {
    if (_isPlaying) return;
    final nameCtrl = TextEditingController(
      text: 'Rekaman ${_recordings.length + 1}',
    );
    int initialFrames = 4;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Buat Rekaman Baru', style: TextStyle(color: Colors.white, fontSize: 15)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Nama Rekaman',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Jumlah Frame Awal:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove, size: 16),
                        onPressed: initialFrames > 1
                            ? () => setDlgState(() => initialFrames--)
                            : null,
                      ),
                      Text('$initialFrames', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF38BDF8))),
                      IconButton(
                        icon: const Icon(Icons.add, size: 16),
                        onPressed: initialFrames < 20
                            ? () => setDlgState(() => initialFrames++)
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isNotEmpty) {
                  final frames = List.generate(
                    initialFrames,
                    (i) => ArmFrame(
                      servo1: 0,
                      servo2: 90,
                      servo3: 90,
                      delayMs: 1000,
                      note: 'Frame ${i + 1}',
                    ),
                  );

                  final newRec = ArmRecording(
                    id: 'rec_${DateTime.now().millisecondsSinceEpoch}',
                    name: name,
                    frames: frames,
                  );

                  setState(() {
                    _recordings.add(newRec);
                    _selectedRecIndex = _recordings.length - 1;
                    _selectedFrameIndex = 0;
                    _syncEditBufferWithSelectedFrame();
                  });
                  _saveCurrentState(showFeedback: true);
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Buat Rekaman'),
            ),
          ],
        ),
      ),
    );
  }

  void _renameCurrentRecordingDialog() {
    if (_isPlaying) return;
    final nameCtrl = TextEditingController(text: _currentRec.name);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Ubah Nama Rekaman', style: TextStyle(color: Colors.white, fontSize: 15)),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nama Rekaman', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isNotEmpty) {
                setState(() {
                  _currentRec.name = nameCtrl.text.trim();
                });
                _saveCurrentState();
                Navigator.pop(ctx);
              }
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
  }

  void _deleteCurrentRecording() {
    if (_isPlaying) return;
    if (_recordings.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Minimal harus ada 1 rekaman tersimpan.'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Hapus Rekaman?', style: TextStyle(color: Colors.white, fontSize: 15)),
        content: Text('Hapus rekaman "${_currentRec.name}" beserta seluruh framenya?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () {
              setState(() {
                _recordings.removeAt(_selectedRecIndex);
                if (_selectedRecIndex >= _recordings.length) {
                  _selectedRecIndex = _recordings.length - 1;
                }
                _selectedFrameIndex = 0;
                _syncEditBufferWithSelectedFrame();
              });
              _saveCurrentState(showFeedback: true);
              Navigator.pop(ctx);
            },
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
  }

  void _duplicateCurrentRecording() {
    if (_isPlaying) return;
    final dup = _currentRec.copyWith(
      id: 'rec_${DateTime.now().millisecondsSinceEpoch}',
      name: '${_currentRec.name} (Salin)',
      updatedAt: DateTime.now(),
    );

    setState(() {
      _recordings.add(dup);
      _selectedRecIndex = _recordings.length - 1;
      _selectedFrameIndex = 0;
      _syncEditBufferWithSelectedFrame();
    });
    _saveCurrentState(showFeedback: true);
  }

  // ==========================================================================
  // AMBIL POSISI LIVE ROBOT
  // ==========================================================================
  Future<void> _captureCurrentRobotPose() async {
    if (_bt.isConnected) {
      final f = _bt.currentAnglesNotifier.value;
      setState(() {
        _isConnected = true;
        _editS1 = f.servo1;
        _editS2 = f.servo2;
        _editS3 = f.servo3;
      });
      _applyEditBufferToSelectedFrame();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✓ Posisi live robot berhasil disalin ke frame!'),
          backgroundColor: Color(0xFF10B981),
          duration: Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✕ Robot belum terhubung via Bluetooth'),
          backgroundColor: Color(0xFFEF4444),
          duration: Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ==========================================================================
  // PEMUTARAN OTOMATIS
  // ==========================================================================
  Future<void> _startPlayback() async {
    if (_currentRec.frames.isEmpty) return;

    if (_isPaused) {
      setState(() {
        _isPaused = false;
        _isPlaying = true;
      });
      return;
    }

    setState(() {
      _isPlaying = true;
      _isPaused = false;
      _stopRequested = false;
      _currentPlayingIndex = 0;
    });

    final rec = _currentRec;

    do {
      for (int i = 0; i < rec.frames.length; i++) {
        if (_stopRequested || !mounted) break;

        while (_isPaused && !_stopRequested && mounted) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (_stopRequested || !mounted) break;

        final frame = rec.frames[i];
        setState(() {
          _currentPlayingIndex = i;
        });

        // Kirim ke robot via Bluetooth
        await _bt.sendFrame(frame);

        // Tunggu jeda
        final adjustedDelay = (frame.delayMs / rec.speedMultiplier).round();
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < adjustedDelay) {
          if (_stopRequested || !mounted) break;
          while (_isPaused && !_stopRequested && mounted) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }
    } while (rec.isLoop && !_stopRequested && mounted);

    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isPaused = false;
        _stopRequested = false;
        _currentPlayingIndex = -1;
      });
    }
  }

  void _pausePlayback() {
    setState(() => _isPaused = true);
  }

  void _stopPlayback() {
    setState(() {
      _stopRequested = true;
      _isPlaying = false;
      _isPaused = false;
      _currentPlayingIndex = -1;
    });
  }

  Future<void> _testFrame(ArmFrame frame) async {
    final success = await _bt.sendFrame(frame);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? '✓ S1:${frame.servo1}° S2:${frame.servo2}° S3:${frame.servo3}° dikirim ke robot'
                : '✕ Gagal terhubung ke ESP32 Bluetooth',
          ),
          duration: const Duration(milliseconds: 1000),
          backgroundColor: success ? const Color(0xFF10B981) : const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ==========================================================================
  // BUILD UI UTAMA (BEBAS OVERFLOW & RAPI)
  // ==========================================================================
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B0F19),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Column(
          children: [
            // 1. TOP BAR COMPACT
            _buildTopBar(),

            // 2. MAIN WORKSPACE (SPLIT 2 PANEL)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // PANEL KIRI: DAFTAR / TIMELINE FRAME (38% WIDTH)
                    Expanded(
                      flex: 38,
                      child: _buildFrameListPanel(),
                    ),

                    const SizedBox(width: 8),

                    // PANEL KANAN: FRAME EDITOR & SEQUENCER PLAYER (62% WIDTH)
                    Expanded(
                      flex: 62,
                      child: _buildFrameEditorAndPlayerPanel(),
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

  // ==========================================================================
  // 1. TOP BAR (COMPACT & OVERFLOW-SAFE)
  // ==========================================================================
  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        color: Color(0xFF131B2E),
        border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
      ),
      child: Row(
        children: [
          // Tombol Kembali
          InkWell(
            onTap: () {
              if (_isPlaying) _stopPlayback();
              Navigator.pop(context);
            },
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_back_rounded, size: 13, color: Colors.white70),
                  SizedBox(width: 4),
                  Text('Manual', style: TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),

          const SizedBox(width: 6),

          // Badge Otomatis
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFA855F7).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: const Color(0xFFA855F7), width: 0.8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_mode_rounded, size: 12, color: Color(0xFFA855F7)),
                SizedBox(width: 3),
                Text(
                  'OTOMATIS',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.6,
                    color: Color(0xFFA855F7),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 6),

          // Status Bluetooth Online/Offline
          InkWell(
            onTap: _showBluetoothDialog,
            borderRadius: BorderRadius.circular(5),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _isConnected
                    ? const Color(0xFF0284C7).withValues(alpha: 0.2)
                    : Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: _isConnected ? const Color(0xFF38BDF8) : Colors.redAccent,
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                    size: 11,
                    color: _isConnected ? const Color(0xFF38BDF8) : Colors.redAccent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isConnected ? 'BT Online' : 'BT Offline',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                      color: _isConnected ? const Color(0xFF38BDF8) : Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 6),

          // Selector Rekaman Aktif (Dropdown Rapi)
          Expanded(
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _selectedRecIndex < _recordings.length ? _selectedRecIndex : 0,
                  dropdownColor: const Color(0xFF1E293B),
                  isDense: true,
                  icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF38BDF8), size: 18),
                  items: List.generate(_recordings.length, (idx) {
                    final rec = _recordings[idx];
                    return DropdownMenuItem<int>(
                      value: idx,
                      child: Text(
                        '🎬 ${rec.name} (${rec.frames.length} Frame)',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    );
                  }),
                  onChanged: _isPlaying
                      ? null
                      : (newIndex) {
                          if (newIndex != null) {
                            setState(() {
                              _selectedRecIndex = newIndex;
                              _selectedFrameIndex = 0;
                              _syncEditBufferWithSelectedFrame();
                            });
                          }
                        },
                ),
              ),
            ),
          ),

          const SizedBox(width: 4),

          // Tombol Tambah Rekaman
          IconButton(
            onPressed: _isPlaying ? null : _createNewRecordingDialog,
            icon: const Icon(Icons.add_rounded, size: 16, color: Color(0xFF38BDF8)),
            tooltip: 'Buat Rekaman Baru',
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF1E293B),
              side: const BorderSide(color: Color(0xFF334155)),
            ),
          ),

          const SizedBox(width: 3),

          // Menu Opsi Rekaman
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, size: 15, color: Colors.white70),
            color: const Color(0xFF1E293B),
            tooltip: 'Opsi Rekaman',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF1E293B),
              side: const BorderSide(color: Color(0xFF334155)),
            ),
            onSelected: (val) {
              if (val == 'rename') _renameCurrentRecordingDialog();
              if (val == 'duplicate') _duplicateCurrentRecording();
              if (val == 'delete') _deleteCurrentRecording();
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'rename',
                height: 32,
                child: Row(
                  children: [
                    Icon(Icons.edit_rounded, size: 14, color: Colors.white70),
                    SizedBox(width: 6),
                    Text('Ubah Nama', style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'duplicate',
                height: 32,
                child: Row(
                  children: [
                    Icon(Icons.copy_rounded, size: 14, color: Colors.white70),
                    SizedBox(width: 6),
                    Text('Duplikat Rekaman', style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                height: 32,
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, size: 14, color: Color(0xFFEF4444)),
                    SizedBox(width: 6),
                    Text('Hapus Rekaman', style: TextStyle(fontSize: 11, color: Color(0xFFEF4444))),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(width: 4),

          // Tombol Simpan
          FilledButton.icon(
            onPressed: () => _saveCurrentState(showFeedback: true),
            icon: const Icon(Icons.save_rounded, size: 13),
            label: const Text('Simpan', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              minimumSize: const Size(0, 26),
              backgroundColor: const Color(0xFF0284C7),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // 2. PANEL KIRI: DAFTAR / TIMELINE FRAME (38% WIDTH)
  // ==========================================================================
  Widget _buildFrameListPanel() {
    final frames = _currentRec.frames;

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFF151E2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF243247)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar Timeline
          Row(
            children: [
              const Text(
                'Urutan Frame',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF38BDF8), width: 0.7),
                ),
                child: Text(
                  '${frames.length}',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ),
              const Spacer(),
              // Tombol Atur Jumlah
              OutlinedButton(
                onPressed: _isPlaying ? null : _showSetFrameCountDialog,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                  minimumSize: const Size(0, 24),
                  side: const BorderSide(color: Color(0xFF334155)),
                  foregroundColor: Colors.white70,
                ),
                child: const Text('Jumlah', style: TextStyle(fontSize: 9.5)),
              ),
              const SizedBox(width: 3),
              // Tombol Tambah Frame
              FilledButton(
                onPressed: _isPlaying ? null : () => _addNewFrame(),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 0),
                  minimumSize: const Size(0, 24),
                  backgroundColor: const Color(0xFF10B981),
                ),
                child: const Text('+ Frame', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold)),
              ),
            ],
          ),

          const SizedBox(height: 5),

          // Scrollable List Frame
          Expanded(
            child: frames.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.layers_clear_outlined, size: 28, color: Colors.white24),
                        const SizedBox(height: 4),
                        const Text('Belum ada frame', style: TextStyle(fontSize: 10, color: Colors.white54)),
                        const SizedBox(height: 6),
                        FilledButton(
                          onPressed: () => _addNewFrame(),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                            minimumSize: const Size(0, 24),
                          ),
                          child: const Text('+ Frame Pertama', style: TextStyle(fontSize: 10)),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    controller: _frameListScrollController,
                    itemCount: frames.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 3),
                    itemBuilder: (context, index) {
                      final frame = frames[index];
                      final isSelected = index == _selectedFrameIndex;
                      final isCurrentPlaying = index == _currentPlayingIndex;

                      return _buildFrameCard(
                        frame: frame,
                        index: index,
                        totalFrames: frames.length,
                        isSelected: isSelected,
                        isPlaying: isCurrentPlaying,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // Single Frame Card
  Widget _buildFrameCard({
    required ArmFrame frame,
    required int index,
    required int totalFrames,
    required bool isSelected,
    required bool isPlaying,
  }) {
    Color borderColor;
    Color bgColor;

    if (isPlaying) {
      borderColor = const Color(0xFF10B981);
      bgColor = const Color(0xFF10B981).withValues(alpha: 0.15);
    } else if (isSelected) {
      borderColor = const Color(0xFF38BDF8);
      bgColor = const Color(0xFF0284C7).withValues(alpha: 0.12);
    } else {
      borderColor = const Color(0xFF243247);
      bgColor = const Color(0xFF0F172A);
    }

    final isBoxOpen = frame.servo1 >= 15;

    return InkWell(
      onTap: () {
        if (!_isPlaying) {
          setState(() {
            _selectedFrameIndex = index;
            _syncEditBufferWithSelectedFrame();
          });
        }
      },
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: borderColor,
            width: isPlaying ? 1.8 : (isSelected ? 1.4 : 0.8),
          ),
        ),
        child: Row(
          children: [
            // Badge Nomor Frame
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isPlaying
                    ? const Color(0xFF10B981)
                    : (isSelected ? const Color(0xFF38BDF8) : const Color(0xFF1E293B)),
              ),
              child: Center(
                child: isPlaying
                    ? const Icon(Icons.play_arrow_rounded, size: 14, color: Colors.black)
                    : Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isSelected ? Colors.black : Colors.white70,
                        ),
                      ),
              ),
            ),

            const SizedBox(width: 6),

            // Deskripsi & Nilai Frame
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          frame.note.isNotEmpty ? frame.note : 'Frame #${index + 1}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isPlaying ? const Color(0xFF10B981) : (isSelected ? Colors.white : Colors.white70),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${(frame.delayMs / 1000).toStringAsFixed(1)}s',
                        style: const TextStyle(fontSize: 8.5, color: Color(0xFFF59E0B), fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // Baris Tag Sudut Servo
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _badgeMini(
                          'Box:${isBoxOpen ? "30°" : "0°"}',
                          isBoxOpen ? const Color(0xFF38BDF8) : Colors.white60,
                        ),
                        const SizedBox(width: 3),
                        _badgeMini('J:${frame.servo2}°', const Color(0xFF10B981)),
                        const SizedBox(width: 3),
                        _badgeMini('B:${frame.servo3}°', const Color(0xFFA855F7)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 4),

            // Tombol Uji Langsung
            IconButton(
              icon: const Icon(Icons.send_rounded, size: 12, color: Color(0xFF38BDF8)),
              tooltip: 'Uji Frame Ini',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              onPressed: () => _testFrame(frame),
            ),

            // Tombol Pindah Urutan
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: index > 0 && !_isPlaying ? () => _moveFrame(index, index - 1) : null,
                  child: Icon(
                    Icons.arrow_drop_up_rounded,
                    size: 15,
                    color: index > 0 && !_isPlaying ? Colors.white70 : Colors.white24,
                  ),
                ),
                InkWell(
                  onTap: index < totalFrames - 1 && !_isPlaying ? () => _moveFrame(index, index + 1) : null,
                  child: Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 15,
                    color: index < totalFrames - 1 && !_isPlaying ? Colors.white70 : Colors.white24,
                  ),
                ),
              ],
            ),

            // Tombol Hapus Frame
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 12, color: Colors.white38),
              tooltip: 'Hapus Frame',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              onPressed: _isPlaying ? null : () => _deleteFrame(index),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badgeMini(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 0.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 8, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }

  // ==========================================================================
  // 3. PANEL KANAN: EDITOR FRAME & SEQUENCER PLAYER (62% WIDTH)
  // ==========================================================================
  Widget _buildFrameEditorAndPlayerPanel() {
    final frame = _selectedFrame;

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFF151E2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF243247)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // KONTEN EDITOR FRAME (DENGAN SCROLL AGAR TIDAK PERNAH OVERFLOW)
          Expanded(
            child: frame == null
                ? const Center(child: Text('Pilih frame untuk mengedit', style: TextStyle(color: Colors.white54, fontSize: 11)))
                : SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // BARIS 1: HEADER FRAME & NAMA FRAME
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: const Color(0xFF38BDF8), width: 0.8),
                              ),
                              child: Text(
                                'FRAME #${_selectedFrameIndex + 1}',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF38BDF8),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // Input Label Frame
                            Expanded(
                              child: SizedBox(
                                height: 26,
                                child: TextField(
                                  controller: _noteController,
                                  style: const TextStyle(fontSize: 10.5, color: Colors.white),
                                  decoration: InputDecoration(
                                    hintText: 'Beri keterangan (misal: Ambil Box)...',
                                    hintStyle: const TextStyle(fontSize: 10, color: Colors.white38),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(5),
                                      borderSide: const BorderSide(color: Color(0xFF334155)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(5),
                                      borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                                    ),
                                  ),
                                  onChanged: (_) => _applyEditBufferToSelectedFrame(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Tombol Tangkap Robot
                            OutlinedButton.icon(
                              onPressed: _captureCurrentRobotPose,
                              icon: const Icon(Icons.camera_alt_outlined, size: 11),
                              label: const Text('Tangkap Robot', style: TextStyle(fontSize: 9.5)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                                minimumSize: const Size(0, 26),
                                side: const BorderSide(color: Color(0xFF334155)),
                                foregroundColor: Colors.white70,
                              ),
                            ),
                            const SizedBox(width: 3),
                            // Tombol Uji Live
                            FilledButton.icon(
                              onPressed: () {
                                _applyEditBufferToSelectedFrame();
                                _testFrame(_selectedFrame!);
                              },
                              icon: const Icon(Icons.play_circle_outline_rounded, size: 12),
                              label: const Text('Uji Live', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold)),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 0),
                                minimumSize: const Size(0, 26),
                                backgroundColor: const Color(0xFF0284C7),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 6),

                        // BARIS 2: SERVO 1 - PENGANGKAT BOX (PIN 18)
                        _buildBoxServoRow(),

                        const SizedBox(height: 5),

                        // BARIS 3: SERVO 2 - ARM JOINT (PIN 26)
                        _buildJointServoRow(),

                        const SizedBox(height: 5),

                        // BARIS 4: SERVO 3 - BASE ROTATION (PIN 21)
                        _buildBaseServoRow(),

                        const SizedBox(height: 5),

                        // BARIS 5: JEDA (DELAY MS)
                        _buildDelayRow(),
                      ],
                    ),
                  ),
          ),

          const Divider(height: 8, color: Color(0xFF243247)),

          // PLAYER BAR DI BAGIAN PALING BAWAH
          _buildPlayerBar(),
        ],
      ),
    );
  }

  // ==========================================================================
  // ROW 1: KONTROL SERVO 1 (PENGANGKAT BOX)
  // ==========================================================================
  Widget _buildBoxServoRow() {
    final bool isOpen = _editS1 >= 15;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        children: [
          // Label Servo 1
          SizedBox(
            width: 95,
            child: Row(
              children: [
                const Icon(Icons.unfold_more_rounded, size: 14, color: Color(0xFF38BDF8)),
                const SizedBox(width: 4),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Box (Pin 18)', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white)),
                    Text(
                      isOpen ? 'Buka (30°)' : 'Tutup (0°)',
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: isOpen ? const Color(0xFF38BDF8) : Colors.white60,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Tombol Buka
          Expanded(
            child: SizedBox(
              height: 26,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: isOpen ? const Color(0xFF38BDF8).withValues(alpha: 0.2) : Colors.transparent,
                  side: BorderSide(color: isOpen ? const Color(0xFF38BDF8) : const Color(0xFF334155)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                ),
                onPressed: () {
                  setState(() => _editS1 = 30);
                  _applyEditBufferToSelectedFrame();
                },
                child: Text(
                  'BUKA (30°)',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: isOpen ? FontWeight.bold : FontWeight.normal,
                    color: isOpen ? const Color(0xFF38BDF8) : Colors.white60,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(width: 6),

          // Tombol Tutup
          Expanded(
            child: SizedBox(
              height: 26,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: !isOpen ? const Color(0xFF38BDF8).withValues(alpha: 0.2) : Colors.transparent,
                  side: BorderSide(color: !isOpen ? const Color(0xFF38BDF8) : const Color(0xFF334155)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                ),
                onPressed: () {
                  setState(() => _editS1 = 0);
                  _applyEditBufferToSelectedFrame();
                },
                child: Text(
                  'TUTUP (0°)',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: !isOpen ? FontWeight.bold : FontWeight.normal,
                    color: !isOpen ? const Color(0xFF38BDF8) : Colors.white60,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // ROW 2: KONTROL SERVO 2 (ARM JOINT)
  // ==========================================================================
  Widget _buildJointServoRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        children: [
          // Label Servo 2
          SizedBox(
            width: 95,
            child: Row(
              children: [
                const Icon(Icons.fitness_center_rounded, size: 13, color: Color(0xFF10B981)),
                const SizedBox(width: 4),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Joint (Pin 26)', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white)),
                    Text(
                      '$_editS2°',
                      style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Slider
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: const Color(0xFF10B981),
                inactiveTrackColor: const Color(0xFF1E293B),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              ),
              child: Slider(
                value: _editS2.toDouble(),
                min: 0,
                max: 180,
                divisions: 180,
                onChanged: (val) {
                  setState(() => _editS2 = val.round());
                  _applyEditBufferToSelectedFrame();
                },
              ),
            ),
          ),

          // Preset Chips (5 Nilai)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _presetChip('0°', 0, _editS2, const Color(0xFF10B981), (v) {
                setState(() => _editS2 = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('45°', 45, _editS2, const Color(0xFF10B981), (v) {
                setState(() => _editS2 = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('90°', 90, _editS2, const Color(0xFF10B981), (v) {
                setState(() => _editS2 = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('135°', 135, _editS2, const Color(0xFF10B981), (v) {
                setState(() => _editS2 = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('180°', 180, _editS2, const Color(0xFF10B981), (v) {
                setState(() => _editS2 = v);
                _applyEditBufferToSelectedFrame();
              }),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // ROW 3: KONTROL SERVO 3 (BASE ROTATION)
  // ==========================================================================
  Widget _buildBaseServoRow() {
    String dirText = _editS3 < 85 ? 'Kiri' : (_editS3 > 95 ? 'Kanan' : 'Tengah');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        children: [
          // Label Servo 3
          SizedBox(
            width: 95,
            child: Row(
              children: [
                const Icon(Icons.sync_rounded, size: 14, color: Color(0xFFA855F7)),
                const SizedBox(width: 4),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Base (Pin 21)', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white)),
                    Text(
                      '$_editS3° ($dirText)',
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFFA855F7)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Slider
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: const Color(0xFFA855F7),
                inactiveTrackColor: const Color(0xFF1E293B),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              ),
              child: Slider(
                value: _editS3.toDouble(),
                min: 0,
                max: 180,
                divisions: 180,
                onChanged: (val) {
                  setState(() => _editS3 = val.round());
                  _applyEditBufferToSelectedFrame();
                },
              ),
            ),
          ),

          // Preset Chips (Kiri, Tengah, Kanan)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _presetChip('0° Kiri', 0, _editS3, const Color(0xFFA855F7), (v) {
                setState(() => _editS3 = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('90° Netral', 90, _editS3, const Color(0xFFA855F7), (v) {
                setState(() => _editS3 = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('180° Kanan', 180, _editS3, const Color(0xFFA855F7), (v) {
                setState(() => _editS3 = v);
                _applyEditBufferToSelectedFrame();
              }),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // ROW 4: KONTROL JEDA (DELAY MS)
  // ==========================================================================
  Widget _buildDelayRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        children: [
          // Label Delay
          SizedBox(
            width: 95,
            child: Row(
              children: [
                const Icon(Icons.timer_outlined, size: 14, color: Color(0xFFF59E0B)),
                const SizedBox(width: 4),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Jeda Frame', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white)),
                    Text(
                      '${(_editDelayMs / 1000).toStringAsFixed(1)}s (${_editDelayMs}ms)',
                      style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Color(0xFFF59E0B)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Slider
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: const Color(0xFFF59E0B),
                inactiveTrackColor: const Color(0xFF1E293B),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              ),
              child: Slider(
                value: _editDelayMs.toDouble().clamp(200, 5000),
                min: 200,
                max: 5000,
                divisions: 48,
                onChanged: (val) {
                  setState(() => _editDelayMs = val.round());
                  _applyEditBufferToSelectedFrame();
                },
              ),
            ),
          ),

          // Preset Chips Delay
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _presetChip('0.5s', 500, _editDelayMs, const Color(0xFFF59E0B), (v) {
                setState(() => _editDelayMs = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('1.0s', 1000, _editDelayMs, const Color(0xFFF59E0B), (v) {
                setState(() => _editDelayMs = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('1.5s', 1500, _editDelayMs, const Color(0xFFF59E0B), (v) {
                setState(() => _editDelayMs = v);
                _applyEditBufferToSelectedFrame();
              }),
              const SizedBox(width: 2),
              _presetChip('2.0s', 2000, _editDelayMs, const Color(0xFFF59E0B), (v) {
                setState(() => _editDelayMs = v);
                _applyEditBufferToSelectedFrame();
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _presetChip(String label, int val, int currentVal, Color color, Function(int) onSelect) {
    final isSelected = currentVal == val;
    return InkWell(
      onTap: () => onSelect(val),
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.22) : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: isSelected ? color : const Color(0xFF334155), width: 0.8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? color : Colors.white60,
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // PLAYER BAR (BOTTOM CONTROLLER)
  // ==========================================================================
  Widget _buildPlayerBar() {
    final rec = _currentRec;
    final totalDuration = rec.totalDurationSeconds;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        children: [
          // Status Live
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isPlaying
                        ? (_isPaused ? const Color(0xFFF59E0B) : const Color(0xFF10B981))
                        : Colors.white24,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isPlaying
                            ? (_isPaused
                                ? 'Dijeda di Frame ${_currentPlayingIndex + 1}/${rec.frames.length}'
                                : 'Memutar Frame ${_currentPlayingIndex + 1}/${rec.frames.length}...')
                            : 'Siap (${rec.frames.length} Frame • ~${totalDuration.toStringAsFixed(1)}s)',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          color: _isPlaying ? const Color(0xFF10B981) : Colors.white70,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_isPlaying) ...[
                        const SizedBox(height: 2),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: rec.frames.isNotEmpty
                                ? ((_currentPlayingIndex + 1) / rec.frames.length).clamp(0.0, 1.0)
                                : 0.0,
                            minHeight: 2,
                            backgroundColor: const Color(0xFF1E293B),
                            valueColor: const AlwaysStoppedAnimation(Color(0xFF10B981)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 6),

          // Tombol Loop
          OutlinedButton.icon(
            onPressed: () {
              setState(() => rec.isLoop = !rec.isLoop);
              _saveCurrentState();
            },
            icon: Icon(
              Icons.loop_rounded,
              size: 11,
              color: rec.isLoop ? const Color(0xFF38BDF8) : Colors.white38,
            ),
            label: Text(
              rec.isLoop ? 'Loop: ON' : 'Loop: OFF',
              style: TextStyle(
                fontSize: 9,
                fontWeight: rec.isLoop ? FontWeight.bold : FontWeight.normal,
                color: rec.isLoop ? const Color(0xFF38BDF8) : Colors.white54,
              ),
            ),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
              minimumSize: const Size(0, 26),
              side: BorderSide(
                color: rec.isLoop ? const Color(0xFF38BDF8) : const Color(0xFF334155),
              ),
            ),
          ),

          const SizedBox(width: 4),

          // Tombol Home Reset
          OutlinedButton(
            onPressed: () => _bt.resetHome(),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
              minimumSize: const Size(0, 26),
              side: const BorderSide(color: Color(0xFF334155)),
            ),
            child: const Text('Home', style: TextStyle(fontSize: 9, color: Colors.white70)),
          ),

          const SizedBox(width: 4),

          // Tombol STOP (jika sedang memutar)
          if (_isPlaying) ...[
            FilledButton(
              onPressed: _stopPlayback,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                minimumSize: const Size(0, 26),
              ),
              child: const Text('STOP', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 4),
          ],

          // Tombol Play / Pause Utama
          FilledButton.icon(
            onPressed: rec.frames.isEmpty
                ? null
                : (_isPlaying
                    ? (_isPaused ? _startPlayback : _pausePlayback)
                    : _startPlayback),
            icon: Icon(
              _isPlaying
                  ? (_isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded)
                  : Icons.play_arrow_rounded,
              size: 14,
            ),
            label: Text(
              _isPlaying
                  ? (_isPaused ? 'LANJUT' : 'JEDA')
                  : 'JALANKAN',
              style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, letterSpacing: 0.4),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _isPlaying && !_isPaused
                  ? const Color(0xFFF59E0B)
                  : const Color(0xFF10B981),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              minimumSize: const Size(0, 28),
            ),
          ),
        ],
      ),
    );
  }
}
