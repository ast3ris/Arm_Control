#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_arduino_version.h>
#include <esp_now.h>
#include <WiFi.h>
#include <esp_wifi.h>

// ==========================================
// PENGATURAN 3 SERVO & PIN (18, 26, 21)
// MENGGUNAKAN NATIVE HARDWARE LEDC PWM (ESP32 CORE 3.x & 2.x)
// 100% Bebas Konflik Timer BLE & Bebas Bug ESP32Servo Library!
// ==========================================
const int pinServo1 = 18; // Pin 18 - Pengangkat Box (30° Buka / 0° Tutup)
const int pinServo2 = 26; // Pin 26 - Arm Joint (0° - 180°) [Diperbarui dari 19 ke 26]
const int pinServo3 = 21; // Pin 21 - Servo Bawah 180° (0° Kiri - 180° Kanan)

const int PWM_FREQ = 50;  // 50Hz Standar Servo Motor (periode 20ms / 20.000us)
const int PWM_RES  = 14;  // Resolusi 14-bit (0 s.d. 16383) - 100% kompatibel di semua varian clock ESP32

// Sudut awal: S1=0° (Tutup), S2=90° (Tengah), S3=90° (Tengah)
int angle1 = 0;
int angle2 = 90;
int angle3 = 90;

// Inisialisasi hardware PWM pada pin servo
void initServoHardware() {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && (ESP_ARDUINO_VERSION_MAJOR >= 3)
  // ESP32 Arduino Core 3.0+ API resmi
  bool ok1 = ledcAttach(pinServo1, PWM_FREQ, PWM_RES);
  bool ok2 = ledcAttach(pinServo2, PWM_FREQ, PWM_RES);
  bool ok3 = ledcAttach(pinServo3, PWM_FREQ, PWM_RES);
  Serial.printf("[LEDC ATTACH] Pin 18: %s | Pin 26: %s | Pin 21: %s\n",
    ok1 ? "BERHASIL (OK)" : "GAGAL!",
    ok2 ? "BERHASIL (OK)" : "GAGAL!",
    ok3 ? "BERHASIL (OK)" : "GAGAL!"
  );
#else
  // ESP32 Arduino Core 2.x API legacy
  ledcSetup(0, PWM_FREQ, PWM_RES);
  ledcAttachPin(pinServo1, 0);
  ledcSetup(1, PWM_FREQ, PWM_RES);
  ledcAttachPin(pinServo2, 1);
  ledcSetup(2, PWM_FREQ, PWM_RES);
  ledcAttachPin(pinServo3, 2);
  Serial.println("[LEDC ATTACH] Core 2.x Setup OK di Channel 0, 1, 2");
#endif
}

// Menghitung pulsa microsecond servo (544us - 2400us) dan menulis duty cycle ke hardware timer
void writeServoHardware(int pin, int angle) {
  angle = constrain(angle, 0, 180);

  // Inversi arah rotasi Servo 3 (Pin 21 - Servo Bawah):
  // Membalik sudut (180 - angle) agar saat kontroler diputar searah jarum jam (CW),
  // servo fisik berputar searah jarum jam (CW) dan arahnya sinkron 100%.
  if (pin == pinServo3) {
    angle = 180 - angle;
  }

  // Pulse microsecond standar servo (544us = 0°, 2400us = 180°)
  uint32_t pulseUs = map(angle, 0, 180, 544, 2400);
  // Konversi pulseUs ke duty cycle 14-bit pada periode 20.000us (50Hz)
  // Duty = (pulseUs / 20000) * 16383
  uint32_t duty = (pulseUs * 16383ULL) / 20000ULL;

#if defined(ESP_ARDUINO_VERSION_MAJOR) && (ESP_ARDUINO_VERSION_MAJOR >= 3)
  ledcWrite(pin, duty);
#else
  int ch = (pin == pinServo1) ? 0 : ((pin == pinServo2) ? 1 : 2);
  ledcWrite(ch, duty);
#endif
}

// ==========================================
// PROTOKOL ESP-NOW (KOMUNIKASI KE ESP32 CONVEYOR)
// Mengirim perintah nirkabel super cepat (<2ms)
// ==========================================
typedef struct __attribute__((packed)) {
  uint8_t mode;      // 0: STOP, 1: MANUAL_RUN, 2: AUTO_CYCLE
  uint16_t runMs;    // Durasi jalan (ms, misal 170)
  uint16_t stopMs;   // Durasi jeda berhenti (ms, misal 3000)
  uint8_t speed;     // Kecepatan PWM (0 - 255)
} ConveyorPacket;

uint8_t cvCurrentMode = 0;   // 0: STOP, 1: MANUAL_RUN, 2: AUTO_CYCLE
uint16_t cvRunMs = 170;      // Default 170 ms
uint16_t cvStopMs = 3000;    // Default 3000 ms (3 detik)
uint8_t cvSpeed = 255;       // Default PWM 255 (100%)
bool espNowReady = false;

void initEspNow() {
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);

  if (esp_now_init() != ESP_OK) {
    Serial.println("[ESP-NOW] Gagal inisialisasi ESP-NOW!");
    espNowReady = false;
    return;
  }
  espNowReady = true;
  Serial.println("[ESP-NOW] Inisialisasi Berhasil pada Channel 1 (STA Mode).");

  // Daftarkan Peer Broadcast (FF:FF:FF:FF:FF:FF)
  // Siapapun ESP32 Conveyor di channel 1 akan langsung menerima sinyal!
  esp_now_peer_info_t peerInfo = {};
  memset(peerInfo.peer_addr, 0xFF, 6);
  peerInfo.channel = 1;
  peerInfo.encrypt = false;

  if (esp_now_add_peer(&peerInfo) == ESP_OK) {
    Serial.println("[ESP-NOW] Peer Broadcast (FF:FF:FF:FF:FF:FF) Terdaftar!");
  } else {
    Serial.println("[ESP-NOW] Peringatan: Gagal registrasi broadcast peer.");
  }
}

void sendConveyorPacket(uint8_t mode, uint16_t runMs, uint16_t stopMs, uint8_t speed) {
  cvCurrentMode = mode;
  if (runMs > 0) cvRunMs = runMs;
  if (stopMs > 0) cvStopMs = stopMs;
  if (speed > 0 || mode == 0) cvSpeed = speed;

  ConveyorPacket pkt;
  pkt.mode = cvCurrentMode;
  pkt.runMs = cvRunMs;
  pkt.stopMs = cvStopMs;
  pkt.speed = cvSpeed;

  if (!espNowReady) {
    initEspNow();
  }

  uint8_t broadcastMac[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
  esp_err_t res = esp_now_send(broadcastMac, (uint8_t*)&pkt, sizeof(pkt));
  if (res == ESP_OK) {
    Serial.printf("[ESP-NOW TX] Berhasil kirim -> Mode:%d | Run:%dms | Stop:%dms | Spd:%d\n",
      pkt.mode, pkt.runMs, pkt.stopMs, pkt.speed);
  } else {
    Serial.printf("[ESP-NOW TX] Gagal kirim paket (Error: %d)\n", res);
  }
}

// ==========================================
// PENGATURAN BLUETOOTH LOW ENERGY (BLE)
// Nordic UART Service (NUS) - Standar Industri Bebas Delay
// ==========================================
#define DEVICE_NAME            "ESP32_Servo_Arm"
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" // Menerima data dari HP
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" // Mengirim notifikasi ke HP

BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Forward declaration
void processCommand(String cmd);
void parseIncoming(String input);
void sendStatus();
void sendConveyorStatus();

// ==========================================
// KONTROL GERAKAN SERVO
// ==========================================
void moveServo(int sNum, int val) {
  if (val < 0 || val > 180) return;

  if (sNum == 1) {
    angle1 = val;
    writeServoHardware(pinServo1, angle1);
  } else if (sNum == 2) {
    angle2 = val;
    writeServoHardware(pinServo2, angle2);
  } else if (sNum == 3) {
    angle3 = val;
    writeServoHardware(pinServo3, angle3);
  }
}

// Mengirim status sudut servo saat ini ke Flutter via BLE Notification
void sendStatus() {
  if (deviceConnected && pTxCharacteristic != nullptr) {
    char buf[40];
    snprintf(buf, sizeof(buf), "STATUS:%d:%d:%d\n", angle1, angle2, angle3);
    pTxCharacteristic->setValue((uint8_t*)buf, strlen(buf));
    pTxCharacteristic->notify();
  }
}

// Mengirim status conveyor saat ini ke Flutter via BLE Notification
void sendConveyorStatus() {
  if (deviceConnected && pTxCharacteristic != nullptr) {
    char buf[50];
    // Format: CV_STATUS:mode:runMs:stopSec:speed
    snprintf(buf, sizeof(buf), "CV_STATUS:%d:%d:%d:%d\n", 
      cvCurrentMode, cvRunMs, (int)(cvStopMs / 1000), cvSpeed);
    pTxCharacteristic->setValue((uint8_t*)buf, strlen(buf));
    pTxCharacteristic->notify();
  }
}

// ==========================================
// CALLBACK BLE (KONEKSI & TERIMA DATA)
// ==========================================
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    Serial.println("\n[BLE] >>> Perangkat HP Terhubung! <<<");
  }

  void onDisconnect(BLEServer* pServer) override {
    deviceConnected = false;
    Serial.println("\n[BLE] Perangkat HP Terputus. Menunggu koneksi ulang...");
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) override {
    String rxValue = pCharacteristic->getValue();
    if (rxValue.length() > 0) {
      parseIncoming(rxValue);
    }
  }
};

// ==========================================
// PARSER PROTOKOL DATA CEPAT (LOW LATENCY)
// ==========================================
void processCommand(String cmd) {
  cmd.trim();
  if (cmd.length() == 0) return;

  // Format: "ALL:s1:s2:s3" (contoh: ALL:30:90:90)
  if (cmd.startsWith("ALL:") || cmd.startsWith("all:")) {
    int c1 = cmd.indexOf(':');
    int c2 = cmd.indexOf(':', c1 + 1);
    int c3 = cmd.indexOf(':', c2 + 1);
    if (c1 != -1 && c2 != -1 && c3 != -1) {
      int s1 = cmd.substring(c1 + 1, c2).toInt();
      int s2 = cmd.substring(c2 + 1, c3).toInt();
      int s3 = cmd.substring(c3 + 1).toInt();
      moveServo(1, s1);
      moveServo(2, s2);
      moveServo(3, s3);
      sendStatus();
    }
  }
  // Format: "S:servoNum:angle" (contoh: S:1:0 atau S:2:90 atau S:3:90)
  else if (cmd.startsWith("S:") || cmd.startsWith("s:") || cmd.startsWith("SET:") || cmd.startsWith("set:")) {
    int c1 = cmd.indexOf(':');
    int c2 = cmd.indexOf(':', c1 + 1);
    if (c1 != -1 && c2 != -1) {
      int sNum = cmd.substring(c1 + 1, c2).toInt();
      int val = cmd.substring(c2 + 1).toInt();
      moveServo(sNum, val);
    }
  }
  // Format: "HOME"
  else if (cmd.equalsIgnoreCase("HOME")) {
    moveServo(1, 0);
    moveServo(2, 90);
    moveServo(3, 90);
    sendStatus();
  }
  // Format: "STATUS"
  else if (cmd.equalsIgnoreCase("STATUS")) {
    sendStatus();
    sendConveyorStatus();
  }
  // --- KONTROL CONVEYOR (FORWARD VIA ESP-NOW) ---
  // 1. Conveyor Stop
  else if (cmd.equalsIgnoreCase("CV:STOP") || cmd.equalsIgnoreCase("cv:stop")) {
    Serial.println("[CMD] Conveyor STOP");
    sendConveyorPacket(0, cvRunMs, cvStopMs, 0);
    sendConveyorStatus();
  }
  // 2. Conveyor Run Manual
  else if (cmd.equalsIgnoreCase("CV:RUN") || cmd.equalsIgnoreCase("cv:run") || 
           cmd.equalsIgnoreCase("CV:START") || cmd.equalsIgnoreCase("cv:start")) {
    Serial.println("[CMD] Conveyor RUN MANUAL");
    if (cvSpeed == 0) cvSpeed = 255;
    sendConveyorPacket(1, cvRunMs, cvStopMs, cvSpeed);
    sendConveyorStatus();
  }
  // 3. Conveyor Mode Otomatis: "CV:AUTO:runMs:stopSec" (contoh: CV:AUTO:170:3)
  else if (cmd.startsWith("CV:AUTO:") || cmd.startsWith("cv:auto:")) {
    int c1 = cmd.indexOf(':');
    int c2 = cmd.indexOf(':', c1 + 1);
    int c3 = cmd.indexOf(':', c2 + 1);
    int runMs = 170;
    int stopSec = 3;
    if (c2 != -1) {
      runMs = cmd.substring(c2 + 1, c3 != -1 ? c3 : cmd.length()).toInt();
      if (c3 != -1) {
        stopSec = cmd.substring(c3 + 1).toInt();
      }
    }
    if (runMs <= 0) runMs = 170;
    if (stopSec <= 0) stopSec = 3;
    if (cvSpeed == 0) cvSpeed = 255;
    Serial.printf("[CMD] Conveyor AUTO -> Jalan: %d ms | Jeda Berhenti: %d detik\n", runMs, stopSec);
    sendConveyorPacket(2, runMs, stopSec * 1000, cvSpeed);
    sendConveyorStatus();
  }
  // 4. Conveyor Kecepatan PWM: "CV:SPEED:pwm" (contoh: CV:SPEED:255)
  else if (cmd.startsWith("CV:SPEED:") || cmd.startsWith("cv:speed:")) {
    int c = cmd.lastIndexOf(':');
    if (c != -1) {
      int spd = cmd.substring(c + 1).toInt();
      cvSpeed = constrain(spd, 0, 255);
      Serial.printf("[CMD] Conveyor Kecepatan PWM: %d\n", cvSpeed);
      sendConveyorPacket(cvCurrentMode, cvRunMs, cvStopMs, cvSpeed);
      sendConveyorStatus();
    }
  }
  // Format: "TEST" (Tes gerak otomatis 3 servo untuk memastikan kelistrikan & kabel)
  else if (cmd.equalsIgnoreCase("TEST")) {
    Serial.println("\n[DIAGNOSTIK] Memulai tes gerakan 3 servo...");
    Serial.println("-> Servo 1 (Pin 18) ke 30° (Buka)...");
    moveServo(1, 30);
    delay(800);
    Serial.println("-> Servo 1 (Pin 18) ke 0° (Tutup)...");
    moveServo(1, 0);
    delay(800);
    Serial.println("-> Servo 2 (Pin 26) ke 45°...");
    moveServo(2, 45);
    delay(800);
    Serial.println("-> Servo 2 (Pin 26) ke 135°...");
    moveServo(2, 135);
    delay(800);
    Serial.println("-> Servo 3 (Pin 21) ke 45°...");
    moveServo(3, 45);
    delay(800);
    Serial.println("-> Servo 3 (Pin 21) ke 135°...");
    moveServo(3, 135);
    delay(800);
    Serial.println("-> Mengembalikan ke posisi HOME...");
    moveServo(1, 0);
    moveServo(2, 90);
    moveServo(3, 90);
    Serial.println("[DIAGNOSTIK] Selesai! Jika servo diam, periksa daya 5V dan Common GND.");
    sendStatus();
  }
}

void parseIncoming(String input) {
  int start = 0;
  while (start < input.length()) {
    int end = input.indexOf('\n', start);
    if (end == -1) {
      end = input.length();
    }
    String line = input.substring(start, end);
    line.trim();
    if (line.length() > 0) {
      processCommand(line);
    }
    start = end + 1;
  }
}

// ==========================================
// SETUP & LOOP
// ==========================================
void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("\n=========================================");
  Serial.println("  ESP32 MASTER: Arm Servo + ESP-NOW Conveyor");
  Serial.println("   Servo 1: Pin 18 | Servo 2: Pin 26 | Servo 3: Pin 21");
  Serial.println("=========================================");

  // Inisialisasi Native Hardware LEDC PWM untuk 3 Servo (Pin 18, 26, 21)
  initServoHardware();

  // Set sudut awal (S1=0, S2=90, S3=90)
  writeServoHardware(pinServo1, angle1);
  writeServoHardware(pinServo2, angle2);
  writeServoHardware(pinServo3, angle3);

  // Inisialisasi ESP-NOW nirkabel untuk mengontrol ESP32 Conveyor
  initEspNow();

  // Inisialisasi BLE Nordic UART Service (NUS)
  BLEDevice::init(DEVICE_NAME);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  // TX Characteristic (Notify status ke Flutter)
  pTxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID_TX,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pTxCharacteristic->addDescriptor(new BLE2902());

  // RX Characteristic (Menerima perintah gerak dari Flutter)
  BLECharacteristic* pRxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID_RX,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pRxCharacteristic->setCallbacks(new RxCallbacks());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06); // 7.5ms min connection interval
  pAdvertising->setMaxPreferred(0x12); // 22.5ms max connection interval
  BLEDevice::startAdvertising();

  Serial.println("[OK] Bluetooth BLE Siap!");
  Serial.print("Nama Bluetooth : ");
  Serial.println(DEVICE_NAME);
  Serial.println("Siap dihubungkan dari aplikasi Flutter!");
}

void loop() {
  // Restart advertising jika koneksi terputus agar bisa konek lagi tanpa restart ESP32
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    Serial.println("[BLE] Mulai advertising kembali...");
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }

  // Dukungan perintah manual lewat Serial Monitor (USB)
  if (Serial.available()) {
    String serialCmd = Serial.readStringUntil('\n');
    parseIncoming(serialCmd);
  }

  delay(10);
}
