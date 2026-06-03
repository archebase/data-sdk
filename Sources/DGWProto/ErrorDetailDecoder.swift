import Foundation

private let archebaseErrorDetailTypeURL = "type.googleapis.com/archebase.common.v1.ErrorDetail"

package enum ArchebaseErrorDetailDecoder {
    package static func decode(fromStatusDetailsBytes bytes: [UInt8]) -> Archebase_Common_V1_ErrorDetail? {
        guard !bytes.isEmpty else {
            return nil
        }

        if let detail = Self.decodeGoogleRpcStatus(bytes) {
            return detail
        }

        guard
            let detail = try? Archebase_Common_V1_ErrorDetail(serializedBytes: bytes),
            detail.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return detail
    }

    private static func decodeGoogleRpcStatus(_ bytes: [UInt8]) -> Archebase_Common_V1_ErrorDetail? {
        var cursor = ProtobufCursor(bytes: bytes)
        while let key = cursor.readVarint() {
            let fieldNumber = key >> 3
            let wireType = key & 0x7
            guard fieldNumber != 3 || wireType != 2 else {
                guard let anyBytes = cursor.readLengthDelimited() else {
                    return nil
                }
                if let detail = Self.decodeAnyErrorDetail(anyBytes) {
                    return detail
                }
                continue
            }
            guard cursor.skip(wireType: wireType) else {
                return nil
            }
        }
        return nil
    }

    private static func decodeAnyErrorDetail(_ bytes: [UInt8]) -> Archebase_Common_V1_ErrorDetail? {
        var cursor = ProtobufCursor(bytes: bytes)
        var typeURL = ""
        var value: [UInt8] = []

        while let key = cursor.readVarint() {
            let fieldNumber = key >> 3
            let wireType = key & 0x7
            guard wireType == 2 else {
                guard cursor.skip(wireType: wireType) else {
                    return nil
                }
                continue
            }

            guard let fieldBytes = cursor.readLengthDelimited() else {
                return nil
            }
            switch fieldNumber {
            case 1:
                typeURL = String(bytes: fieldBytes, encoding: .utf8) ?? ""
            case 2:
                value = fieldBytes
            default:
                continue
            }
        }

        guard
            typeURL == archebaseErrorDetailTypeURL || typeURL.hasSuffix("/archebase.common.v1.ErrorDetail"),
            let detail = try? Archebase_Common_V1_ErrorDetail(serializedBytes: value),
            detail.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return detail
    }
}

private struct ProtobufCursor {
    private let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0

        while self.index < self.bytes.count, shift < 64 {
            let byte = self.bytes[self.index]
            self.index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }
        return nil
    }

    mutating func readLengthDelimited() -> [UInt8]? {
        guard let length = self.readVarint(), length <= UInt64(Int.max) else {
            return nil
        }
        let end = self.index + Int(length)
        guard end <= self.bytes.count else {
            return nil
        }
        defer { self.index = end }
        return Array(self.bytes[self.index..<end])
    }

    mutating func skip(wireType: UInt64) -> Bool {
        switch wireType {
        case 0:
            return self.readVarint() != nil
        case 1:
            return self.skipFixed(byteCount: 8)
        case 2:
            return self.readLengthDelimited() != nil
        case 5:
            return self.skipFixed(byteCount: 4)
        default:
            return false
        }
    }

    private mutating func skipFixed(byteCount: Int) -> Bool {
        let end = self.index + byteCount
        guard end <= self.bytes.count else {
            return false
        }
        self.index = end
        return true
    }
}
