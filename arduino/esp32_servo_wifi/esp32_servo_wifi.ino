#include <WiFi.h>
#include <WebServer.h>
#include <ESP32Servo.h>

// ==========================================
// PENGATURAN 3 SERVO & PIN (18, 19, 21)
// ==========================================
Servo servo1; // Pin 18
Servo servo2; // Pin 19
Servo servo3; // Pin 21

const int pinServo1 = 18;
const int pinServo2 = 19;
const int pinServo3 = 21;

// Sudut awal: S1=0° (Box Tertutup), S2=90° (Arm Joint), S3=90 (Servo 360 STOP)
int angle1 = 0;
int angle2 = 90;
int angle3 = 90;

// Status attach: jangan paksa gerak saat pertama nyala sebelum diperintah aplikasi
bool s1Attached = false;
bool s2Attached = false;
bool s3Attached = false;

// ==========================================
// PENGATURAN WI-FI
// ==========================================
// MODE 1: Access Point (ESP32 membuat hotspot sendiri)
const char* apSSID = "ESP32_Servo_Arm";
const char* apPass = "12345678";

// MODE 2 (Opsional): Koneksi ke Wi-Fi Rumah
const bool USE_STA_MODE = false;
const char* staSSID = "Asalole 4G";
const char* staPass = "21032006";

WebServer server(80);

void setCORS() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "*");
}

void handleRoot() {
  setCORS();
  String html = "<html><body style='font-family:sans-serif;text-align:center;padding:30px;background:#090d16;color:#fff;'>";
  html += "<h2 style='color:#00f0ff;'>ESP32 3-Axis Servo Arm Siap!</h2>";
  html += "<p>Servo 1 (Pin 18 - Pengangkat Box): <b>" + String(angle1) + "&deg;</b> (0&deg; Tutup / 30&deg; Buka)</p>";
  html += "<p>Servo 2 (Pin 19 - Arm Joint): <b>" + String(angle2) + "&deg;</b></p>";
  html += "<p>Servo 3 (Pin 21 - Servo 360 Bawah): <b>" + String(angle3) + "&deg;</b> (90 = STOP)</p>";
  html += "</body></html>";
  server.send(200, "text/html", html);
}

void handleStatus() {
  setCORS();
  String json = "{\"status\":\"online\","
                "\"s1\":" + String(angle1) + ","
                "\"s2\":" + String(angle2) + ","
                "\"s3\":" + String(angle3) + "}";
  server.send(200, "application/json", json);
}

// Menggerakkan servo dengan attach otomatis saat pertama kali ada perintah
void moveServo(int sNum, int val) {
  if (val < 0 || val > 180) return;

  if (sNum == 1) {
    if (!s1Attached) {
      servo1.attach(pinServo1, 544, 2400);
      s1Attached = true;
    }
    angle1 = val;
    servo1.write(angle1);
    Serial.printf("-> Servo 1 (Pin 18) = %d°\n", angle1);
  } else if (sNum == 2) {
    if (!s2Attached) {
      servo2.attach(pinServo2, 544, 2400);
      s2Attached = true;
    }
    angle2 = val;
    servo2.write(angle2);
    Serial.printf("-> Servo 2 (Pin 19) = %d°\n", angle2);
  } else if (sNum == 3) {
    angle3 = val;
    if (val == 90) {
      // Jika sinyal STOP (90), matikan pulsa PWM agar servo 360 diam total 100% tanpa merayap!
      servo3.write(90);
      delay(20);
      if (s3Attached) {
        servo3.detach();
        s3Attached = false;
      }
      Serial.println("-> Servo 3 (Pin 21) = STOP & DETACHED (Diam Total)");
    } else {
      if (!s3Attached) {
        servo3.attach(pinServo3, 544, 2400);
        s3Attached = true;
      }
      servo3.write(angle3);
      Serial.printf("-> Servo 3 (Pin 21) = %d°\n", angle3);
    }
  }
}

// Handler: Atur servo individual "/set?servo=1&angle=90"
void handleSetSingle() {
  setCORS();
  if (server.hasArg("servo") && server.hasArg("angle")) {
    int sNum = server.arg("servo").toInt();
    int val = server.arg("angle").toInt();

    if (val >= 0 && val <= 180 && (sNum >= 1 && sNum <= 3)) {
      moveServo(sNum, val);
      String json = "{\"status\":\"ok\",\"servo\":" + String(sNum) + ",\"angle\":" + String(val) + "}";
      server.send(200, "application/json", json);
      return;
    }
  }
  server.send(400, "application/json", "{\"status\":\"error\",\"message\":\"Parameter tidak valid\"}");
}

// Handler: Atur semua servo sekaligus "/set_all?s1=90&s2=90&s3=90"
void handleSetAll() {
  setCORS();
  if (server.hasArg("s1")) moveServo(1, server.arg("s1").toInt());
  if (server.hasArg("s2")) moveServo(2, server.arg("s2").toInt());
  if (server.hasArg("s3")) moveServo(3, server.arg("s3").toInt());

  Serial.printf("-> All Servos: S1=%d°, S2=%d°, S3=%d°\n", angle1, angle2, angle3);
  handleStatus();
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n--- Memulai ESP32 3-Servo Controller ---");

  // Alokasi timer PWM untuk ESP32
  ESP32PWM::allocateTimer(0);
  ESP32PWM::allocateTimer(1);
  ESP32PWM::allocateTimer(2);
  ESP32PWM::allocateTimer(3);

  servo1.setPeriodHertz(50);
  servo2.setPeriodHertz(50);
  servo3.setPeriodHertz(50);

  // CATATAN: Di sini sengaja BELUM di-attach agar servo tidak bergerak sendiri saat baru dinyalakan.
  // Servo akan di-attach secara otomatis saat menerima sinyal pertama dari Flutter.

  // Inisialisasi Wi-Fi
  if (USE_STA_MODE) {
    Serial.print("Menghubungkan ke Wi-Fi: ");
    Serial.println(staSSID);
    WiFi.mode(WIFI_STA);
    WiFi.begin(staSSID, staPass);
    int timeout = 0;
    while (WiFi.status() != WL_CONNECTED && timeout < 20) {
      delay(500);
      Serial.print(".");
      timeout++;
    }
    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("\n[OK] Terhubung ke Router Wi-Fi!");
      Serial.print("IP Address ESP32: ");
      Serial.println(WiFi.localIP());
    } else {
      Serial.println("\n[!] Gagal ke router. Beralih ke Hotspot...");
      WiFi.mode(WIFI_AP);
      WiFi.softAP(apSSID, apPass);
      Serial.print("Hotspot dibuat. IP Address: ");
      Serial.println(WiFi.softAPIP());
    }
  } else {
    WiFi.mode(WIFI_AP);
    WiFi.softAP(apSSID, apPass);
    Serial.println("[OK] Hotspot ESP32 Berhasil Dibuat!");
    Serial.print("SSID Wi-Fi: ");
    Serial.println(apSSID);
    Serial.print("Password  : ");
    Serial.println(apPass);
    Serial.print("IP Address: ");
    Serial.println(WiFi.softAPIP()); // Default: 192.168.4.1
  }

  // Routing Web Server
  server.on("/", HTTP_GET, handleRoot);
  server.on("/status", HTTP_GET, handleStatus);
  server.on("/set", HTTP_GET, handleSetSingle);
  server.on("/set_all", HTTP_GET, handleSetAll);

  server.begin();
  Serial.println("Web Server Siap di Port 80!");
}

void loop() {
  server.handleClient();
}
