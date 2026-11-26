import Foundation

@main enum LabContractChecks {
    static func main() {
        func packet(source: [UInt8], target: [UInt8], outgoing: Bool = true) -> Data {
            var data = Data([0x45, 0, 0, 40, 0, 0, 0x40, 0, 64, 6, 0, 0])
            data.append(contentsOf: source + target)
            let local: [UInt8] = [0xC0, 0x00]
            let fixture: [UInt8] = [0x46, 0xA0]
            data.append(contentsOf: outgoing ? local + fixture : fixture + local)
            data.append(contentsOf: Array(repeating: 0, count: 16))
            data[32] = 0x50
            return data
        }
        let device: [UInt8] = [198, 18, 0, 1]
        let target: [UInt8] = [198, 51, 100, 42]
        let request = packet(source: device, target: target)
        let response = packet(source: target, target: device, outgoing: false)
        precondition(LabContract.accepts(request, fromProvider: false))
        precondition(LabContract.accepts(response, fromProvider: true))
        precondition(!LabContract.accepts(response, fromProvider: false))
        precondition(!LabContract.accepts(request, fromProvider: true))
        precondition(!LabContract.accepts(packet(source: device, target: [198, 51, 100, 43]), fromProvider: false))
        precondition(!LabContract.accepts(packet(source: [192, 0, 2, 10], target: target), fromProvider: false))
        precondition(!LabContract.accepts(Data(request.dropLast()), fromProvider: false))
        var invalid = request
        invalid[0] = 0x60
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid[0] = 0x4F
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid[0] = 0x45
        invalid[3] = 39
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid = request
        invalid[23] = 0xA1
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid = request
        invalid[6] = 0x20
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid = request
        invalid[9] = 17
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        invalid = request
        invalid[32] = 0x10
        precondition(!LabContract.accepts(invalid, fromProvider: false))
        print("CLAY Tunnel Lab packet scope passed")
    }
}
