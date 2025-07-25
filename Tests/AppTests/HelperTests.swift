import Foundation
@testable import App
import Testing
import NIO
// import Vapor

@Suite struct HelperTests {
    @Test func mapStream() async {
        let a = (0..<100).map { $0 }
        let res = try! await a.mapStream(nConcurrent: 4) {
            try await Task.sleep(nanoseconds: UInt64.random(in: 1000..<10000))
            return $0
        }.collect()
        #expect(res == a)

        let a2 = (0..<5).map { $0 }
        let res2 = try! await a2.mapStream(nConcurrent: 10) {
            try await Task.sleep(nanoseconds: UInt64.random(in: 1000..<10000))
            return $0
        }.collect()
        #expect(res2 == a2)
    }

    @Test func indexedCurl() {
        let index = """
            1:0:d=2022080800:UFLX:surface:anl:
            2:52676:d=2022080800:VFLX:surface:anl:
            3:104746:d=2022080800:SHTFL:surface:anl:
            4:147011:d=2022080800:LHTFL:surface:anl:
            5:191888:d=2022080800:TMP:surface:anl:
            6:276987:d=2022080800:SOILW:0-0.1 m below ground:anl:
            7:310844:d=2022080800:SOILW:0.1-0.4 m below ground:anl:
            8:344851:d=2022080800:TMP:0-0.1 m below ground:anl:
            9:387832:d=2022080800:TMP:0.1-0.4 m below ground:anl:
            10:430543:d=2022080800:WEASD:surface:anl:
            11:447714:d=2022080800:DLWRF:surface:anl:
            12:490126:d=2022080800:ULWRF:surface:anl:
            13:520276:d=2022080800:ULWRF:top of atmosphere:anl:
            14:564311:d=2022080800:USWRF:top of atmosphere:anl:
            """
        let range = index.split(separator: "\n").indexToRange { line in
            line.contains("SHTFL") || line.contains("LHTFL") || line.contains("USWRF") || line.contains("TMP")
        }
        #expect(range?.range == "104746-276986,344851-430542,564311-")
        #expect(range?.minSize == 257933)

        let range2 = index.split(separator: "\n").indexToRange { _ in
            return true
        }
        #expect(range2?.range == "0-")
        #expect(range2?.minSize == 564311)

        let range3 = index.split(separator: "\n").indexToRange { _ in
            return false
        }
        #expect(range3 == nil)

        let range4 = index.split(separator: "\n").indexToRange { line in
            line.contains("TMP") || line.contains("UFLX")
        }
        #expect(range4?.range == "0-52675,191888-276986,344851-430542")
        #expect(range4?.minSize == 223467)
        /*let curl = Curl(logger: Logger(label: ""))
         try! curl.downloadIndexedGrib(url: "https://nomads.ncep.noaa.gov/pub/data/nccf/com/cfs/prod/cfs.20220808/00/6hrly_grib_01/flxf2022080812.01.2022080800.grb2", to: "/Users/patrick/Downloads/test.grib", include: { line in
         line.contains(":")
         })*/
    }

    @Test func decodeEcmwfIndex() throws {
        var buffer = ByteBuffer()
        buffer.writeString("""
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "levtype": "sfc", "number": "21", "step": "102", "param": "tp", "_offset": 0, "_length": 812043}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "30", "param": "10v", "_offset": 812043, "_length": 609069}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "31", "param": "10v", "_offset": 1421112, "_length": 609069}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "16", "param": "10v", "_offset": 2030181, "_length": 609069}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "16", "param": "10u", "_offset": 2639250, "_length": 609069}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "41", "param": "10v", "_offset": 3248319, "_length": 609069}
        """)
        let index = try buffer.readEcmwfIndexEntries()
        #expect(index.count == 6)
        let range = index.indexToRange()[0]
        #expect(range.range == "0-3857388")
        #expect(range.minSize == 3857388)

        var buffer2 = ByteBuffer()
        buffer2.writeString("""
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "levtype": "sfc", "number": "21", "step": "102", "param": "tp", "_offset": 0, "_length": 812043}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "30", "param": "10v", "_offset": 812044, "_length": 609068}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "31", "param": "10v", "_offset": 1421112, "_length": 609069}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "16", "param": "10v", "_offset": 2030181, "_length": 609069}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "16", "param": "10u", "_offset": 2639249, "_length": 609068}
        {"domain": "g", "date": "20230501", "time": "0000", "expver": "0001", "class": "od", "type": "pf", "stream": "enfo", "step": "102", "levtype": "sfc", "number": "41", "param": "10v", "_offset": 3248319, "_length": 609069}
        """)
        let index2 = try buffer2.readEcmwfIndexEntries()
        #expect(index2.count == 6)
        let range2 = index2.indexToRange()[0]
        #expect(range2.range == "0-812043,812044-2639250,2639249-3248317,3248319-3857388")
        #expect(range2.minSize == 3857386)
    }

    /*func testSpawn() async throws {
     let time = DispatchTime.now()
     async let a: () = try Process.spawn(cmd: "sleep", args: ["1"])
     async let b: () = try Process.spawn(cmd: "sleep", args: ["1"])
     try await a
     try await b
     let elapsedMs = Double((DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds) / 1_000_000)
     #expect(elapsedMs < 1200)
     }*/

    @Test func nativeSpawn() throws {
        #expect(try Process.spawnWithExitCode(cmd: "echo", args: ["Hello"]) == 0)
        #expect(try Process.spawnWithExitCode(cmd: "echo", args: ["World"]) == 0)

        try "exit 70".write(toFile: "temp.sh", atomically: true, encoding: .utf8)
        #expect(try Process.spawnWithExitCode(cmd: "bash", args: ["temp.sh"]) == 70)
        try FileManager.default.removeItem(atPath: "temp.sh")
    }

    @Test func byteSizeParser() throws {
        let bytes = try ByteSizeParser.parseSizeStringToBytes("2KB")
        #expect(bytes == 2 * 1024)
        let bytes2 = try ByteSizeParser.parseSizeStringToBytes("1.5MB")
        #expect(bytes2 == Int(1.5 * 1024 * 1024))
        let bytes3 = try ByteSizeParser.parseSizeStringToBytes("1GB")
        #expect(bytes3 == 1 * 1024 * 1024 * 1024)
        let bytes4 = try ByteSizeParser.parseSizeStringToBytes("0.5TB")
        #expect(bytes4 == Int(0.5 * 1024 * 1024 * 1024 * 1024))
        let bytes5 = try ByteSizeParser.parseSizeStringToBytes("3.25MB")
        #expect(bytes5 == Int(3.25 * 1024 * 1024))
    }
}
