#include <Arduino.h>
#include <esp_now.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_arduino_version.h>

// ==========================================
// ESP32 CONVEYOR RECEIVER (ESP-NOW SLAVE)
// Menerima perintah nirkabel dari ESP32 Master Arm
// Kontrol Motor Driver: GPIO 16, 17, 18, 19
// ==========================================

// 1. Deklarasi pin output motor sesuai wiring
const int IN1_A = 16; // Pin IN1 Driver (Motor A)
const int IN2_A = 17; // Pin IN2 Driver (Motor A)
const int IN1_B = 18; // Pin IN3 Driver (Motor B)
const int IN2_B = 19; // Pin IN4 Driver (Motor B)

// 2. Konfigurasi parameter PWM
const int frekuensi = 5000; // Frekuensi sinyal PWM 5000 Hz
const int resolusi = 8;     // Resolusi 8-bit (Rentang 0 - 255)

// 3. Struktur Paket Data ESP-NOW (Harus identik dengan Master)
typedef struct __attribute__((packed)) {
  uint8_t mode;      // 0: STOP, 1: MANUAL_RUN, 2: AUTO_CYCLE
  uint16_t runMs;    // Durasi jalan (contoh: 170 ms)
  uint16_t stopMs;   // Durasi jeda berhenti (contoh: 3000 ms)
  uint8_t speed;     // Kecepatan PWM (0 - 255)
} ConveyorPacket;

// 4. Status & Variabel Operasional
volatile uint8_t currentMode = 0;       // 0: STOP, 1: RUN, 2: AUTO
volatile uint16_t currentRunMs = 170;   // Durasi jalan (ms)
volatile uint16_t currentStopMs = 3000; // Durasi jeda berhenti (ms)
volatile uint8_t currentSpeed = 255;    // Kecepatan motor (0 - 255)

// State machine non-blocking untuk Mode Otomatis
enum AutoSubState { AUTO_RUNNING, AUTO_STOPPED };
AutoSubState autoState = AUTO_RUNNING;
unsigned long lastCycleMillis = 0;

// Mengatur output motor A & B
void setMotors(uint8_t speed) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && (ESP_ARDUINO_VERSION_MAJOR >= 3)
  if (speed > 0) {
    ledcWrite(IN1_A, speed);
    ledcWrite(IN2_A, 0);
    ledcWrite(IN1_B, speed);
    ledcWrite(IN2_B, 0);
  } else {
    ledcWrite(IN1_A, 0);
    ledcWrite(IN2_A, 0);
    ledcWrite(IN1_B, 0);
    ledcWrite(IN2_B, 0);
  }
#else
  if (speed > 0) {
    ledcWrite(0, speed);
    ledcWrite(1, 0);
    ledcWrite(2, speed);
    ledcWrite(3, 0);
  } else {
    ledcWrite(0, 0);
    ledcWrite(1, 0);
    ledcWrite(2, 0);
    ledcWrite(3, 0);
  }
#endif
}

// Inisialisasi PWM Motor Driver
void initMotors() {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && (ESP_ARDUINO_VERSION_MAJOR >= 3)
  ledcAttach(IN1_A, frekuensi, resolusi);
  ledcAttach(IN2_A, frekuensi, resolusi);
  ledcAttach(IN1_B, frekuensi, resolusi);
  ledcAttach(IN2_B, frekuensi, resolusi);
#else
  ledcSetup(0, frekuensi, resolusi);
  ledcAttachPin(IN1_A, 0);
  ledcSetup(1, frekuensi, resolusi);
  ledcAttachPin(IN2_A, 1);
  ledcSetup(2, frekuensi, resolusi);
  ledcAttachPin(IN1_B, 2);
  ledcSetup(3, frekuensi, resolusi);
  ledcAttachPin(IN2_B, 3);
#endif
  setMotors(0);
}

// Callback Penerimaan Data ESP-NOW
#if defined(ESP_ARDUINO_VERSION_MAJOR) && (ESP_ARDUINO_VERSION_MAJOR >= 3)
void onDataRecv(const esp_now_recv_info_t *info, const uint8_t *incomingData, int len) {
#else
void onDataRecv(const uint8_t *mac, const uint8_t *incomingData, int len) {
#endif
  if (len == sizeof(ConveyorPacket)) {
    ConveyorPacket pkt;
    memcpy(&pkt, incomingData, sizeof(pkt));

    currentMode = pkt.mode;
    if (pkt.runMs > 0) currentRunMs = pkt.runMs;
    if (pkt.stopMs > 0) currentStopMs = pkt.stopMs;
    currentSpeed = (pkt.speed > 0 || pkt.mode == 0) ? pkt.speed : 255;

    lastCycleMillis = millis();

    if (currentMode == 0) {
      setMotors(0);
      Serial.println("[ESP-NOW RX] Perintah: STOP Total");
    } else if (currentMode == 1) {
      setMotors(currentSpeed);
      Serial.printf("[ESP-NOW RX] Perintah: RUN MANUAL (Kecepatan: %d)\n", currentSpeed);
    } else if (currentMode == 2) {
      autoState = AUTO_RUNNING;
      setMotors(currentSpeed);
      Serial.printf("[ESP-NOW RX] Perintah: AUTO CYCLE (Jalan: %d ms | Jeda: %d ms | Spd: %d)\n",
        currentRunMs, currentStopMs, currentSpeed);
    }
  }
}

// Dukungan pengujian manual via Serial Monitor USB
void processSerialCommand(String cmd) {
  cmd.trim();
  if (cmd.length() == 0) return;

  if (cmd.equalsIgnoreCase("STOP")) {
    currentMode = 0;
    setMotors(0);
    Serial.println("[MANUAL SERIAL] Conveyor STOP");
  } else if (cmd.equalsIgnoreCase("RUN")) {
    currentMode = 1;
    if (currentSpeed == 0) currentSpeed = 255;
    setMotors(currentSpeed);
    Serial.printf("[MANUAL SERIAL] Conveyor RUN (Speed: %d)\n", currentSpeed);
  } else if (cmd.startsWith("AUTO") || cmd.startsWith("auto")) {
    // Format: AUTO <runMs> <stopMs>
    int s1 = cmd.indexOf(' ');
    int s2 = s1 != -1 ? cmd.indexOf(' ', s1 + 1) : -1;
    if (s1 != -1) {
      int r = cmd.substring(s1 + 1, s2 != -1 ? s2 : cmd.length()).toInt();
      if (r > 0) currentRunMs = r;
      if (s2 != -1) {
        int st = cmd.substring(s2 + 1).toInt();
        if (st > 0) currentStopMs = st;
      }
    }
    currentMode = 2;
    autoState = AUTO_RUNNING;
    lastCycleMillis = millis();
    if (currentSpeed == 0) currentSpeed = 255;
    setMotors(currentSpeed);
    Serial.printf("[MANUAL SERIAL] Conveyor AUTO -> Jalan: %d ms | Jeda: %d ms\n", currentRunMs, currentStopMs);
  } else if (cmd.startsWith("SPEED") || cmd.startsWith("speed")) {
    int s = cmd.indexOf(' ');
    if (s != -1) {
      currentSpeed = constrain(cmd.substring(s + 1).toInt(), 0, 255);
      Serial.printf("[MANUAL SERIAL] Kecepatan diatur ke: %d\n", currentSpeed);
      if (currentMode == 1 || (currentMode == 2 && autoState == AUTO_RUNNING)) {
        setMotors(currentSpeed);
      }
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("\n=========================================");
  Serial.println("  ESP32 SLAVE: Penerima Motor Conveyor");
  Serial.println("  Pin Driver: IN1=16, IN2=17, IN3=18, IN4=19");
  Serial.println("=========================================");

  // Inisialisasi motor driver
  initMotors();

  // Inisialisasi WiFi Mode STA & Channel 1 untuk ESP-NOW
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);

  // Inisialisasi ESP-NOW
  if (esp_now_init() != ESP_OK) {
    Serial.println("[ERROR] Gagal inisialisasi ESP-NOW!");
    return;
  }
  Serial.println("[OK] ESP-NOW Receiver Berhasil diaktifkan!");

  // Daftarkan fungsi callback saat menerima data nirkabel
  esp_now_register_recv_cb(onDataRecv);

  Serial.println("--- Sistem Motor Conveyor Siap Menerima Perintah ---");
  Serial.println("[TIPS] Bisa ketik 'RUN', 'STOP', atau 'AUTO 170 3000' di Serial Monitor untuk tes!");
}

void loop() {
  // 1. Eksekusi State Machine Non-Blocking
  if (currentMode == 0) {
    // Mode STOP Total
    setMotors(0);
  } 
  else if (currentMode == 1) {
    // Mode RUN Terus Menerus
    setMotors(currentSpeed);
  } 
  else if (currentMode == 2) {
    // Mode AUTO CYCLE: Jalan X ms -> Jeda Y ms -> Jalan lagi otomatis!
    unsigned long now = millis();

    if (autoState == AUTO_RUNNING) {
      setMotors(currentSpeed);
      if (now - lastCycleMillis >= currentRunMs) {
        // Durasi jalan selesai -> Berhenti
        setMotors(0);
        autoState = AUTO_STOPPED;
        lastCycleMillis = now;
        Serial.printf("[AUTO] Waktu jalan (%d ms) selesai. Jeda berhenti %d ms...\n", currentRunMs, currentStopMs);
      }
    } 
    else if (autoState == AUTO_STOPPED) {
      setMotors(0);
      if (now - lastCycleMillis >= currentStopMs) {
        // Durasi jeda berhenti selesai -> Jalan otomatis kembali!
        autoState = AUTO_RUNNING;
        setMotors(currentSpeed);
        lastCycleMillis = now;
        Serial.printf("[AUTO] Jeda selesai! Otomatis jalan kembali selama %d ms...\n", currentRunMs);
      }
    }
  }

  // 2. Baca perintah dari Serial Monitor (USB) jika ada
  if (Serial.available()) {
    String cmd = Serial.readStringUntil('\n');
    processSerialCommand(cmd);
  }

  delay(5);
}

