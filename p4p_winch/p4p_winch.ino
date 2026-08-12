#include <SPI.h>
#include <SD.h>


// pin defs
const int pinAIN1 = 2; // direction
const int pinAIN2 = 3;
const int pinPWMA = 4;
const int pinSTBY = 5;

const int pinEncA = 0; // interrupt pin

// global vars
volatile long encoderTicks = 0;
unsigned long previousMS = 0;

File logFile;

// constants
const float ticksPerRev = 228.0; // from datasheet
const int revSpeed = 128; // SET THIS
const int interval = 1000;
const int intervalsPerMin = 60000.0 / interval;
const String fileName = "data.csv";

// -- isr --
void isr_countTicks() {
  encoderTicks++;
}

void setup() {
  Serial.begin(9600);

  // -- motor setup --
  pinMode(pinAIN1, OUTPUT);
  pinMode(pinAIN2, OUTPUT);
  pinMode(pinPWMA, OUTPUT);
  pinMode(pinSTBY, OUTPUT);

  // -- motor encoder setup --
  pinMode(pinEncA, INPUT_PULLUP);
  // trigger interrupt  on rising edge of encoder pulse
  attachInterrupt(digitalPinToInterrupt(pinEncA), isr_countTicks, RISING);

  // -- SD card setup --
  Serial.print("Init SD Card...");
  if (!SD.begin(SDCARD_SS_PIN)) {
    Serial.println("Failed to init...");
    while (1);
  }
  Serial.print("Init done!");

  // -- file setup
  logFile = SD.open(fileName, FILE_WRITE);
  if (logFile) {
    logFile.println("Time(ms),RPM");
    logFile.close();
  }

  // -- start motor
  digitalWrite(pinSTBY, HIGH);
  digitalWrite(pinAIN1, HIGH);
  digitalWrite(pinAIN2, LOW);
  analogWrite(pinPWMA, revSpeed); // set constant speed
}

void loop() {
  unsigned long currentMS = millis();

  if (currentMS - previousMS >= interval) {
    noInterrupts(); // pause preemption
    long ticks = encoderTicks;
    encoderTicks = 0;
    interrupts(); // resume

    // -- calculate RPM --
    float rpm = (ticks / ticksPerRev) * intervalsPerMin;
    float meters_second = 0;

    // -- log data --
    logFile = SD.open(fileName, FILE_WRITE);
    if (logFile) {
      logFile.print(currentMS);
      logFile.print(",");
      logFile.println(rpm);
      logFile.close();

      // print to serial monitor
      Serial.print("Current ms: ");
      Serial.print(currentMS);
      Serial.print(" | RPM: ");
      Serial.println(rpm);
    }
    else {
      Serial.print("Error opening: ");
      Serial.print(fileName);
    }

    // reset the interval timer
    previousMS = currentMS;
  }
}
