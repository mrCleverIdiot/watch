import Foundation
import HealthKit

class HealthManager {
    static let shared = HealthManager()
    private let healthStore = HKHealthStore()
    private let heartType = HKQuantityType(.heartRate)
    private let bpmUnit = HKUnit(from: "count/min")
    
    private init() {}
    
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        let toRead: Set<HKObjectType> = [heartType]
        let toWrite: Set<HKSampleType> = [heartType]
        healthStore.requestAuthorization(toShare: toWrite, read: toRead) { success, _ in
            completion(success)
        }
    }
    
    // Entry point from BLEManager when FF03 updates
    func processWatchData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ HealthManager: JSON parse failed")
            return
        }
        let type = json["type"] as? String
        if type == "heart_rate" {
            if let bpm = json["bpm"] as? Double ?? (json["bpm"] as? Int).map(Double.init),
               let ts = json["ts"] as? Double {
                print("🩺 Parsed HR sample: bpm=\(bpm), ts=\(ts)")
                saveHeartRate(bpm: bpm, timestampMs: ts)
            }
        } else if type == "heart_rate_batch" {
            if let samples = json["samples"] as? [[String: Any]] {
                var hkSamples: [HKQuantitySample] = []
                for s in samples {
                    guard let bpm = s["bpm"] as? Double ?? (s["bpm"] as? Int).map(Double.init),
                          let ts = s["ts"] as? Double else { continue }
                    let date = Date(timeIntervalSince1970: ts / 1000.0)
                    let qty = HKQuantity(unit: bpmUnit, doubleValue: bpm)
                    hkSamples.append(HKQuantitySample(type: heartType, quantity: qty, start: date, end: date))
                }
                print("🩺 Parsed HR batch: count=\(hkSamples.count)")
                if !hkSamples.isEmpty {
                    healthStore.save(hkSamples) { success, error in
                        if let error = error { print("Health save error: \(error.localizedDescription)") }
                        else { print("Saved \(hkSamples.count) HR samples to Health") }
                    }
                }
            }
        }
    }
    
    private func saveHeartRate(bpm: Double, timestampMs: Double) {
        let date = Date(timeIntervalSince1970: timestampMs / 1000.0)
        let qty = HKQuantity(unit: bpmUnit, doubleValue: bpm)
        let sample = HKQuantitySample(type: heartType, quantity: qty, start: date, end: date)
        healthStore.save(sample) { success, error in
            if let error = error { print("Health save error: \(error.localizedDescription)") }
            else { print("Saved HR: \(bpm) @ \(date)") }
        }
    }
}

