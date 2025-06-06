import Foundation
import Vapor

typealias GloFasVariableMember = GloFasVariable

struct GloFasMixer: GenericReaderMixer {
    let reader: [GloFasReader]

    static func makeReader(domain: GloFasReader.Domain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode, options: GenericReaderOptions) async throws -> GloFasReader? {
        return try await GloFasReader(domain: domain, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
    }
}

enum GlofasDerivedVariable: String, CaseIterable, GenericVariableMixable {
    case river_discharge_mean
    case river_discharge_min
    case river_discharge_max
    case river_discharge_median
    case river_discharge_p25
    case river_discharge_p75

    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

typealias GloFasVariableOrDerived = VariableOrDerived<GloFasVariable, GlofasDerivedVariable>
typealias GloFasVariableOrDerivedMember = VariableOrDerived<GloFasVariableMember, GloFasReader.Derived>

struct GloFasReader: GenericReaderDerivedSimple, GenericReaderProtocol {
    let reader: GenericReaderCached<GloFasDomain, GloFasVariableMember>

    typealias Domain = GloFasDomain

    typealias Variable = GloFasVariableMember

    typealias Derived = GlofasDerivedVariable

    public init?(domain: Domain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode, options: GenericReaderOptions) async throws {
        guard let reader = try await GenericReader<Domain, Variable>(domain: domain, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) else {
            return nil
        }
        self.reader = GenericReaderCached(reader: reader)
    }

    func prefetchData(derived: GlofasDerivedVariable, time: TimerangeDtAndSettings) async throws {
        for member in 0..<51 {
            try await reader.prefetchData(variable: .river_discharge, time: time.with(ensembleMember: member))
        }
    }

    func get(derived: GlofasDerivedVariable, time: TimerangeDtAndSettings) async throws -> DataAndUnit {
        let data = try await (0..<51).asyncMap({
            try await reader.get(variable: .river_discharge, time: time.with(ensembleMember: $0)).data
        })
        if data[0].onlyNaN() {
            return DataAndUnit(data[0], .cubicMetrePerSecond)
        }
        switch derived {
        case .river_discharge_mean:
            return DataAndUnit((0..<time.time.count).map { t in
                data.reduce(0, { $0 + $1[t] }) / Float(data.count)
            }, .cubicMetrePerSecond)
        case .river_discharge_min:
            return DataAndUnit((0..<time.time.count).map { t in
                data.reduce(Float.nan, { $0.isNaN || $1[t] < $0 ? $1[t] : $0 })
            }, .cubicMetrePerSecond)
        case .river_discharge_max:
            return DataAndUnit((0..<time.time.count).map { t in
                data.reduce(Float.nan, { $0.isNaN || $1[t] > $0 ? $1[t] : $0 })
            }, .cubicMetrePerSecond)
        case .river_discharge_median:
            return DataAndUnit((0..<time.time.count).map { t in
                data.map({ $0[t] }).sorted().interpolateLinear(Int(Float(data.count) * 0.5), (Float(data.count) * 0.5).truncatingRemainder(dividingBy: 1) )
            }, .cubicMetrePerSecond)
        case .river_discharge_p25:
            return DataAndUnit((0..<time.time.count).map { t in
                data.map({ $0[t] }).sorted().interpolateLinear(Int(Float(data.count) * 0.25), (Float(data.count) * 0.25).truncatingRemainder(dividingBy: 1) )
            }, .cubicMetrePerSecond)
        case .river_discharge_p75:
            return DataAndUnit((0..<time.time.count).map { t in
                data.map({ $0[t] }).sorted().interpolateLinear(Int(Float(data.count) * 0.75), (Float(data.count) * 0.75).truncatingRemainder(dividingBy: 1) )
            }, .cubicMetrePerSecond)
        }
    }
}

struct GloFasController {
    func query(_ req: Request) async throws -> Response {
        try await req.withApiParameter("flood-api") { _, params in
            let currentTime = Timestamp.now()
            let allowedRange = Timestamp(1984, 1, 1) ..< currentTime.add(86400 * 230)
            let logger = req.logger
            let httpClient = req.application.http.client.shared

            let prepared = try await params.prepareCoordinates(allowTimezones: false, logger: logger, httpClient: httpClient)
            guard case .coordinates(let prepared) = prepared else {
                throw ForecastapiError.generic(message: "Bounding box not supported")
            }
            let domains = try GlofasDomainApi.load(commaSeparatedOptional: params.models) ?? [.best_match]
            guard let paramsDaily = try GloFasVariableOrDerived.load(commaSeparatedOptional: params.daily) else {
                throw ForecastapiError.generic(message: "Parameter 'daily' required")
            }
            let nVariables = (params.ensemble ? 51 : 1) * domains.count
            let options = try params.readerOptions(logger: logger, httpClient: httpClient)

            let locations: [ForecastapiResult<GlofasDomainApi>.PerLocation] = try await prepared.asyncMap { prepared in
                let coordinates = prepared.coordinate
                let timezone = prepared.timezone
                let time = try params.getTimerange2(timezone: timezone, current: currentTime, forecastDaysDefault: 92, forecastDaysMax: 366, startEndDate: prepared.startEndDate, allowedRange: allowedRange, pastDaysMax: 92)
                let timeLocal = TimerangeLocal(range: time.dailyRead.range, utcOffsetSeconds: timezone.utcOffsetSeconds)

                let readers: [ForecastapiResult<GlofasDomainApi>.PerModel] = try await domains.asyncCompactMap { domain in
                    guard let reader = try await domain.getReader(lat: coordinates.latitude, lon: coordinates.longitude, elevation: .nan, mode: params.cell_selection ?? .nearest, options: options) else {
                        return nil
                    }
                    return ForecastapiResult<GlofasDomainApi>.PerModel(
                        model: domain,
                        latitude: reader.modelLat,
                        longitude: reader.modelLon,
                        elevation: reader.targetElevation,
                        prefetch: {
                            for param in paramsDaily {
                                try await reader.prefetchData(variable: param, time: time.dailyRead.toSettings())
                            }
                            if params.ensemble {
                                for member in 1..<51 {
                                    try await reader.prefetchData(variable: .raw(.river_discharge), time: time.dailyRead.toSettings(ensembleMember: member))
                                }
                            }
                        },
                        current: nil,
                        hourly: nil,
                        daily: {
                            return await ApiSection<GloFasVariableOrDerived>(name: "daily", time: time.dailyDisplay, columns: try paramsDaily.asyncMap { variable in
                                switch variable {
                                case .raw:
                                    let d = try await (params.ensemble ? (0..<51) : (0..<1)).asyncMap { member -> ApiArray in
                                        let d = try await reader.get(variable: .raw(.river_discharge), time: time.dailyRead.toSettings(ensembleMember: member)).convertAndRound(params: params)
                                        assert(time.dailyRead.count == d.data.count, "days \(time.dailyRead.count), values \(d.data.count)")
                                        return ApiArray.float(d.data)
                                    }
                                    return ApiColumn<GloFasVariableOrDerived>(variable: variable, unit: .cubicMetrePerSecond, variables: d)
                                case .derived(let derived):
                                    let d = try await reader.get(variable: .derived(derived), time: time.dailyRead.toSettings()).convertAndRound(params: params)
                                    assert(time.dailyRead.count == d.data.count, "days \(time.dailyRead.count), values \(d.data.count)")
                                    return ApiColumn<GloFasVariableOrDerived>(variable: variable, unit: .cubicMetrePerSecond, variables: [.float(d.data)])
                                }
                            })
                        },
                        sixHourly: nil,
                        minutely15: nil
                    )
                }
                guard !readers.isEmpty else {
                    throw ForecastapiError.noDataAvilableForThisLocation
                }
                return .init(timezone: timezone, time: timeLocal, locationId: coordinates.locationId, results: readers)
            }
            return ForecastapiResult<GlofasDomainApi>(timeformat: params.timeformatOrDefault, results: locations, nVariablesTimesDomains: nVariables)
        }
    }
}

enum GlofasDomainApi: String, RawRepresentableString, CaseIterable, Sendable {
    case best_match

    case seamless_v3
    case forecast_v3
    case consolidated_v3

    case seamless_v4
    case forecast_v4
    case consolidated_v4

    /// Return the required readers for this domain configuration
    /// Note: last reader has highes resolution data
    func getReader(lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode, options: GenericReaderOptions) async throws -> GloFasMixer? {
        switch self {
        case .best_match:
            return try await GloFasMixer(domains: [.seasonalv3, .consolidatedv3, .intermediatev3, .forecastv3, .seasonal, .consolidated, .intermediate, .forecast], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
        case .seamless_v3:
            return try await GloFasMixer(domains: [.seasonalv3, .consolidatedv3, .intermediatev3, .forecastv3], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
        case .forecast_v3:
            return try await GloFasMixer(domains: [.seasonalv3, .intermediatev3, .forecastv3], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
        case .seamless_v4:
            return try await GloFasMixer(domains: [.seasonal, .consolidated, .intermediate, .forecast], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
        case .forecast_v4:
            return try await GloFasMixer(domains: [.seasonal, .intermediate, .forecast], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
        case .consolidated_v3:
            return try await GloFasMixer(domains: [.consolidatedv3], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
        case .consolidated_v4:
            return try await GloFasMixer(domains: [.consolidated], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
        }
    }
}
