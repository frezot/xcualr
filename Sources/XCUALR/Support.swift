import Foundation

func parseAppleReferenceMilliseconds(_ value: String) -> Int64? {
    guard let seconds = Double(value), seconds > 0 else {
        return nil
    }
    return Int64(seconds * 1000) + 978_307_200_000
}
