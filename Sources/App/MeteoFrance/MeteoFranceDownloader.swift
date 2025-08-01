import Foundation
import Vapor
import OmFileFormat

/**
Meteofrance Arome, Arpge downloader
 
 TODO:
 - AROME 0.025 PI added direct radiation
 - Correct old shortwave radiaiton files
 - AROME 0.01 PI has low clouds, AROME PRI 0.025 mid and high, should be combined to total clouds
 */
struct MeteoFranceDownload: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "domain")
        var domain: String

        @Option(name: "run")
        var run: String?

        @Flag(name: "create-netcdf")
        var createNetcdf: Bool

        @Option(name: "only-variables")
        var onlyVariables: String?

        //@Flag(name: "upper-level", help: "Download upper-level variables on pressure levels")
        //var upperLevel: Bool

        @Flag(name: "use-grib-packages", help: "If true, download GRIB packages (SP1, SP2, ...) instead of individual records")
        var useGribPackages: Bool
        
        @Option(name: "grib-packages")
        var gribPackages: String?

        @Flag(name: "use-gov-server", help: "Use france gov server instead of meteofrance API")
        var useGovServer: Bool

        @Option(name: "upload-s3-bucket", help: "Upload open-meteo database to an S3 bucket after processing")
        var uploadS3Bucket: String?

        @Option(name: "concurrent", short: "c", help: "Numer of concurrent download/conversion jobs")
        var concurrent: Int?

        @Option(name: "max-forecast-hour", help: "Only download data until this forecast hour")
        var maxForecastHour: Int?
    }

    var help: String {
        "Download MeteoFrance models"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let start = DispatchTime.now()
        let logger = context.application.logger
        let domain = try MeteoFranceDomain.load(rawValue: signature.domain)

        /*if signature.onlyVariables != nil && signature.upperLevel {
            fatalError("Parameter 'onlyVariables' and 'upperLevel' must not be used simultaneously")
        }*/

        let run = try signature.run.flatMap(Timestamp.fromRunHourOrYYYYMMDD) ?? domain.lastRun

        let onlyVariables: [any MeteoFranceVariableDownloadable]? = try signature.onlyVariables.map {
            try $0.split(separator: ",").map {
                if let variable = MeteoFrancePressureVariable(rawValue: String($0)) {
                    return variable
                }
                return try MeteoFranceSurfaceVariable.load(rawValue: String($0))
            }
        }

        let pressureVariables = domain.levels.reversed().flatMap { level in
            MeteoFrancePressureVariableType.allCases.map { variable -> MeteoFrancePressureVariable in
                return MeteoFrancePressureVariable(variable: variable, level: level)
            }
        }
        let surfaceVariables = MeteoFranceSurfaceVariable.allCases

        let variablesAll = onlyVariables ?? surfaceVariables + pressureVariables //(signature.upperLevel ? pressureVariables : surfaceVariables)

        let variables = variablesAll.filter({ $0.availableFor(domain: domain, forecastSecond: 0) })

        let nConcurrent = signature.concurrent ?? 1

        logger.info("Downloading domain '\(domain.rawValue)' run '\(run.iso8601_YYYY_MM_dd_HH_mm)'")

        let useGribPackagesDownload = signature.useGribPackages && !domain.mfApiPackagesSurface.isEmpty
        let gribPackages: [String]? = signature.gribPackages.map{$0.split(separator: ",").map(String.init)}

        try await downloadElevation2(application: context.application, domain: domain, run: run)
        let handles = await domain == .arpege_world_probabilities || domain == .arpege_europe_probabilities ? try downloadProbabilities(application: context.application, domain: domain, run: run, uploadS3Bucket: signature.uploadS3Bucket) : useGribPackagesDownload ?
        try await download3(application: context.application, domain: domain, run: run, /*upperLevel: signature.upperLevel,*/ useGovServer: signature.useGovServer, maxForecastHour: signature.maxForecastHour, uploadS3Bucket: signature.uploadS3Bucket, packages: gribPackages) :
        try await download2(application: context.application, domain: domain, run: run, variables: variables, uploadS3Bucket: signature.uploadS3Bucket)

        try await GenericVariableHandle.convert(logger: logger, domain: domain, createNetcdf: signature.createNetcdf, run: run, handles: handles, concurrent: nConcurrent, writeUpdateJson: true, uploadS3Bucket: signature.uploadS3Bucket, uploadS3OnlyProbabilities: false)
        // try convert(logger: logger, domain: domain, variables: variables, run: run, createNetcdf: signature.createNetcdf)

        logger.info("Finished in \(start.timeElapsedPretty())")
    }

    func downloadElevation2(application: Application, domain: MeteoFranceDomain, run: Timestamp) async throws {
        let logger = application.logger
        let surfaceElevationFileOm = domain.surfaceElevationFileOm.getFilePath()
        if domain == .arome_france_15min || domain == .arome_france_hd_15min || domain == .arpege_world_probabilities || domain == .arpege_europe_probabilities {
            return
        }
        if FileManager.default.fileExists(atPath: surfaceElevationFileOm) {
            return
        }
        try domain.surfaceElevationFileOm.createDirectory()
        guard let apikey = Environment.get("METEOFRANCE_API_KEY")?.split(separator: ",").map(String.init) else {
            fatalError("Please specify environment variable 'METEOFRANCE_API_KEY'")
        }
        let curl = Curl(logger: logger, client: application.dedicatedHttpClient, headers: [("apikey", apikey.randomElement() ?? "")])
        let runTime = "\(run.iso8601_YYYY_MM_dd)T\(run.hour.zeroPadded(len: 2)).00.00Z"
        let subsetGrid = domain.mfSubsetGrid
        let url = "https://public-api.meteofrance.fr/public/\(domain.family.rawValue)/1.0/wcs/\(domain.mfApiName)-WCS/GetCoverage?service=WCS&version=2.0.1&coverageid=GEOMETRIC_HEIGHT__GROUND_OR_WATER_SURFACE___\(runTime)\(subsetGrid)&subset=time(0)&format=application%2Fwmo-grib"

        let message = try await curl.downloadGrib(url: url, bzip2Decode: false)[0]
        var grib2d = GribArray2D(nx: domain.grid.nx, ny: domain.grid.ny)
        try grib2d.load(message: message)
        if domain.isGlobal {
            grib2d.array.shift180LongitudeAndFlipLatitude()
        } else {
            grib2d.array.flipLatitude()
        }
        // try grib2d.array.writeNetcdf(filename: "\(domain.downloadDirectory)elevation.nc")
        // try message.debugGrid(grid: domain.grid, flipLatidude: true, shift180Longitude: true)
        // message.dumpAttributes()

        try grib2d.array.data.writeOmFile2D(file: surfaceElevationFileOm, grid: domain.grid, createNetCdf: false)
    }

    /// Temporarily keep those varibles to derive others
    enum MfVariableTemporary: String {
        case ugst
        case vgst

        static func getVariable(shortName: String, levelStr: String, parameterName: String, typeOfLevel: String) -> Self? {
            switch (shortName, typeOfLevel, levelStr) {
            case ("10efg", "heightAboveGround", "10"):
                return .ugst
            case ("10nfg", "heightAboveGround", "10"):
                return .vgst
            default:
                return nil
            }
        }
    }

    /// Temporarily keep those varibles to derive others
    enum MfVariablePrecipTemporary: String, GenericVariable {
        case tgrp // graupel
        case tirf // rain
        case tsnowp // snow

        static func getVariable(shortName: String, levelStr: String, parameterName: String, typeOfLevel: String) -> Self? {
            switch (shortName, typeOfLevel, levelStr) {
            case ("tgrp", "surface", "0"):
                return .tgrp
            case ("tirf", "surface", "0"):
                return .tirf
            case ("tsnowp", "surface", "0"):
                return .tsnowp
            default:
                return nil
            }
        }

        var omFileName: (file: String, level: Int) {
            return (rawValue, 0)
        }

        var scalefactor: Float {
             return 10
        }

        var interpolation: ReaderInterpolation {
            return .backwards_sum
        }

        var unit: SiUnit {
            return .millimetre
        }

        var isElevationCorrectable: Bool {
            return false
        }

        var storePreviousForecast: Bool {
            return false
        }

        var requiresOffsetCorrectionForMixing: Bool {
            return false
        }
    }

    /**
     Download statistical ensemble forecast. See https://github.com/open-meteo/open-meteo/issues/1069
     */
    func downloadProbabilities(application: Application, domain: MeteoFranceDomain, run: Timestamp, uploadS3Bucket: String?) async throws -> [GenericVariableHandle] {
        guard let apikey = Environment.get("METEOFRANCE_API_KEY")?.split(separator: ",").map(String.init) else {
            fatalError("Please specify environment variable 'METEOFRANCE_API_KEY'")
        }
        let logger = application.logger
        let deadLineHours = domain.timeoutHours
        Process.alarm(seconds: Int(deadLineHours + 0.5) * 3600)
        defer { Process.alarm(seconds: 0) }
        
        // let grid = domain.grid
        let curl = Curl(logger: logger, client: application.dedicatedHttpClient, deadLineHours: deadLineHours, waitAfterLastModified: TimeInterval(2 * 60))

        let timestamps = domain.forecastSeconds(run: run.hour, hourlyForArpegeEurope: false).map { run.add($0) }
        
        // https://public-api.meteofrance.fr/public/DPStatsPEARPEGE/v1/models/PEARP-EUROPE/grids/0.1/groups/FFDDP1/productStatsPEARP?referencetime=2024-10-14T18%3A00%3A00Z&time=003H&format=grib2

        let handles = try await timestamps.enumerated().asyncFlatMap { (i,timestamp) -> [GenericVariableHandle] in
            let f3 = ((timestamp.timeIntervalSince1970 - run.timeIntervalSince1970) / 3600).zeroPadded(len: 3)

            let url = "https://public-api.meteofrance.fr/public/DPStatsPEARPEGE/v1/models/PEARP-EUROPE/grids/\(domain.mfApiGridName)/groups/RRP1/productStatsPEARP?referencetime=\(run.iso8601_YYYY_MM_dd_HH_mm):00Z&time=\(f3)H&format=grib2"

            return try await curl.withGribStream(url: url, bzip2Decode: false, headers: [("apikey", apikey.randomElement() ?? "")]) { stream in
                // process sequentialy, as precipitation need to be in order for deaveraging
                let writer = OmSpatialTimestepWriter(domain: domain, run: run, time: timestamp, storeOnDisk: true, realm: nil)
                for try await message in stream {
                    // Only select 3h precipitation probability from the grib file
                    guard let probabilityType = message.getLong(attribute: "probabilityType"),
                          probabilityType == 3,
                          let stepRange = message.get(attribute: "stepRange")?.splitTo2Integer(),
                          stepRange.1 - stepRange.0 == 3
                    else {
                        continue
                    }
                    var grib2d = GribArray2D(nx: domain.grid.nx, ny: domain.grid.ny)
                    // message.dumpAttributes()
                    try grib2d.load(message: message)
                    if domain.isGlobal {
                        grib2d.array.shift180LongitudeAndFlipLatitude()
                    } else {
                        grib2d.array.flipLatitude()
                    }

                    let variable = ProbabilityVariable.precipitation_probability
                    logger.info("Compressing and writing data to \(timestamp.format_YYYYMMddHH) \(variable)")
                    try await writer.write(member: 0, variable: variable, data: grib2d.array.data)
                }
                let completed = i == timestamps.count - 1
                return try await writer.finalise(completed: completed, validTimes: Array(timestamps[0...i]), uploadS3Bucket: uploadS3Bucket)
            }
        }
        await curl.printStatistics()
        return handles
    }

    /**
     Download GRIB packaegs SP1, SP2,....
     Issues:
     - MF does not publish 15minutely data via GRIB packages
     - There is no GRIB inventory, so we have to download the entire GRIB file
     */
    func download3(application: Application, domain: MeteoFranceDomain, run: Timestamp, /*upperLevel: Bool,*/ useGovServer: Bool, maxForecastHour: Int?, uploadS3Bucket: String?, packages: [String]?) async throws -> [GenericVariableHandle] {
        guard let apikey = Environment.get("METEOFRANCE_API_KEY")?.split(separator: ",").map(String.init) else {
            fatalError("Please specify environment variable 'METEOFRANCE_API_KEY'")
        }
        let logger = application.logger
        let deadLineHours = domain.timeoutHours
        Process.alarm(seconds: Int(deadLineHours + 0.5) * 3600)
        defer { Process.alarm(seconds: 0) }
        
        let grid = domain.grid
        let nx = grid.nx
        let ny = grid.ny
        let previous = GribDeaverager()
        let packages = packages ?? (domain.mfApiPackagesPressure + domain.mfApiPackagesSurface)
        //upperLevel ? domain.mfApiPackagesPressure : domain.mfApiPackagesSurface
        let curl = Curl(logger: logger, client: application.dedicatedHttpClient, deadLineHours: deadLineHours, waitAfterLastModified: TimeInterval(2 * 60))

        // https://public-api.meteofrance.fr/previnum/DPPaquetAROME/v1/models/AROME/grids/0.025/packages/SP2/productARO?referencetime=2024-06-20T21%3A00%3A00Z&time=00H06H&format=grib2
        // https://object.data.gouv.fr/meteofrance-pnt/pnt/2024-06-23T03:00:00Z/arome/0025/SP1/arome__0025__SP1__00H06H__2024-06-23T03:00:00Z.grib2
        // https://object.data.gouv.fr/meteofrance-pnt/pnt/2024-06-23T00:00:00Z/arpege/01/HP1/arpege__01__HP1__000H012H__2024-06-23T00:00:00Z.grib2

        var validTimes: Set<Timestamp> = []
        
        let handles = try await domain.mfApiPackageTimes.asyncFlatMap { packageTime -> [GenericVariableHandle] in
            if let maxForecastHour {
                if let start = packageTime.split(separator: "H").first.map(String.init)?.toInt() {
                    if start > maxForecastHour {
                        return []
                    }
                }
            }
            let writer = OmSpatialMultistepWriter(domain: domain, run: run, storeOnDisk: true, realm: nil)
            for package in packages {
                let url = "https://public-api.meteofrance.fr/previnum/DPPaquet\(domain.family.mfApiDDP)/v1/models/\(domain.family.mfApiDDP)/grids/\(domain.mfApiGridName)/packages/\(package)/\(domain.family.mfApiProductName)?referencetime=\(run.iso8601_YYYY_MM_dd_HH_mm):00Z&time=\(packageTime)&format=grib2"

                let gridRes = domain.mfApiGridName.replacingOccurrences(of: ".", with: "")
                let urlGov = "https://object.data.gouv.fr/meteofrance-pnt/pnt/\(run.iso8601_YYYY_MM_dd_HH_mm):00Z/\(domain.family.rawValue)/\(gridRes)/\(package)/\(domain.family.rawValue)__\(gridRes)__\(package)__\(packageTime)__\(run.iso8601_YYYY_MM_dd_HH_mm):00Z.grib2"

                let inMemory = VariablePerMemberStorage<MfVariableTemporary>()
                let inMemoryPrecip = VariablePerMemberStorage<MfVariablePrecipTemporary>()
                
                try await curl.downloadGrib(url: useGovServer ? urlGov : url, bzip2Decode: false, nConcurrent: useGovServer ? 4 : 1, headers: [("apikey", apikey.randomElement() ?? "")]).foreachConcurrent(nConcurrent: 1) { message in

                    guard let shortName = message.get(attribute: "shortName"),
                          let stepRange = message.get(attribute: "stepRange"),
                          let stepType = message.get(attribute: "stepType"),
                          let levelStr = message.get(attribute: "level"),
                          let typeOfLevel = message.get(attribute: "typeOfLevel"),
                          let parameterName = message.get(attribute: "parameterName"),
                          let parameterUnits = message.get(attribute: "parameterUnits"),
                          let validityTime = message.get(attribute: "validityTime"),
                          let validityDate = message.get(attribute: "validityDate"),
                          let unit = message.get(attribute: "units"),
                          let paramId = message.get(attribute: "paramId")
                    else {
                        fatalError("could not get attributes")
                    }
                    let timestamp = try Timestamp.from(yyyymmdd: "\(validityDate)\(Int(validityTime)!.zeroPadded(len: 4))")

                    if let temporary = MfVariableTemporary.getVariable(shortName: shortName, levelStr: levelStr, parameterName: parameterName, typeOfLevel: typeOfLevel) {
                        logger.info("Keep in memory: \(shortName) level=\(levelStr) [\(typeOfLevel)] \(stepRange) \(stepType) '\(parameterName)' \(parameterUnits)  id=\(paramId)")
                        var grib2d = GribArray2D(nx: nx, ny: ny)
                        try grib2d.load(message: message)
                        if domain.isGlobal {
                            grib2d.array.shift180LongitudeAndFlipLatitude()
                        } else {
                            grib2d.array.flipLatitude()
                        }
                        await inMemory.set(variable: temporary, timestamp: timestamp, member: 0, data: grib2d.array)
                        return
                    }

                    if domain == .arome_france_hd, let temporary = MfVariablePrecipTemporary.getVariable(shortName: shortName, levelStr: levelStr, parameterName: parameterName, typeOfLevel: typeOfLevel) {
                        logger.info("Keep in memory: \(shortName) level=\(levelStr) [\(typeOfLevel)] \(stepRange) \(stepType) '\(parameterName)' \(parameterUnits)  id=\(paramId)")
                        var grib2d = GribArray2D(nx: nx, ny: ny)
                        try grib2d.load(message: message)
                        if domain.isGlobal {
                            grib2d.array.shift180LongitudeAndFlipLatitude()
                        } else {
                            grib2d.array.flipLatitude()
                        }
                        switch unit {
                        case "kg m-2 s-1": // mm/s to mm/h
                            grib2d.array.data.multiplyAdd(multiply: 3600, add: 0)
                        default:
                            break
                        }
                        // Deaccumulate precipitation
                        guard await previous.deaccumulateIfRequired(variable: temporary, member: 0, stepType: stepType, stepRange: stepRange, grib2d: &grib2d) else {
                            return
                        }
                        await inMemoryPrecip.set(variable: temporary, timestamp: timestamp, member: 0, data: grib2d.array)
                        return
                    }

                    guard let variable = getVariable(shortName: shortName, levelStr: levelStr, parameterName: parameterName, typeOfLevel: typeOfLevel) else {
                        logger.info("Unmapped GRIB message \(shortName) level=\(levelStr) [\(typeOfLevel)] \(stepRange) \(stepType) '\(parameterName)' \(parameterUnits)  id=\(paramId)")
                        return
                    }

                    var grib2d = GribArray2D(nx: nx, ny: ny)
                    // message.dumpAttributes()
                    try grib2d.load(message: message)
                    if domain.isGlobal {
                        grib2d.array.shift180LongitudeAndFlipLatitude()
                    } else {
                        grib2d.array.flipLatitude()
                    }

                    // Scaling before compression with scalefactor
                    if let fma = variable.multiplyAdd {
                        grib2d.array.data.multiplyAdd(multiply: fma.multiply, add: fma.add)
                    }

                    // Deaccumulate precipitation
                    guard await previous.deaccumulateIfRequired(variable: variable, member: 0, stepType: stepType, stepRange: stepRange, grib2d: &grib2d) else {
                        return
                    }

                    logger.info("Compressing and writing data to \(timestamp.format_YYYYMMddHH) \(variable)")
                    try await writer.write(time: timestamp, member: 0, variable: variable, data: grib2d.array.data)
                }
                for writer in await writer.writer {
                    try await inMemory.calculateWindSpeed(u: .ugst, v: .vgst, outSpeedVariable: MeteoFranceSurfaceVariable.wind_gusts_10m, outDirectionVariable: nil, writer: writer)
                    try await inMemoryPrecip.calculatePrecip(tgrp: .tgrp, tirf: .tirf, tsnowp: .tsnowp, outVariable: MeteoFranceSurfaceVariable.precipitation, writer: writer)
                }
            }
            
            for writer in await writer.writer {
                validTimes.insert(writer.time)
            }
            let completed = packageTime == domain.mfApiPackageTimes.last
            return try await writer.finalise(completed: completed, validTimes: Array(validTimes).sorted(), uploadS3Bucket: uploadS3Bucket)
        }
        await curl.printStatistics()
        return handles
    }

    func getVariable(shortName: String, levelStr: String, parameterName: String, typeOfLevel: String) -> (any MeteoFranceVariableDownloadable)? {
        switch (parameterName, levelStr) {
        case ("Total cloud cover", "0"):
            return MeteoFranceSurfaceVariable.cloud_cover
        default:
            break
        }

        if typeOfLevel == "isobaricInhPa" {
            guard let level = Int(levelStr) else {
                fatalError("Could not parse level str \(levelStr)")
            }
            if level < 10 {
                return nil
            }
            switch shortName {
            case "t":
                return MeteoFrancePressureVariable(variable: .temperature, level: level)
            case "u":
                return MeteoFrancePressureVariable(variable: .wind_u_component, level: level)
            case "v":
                return MeteoFrancePressureVariable(variable: .wind_v_component, level: level)
            case "r":
                return MeteoFrancePressureVariable(variable: .relative_humidity, level: level)
            case "z":
                return MeteoFrancePressureVariable(variable: .geopotential_height, level: level)
            default:
                break
            }
        }

        switch (shortName, typeOfLevel, levelStr) {
        case ("t", "heightAboveGround", "20"):
            return MeteoFranceSurfaceVariable.temperature_20m
        case ("t", "heightAboveGround", "50"):
            return MeteoFranceSurfaceVariable.temperature_50m
        case ("t", "heightAboveGround", "100"):
            return MeteoFranceSurfaceVariable.temperature_100m
        case ("t", "heightAboveGround", "150"):
            return MeteoFranceSurfaceVariable.temperature_150m
        case ("t", "heightAboveGround", "200"):
            return MeteoFranceSurfaceVariable.temperature_200m
        case ("u", "heightAboveGround", "20"):
            return MeteoFranceSurfaceVariable.wind_u_component_20m
        case ("u", "heightAboveGround", "50"):
            return MeteoFranceSurfaceVariable.wind_u_component_50m
        case ("100u", "heightAboveGround", "100"):
            return MeteoFranceSurfaceVariable.wind_u_component_100m
        case ("u", "heightAboveGround", "150"):
            return MeteoFranceSurfaceVariable.wind_u_component_150m
        case ("200u", "heightAboveGround", "200"):
            return MeteoFranceSurfaceVariable.wind_u_component_200m
        case ("v", "heightAboveGround", "20"):
            return MeteoFranceSurfaceVariable.wind_v_component_20m
        case ("v", "heightAboveGround", "50"):
            return MeteoFranceSurfaceVariable.wind_v_component_50m
        case ("100v", "heightAboveGround", "100"):
            return MeteoFranceSurfaceVariable.wind_v_component_100m
        case ("v", "heightAboveGround", "150"):
            return MeteoFranceSurfaceVariable.wind_v_component_150m
        case ("200v", "heightAboveGround", "200"):
            return MeteoFranceSurfaceVariable.wind_v_component_200m

        default:
            break
        }

        switch (shortName, levelStr) {
        case ("2t", "2"):
            return MeteoFranceSurfaceVariable.temperature_2m
        case ("2r", "2"):
            return MeteoFranceSurfaceVariable.relative_humidity_2m
        case ("tp", "0"):
            return MeteoFranceSurfaceVariable.precipitation
        case ("prmsl", "0"):
              return MeteoFranceSurfaceVariable.pressure_msl
        case ("10v", "10"):
              return MeteoFranceSurfaceVariable.wind_v_component_10m
        case ("10u", "10"):
              return MeteoFranceSurfaceVariable.wind_u_component_10m
        case ("clct", "0"):
              return MeteoFranceSurfaceVariable.cloud_cover
        case ("snow_gsp", "0"):
              return MeteoFranceSurfaceVariable.snowfall_water_equivalent
        case ("10fg", "10"):
            return MeteoFranceSurfaceVariable.wind_gusts_10m
        case ("ssrd", "0"):
            return MeteoFranceSurfaceVariable.shortwave_radiation
        case ("lcc", "0"):
            return MeteoFranceSurfaceVariable.cloud_cover_low
        case ("mcc", "0"):
            return MeteoFranceSurfaceVariable.cloud_cover_mid
        case ("hcc", "0"):
            return MeteoFranceSurfaceVariable.cloud_cover_high
        case ("CAPE_INS", "0"):
            return MeteoFranceSurfaceVariable.cape
        case ("tsnowp", "0"):
            return MeteoFranceSurfaceVariable.snowfall_water_equivalent
        default: return nil
        }
    }

    /// Download one field at a time
    func download2(application: Application, domain: MeteoFranceDomain, run: Timestamp, variables: [any MeteoFranceVariableDownloadable], uploadS3Bucket: String?) async throws -> [GenericVariableHandle] {
        guard let apikey = Environment.get("METEOFRANCE_API_KEY")?.split(separator: ",").map(String.init) else {
            fatalError("Please specify environment variable 'METEOFRANCE_API_KEY'")
        }
        let logger = application.logger
        let deadLineHours = domain.timeoutHours
        Process.alarm(seconds: Int(deadLineHours + 1) * 3600)
        defer { Process.alarm(seconds: 0) }

        let grid = domain.grid
        var grib2d = GribArray2D(nx: grid.nx, ny: grid.ny)
        let subsetGrid = domain.mfSubsetGrid

        let timestamps = domain.forecastSeconds(run: run.hour, hourlyForArpegeEurope: true).map { run.add($0) }

        let handles: [GenericVariableHandle] = try await timestamps.enumerated().asyncFlatMap { (i,timestamp) -> [GenericVariableHandle] in
            let seconds = timestamp.timeIntervalSince1970 - run.timeIntervalSince1970
            let writer = OmSpatialTimestepWriter(domain: domain, run: run, time: timestamp, storeOnDisk: true, realm: nil)
            
            for variable in variables {
                guard variable.availableFor(domain: domain, forecastSecond: seconds) else {
                    continue
                }
                if seconds == 0 && variable.skipHour0(domain: domain) {
                    continue
                }
                let coverage = variable.getCoverageId(domain: domain)
                let subsetHeight = coverage.height.map { "&subset=height(\($0))" } ?? ""
                let subsetPressure = coverage.pressure.map { "&subset=pressure(\($0))" } ?? ""
                let subsetTime = "&subset=time(\(seconds))"
                let runTime = "\(run.iso8601_YYYY_MM_dd)T\(run.hour.zeroPadded(len: 2)).00.00Z"
                // let is3H = domain == .arpege_world && (seconds/3600) >= 51
                let period = coverage.periodMinutes.map { $0 >= 60 ? "_PT\($0 / 60)H" : "_PT\($0)M" } ?? ""

                let url = "https://public-api.meteofrance.fr/public/\(domain.family.rawValue)/1.0/wcs/\(domain.mfApiName)-WCS/GetCoverage?service=WCS&version=2.0.1&coverageid=\(coverage.variable)___\(runTime)\(period)\(subsetGrid)\(subsetHeight)\(subsetPressure)\(subsetTime)&format=application%2Fwmo-grib"

                /// MeteoFrance servers close the HTTP connection unclean, resulting in `connection reset by peer` errors
                /// Use a new HTTP client with new connections for every request
                let client = application.makeNewHttpClient()
                let curl = Curl(logger: logger, client: client, deadLineHours: deadLineHours, waitAfterLastModified: TimeInterval(2 * 60))
                let message = try await curl.downloadGrib(url: url, bzip2Decode: false, headers: [("apikey", apikey.randomElement() ?? "")])[0]

                // try message.debugGrid(grid: grid, flipLatidude: true, shift180Longitude: true)
                // message.dumpAttributes()

                try grib2d.load(message: message)
                try await client.shutdown()
                if domain.isGlobal {
                    grib2d.array.shift180LongitudeAndFlipLatitude()
                } else {
                    grib2d.array.flipLatitude()
                }
                if let fma = variable.multiplyAdd {
                    grib2d.array.data.multiplyAdd(multiply: fma.multiply, add: fma.add)
                }
                try await writer.write(member: 0, variable: variable, data: grib2d.array.data)
            }
            let completed = i == timestamps.count - 1
            let handles = try await writer.finalise(completed: completed, validTimes: Array(timestamps[0...i]), uploadS3Bucket: uploadS3Bucket)
            return handles
        }
        // await curl.printStatistics()
        return handles
    }
}
