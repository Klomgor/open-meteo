import Foundation
import OpenMeteoSdk
import Vapor

public struct ForecastapiController: RouteCollection {
    public func boot(routes: RoutesBuilder) throws {
        let categoriesRoute = routes.grouped("v1")
        let era5 = WeatherApiController(
            has15minutely: false,
            hasCurrentWeather: false,
            defaultModel: .archive_best_match,
            subdomain: "archive-api",
            alias: ["satellite-api"]
        )
        categoriesRoute.getAndPost("era5", use: era5.query)
        categoriesRoute.getAndPost("archive", use: era5.query)

        categoriesRoute.getAndPost("forecast", use: WeatherApiController(
            defaultModel: .best_match,
            alias: ["historical-forecast-api", "previous-runs-api"]).query
        )
        categoriesRoute.getAndPost("dwd-icon", use: WeatherApiController(
            defaultModel: .icon_seamless).query
        )
        categoriesRoute.getAndPost("gfs", use: WeatherApiController(
            has15minutely: true,
            defaultModel: .gfs_seamless).query
        )
        categoriesRoute.getAndPost("meteofrance", use: WeatherApiController(
            has15minutely: true,
            defaultModel: .meteofrance_seamless).query
        )
        categoriesRoute.getAndPost("jma", use: WeatherApiController(
            has15minutely: false,
            defaultModel: .jma_seamless).query
        )
        categoriesRoute.getAndPost("metno", use: WeatherApiController(
            has15minutely: false,
            defaultModel: .metno_nordic).query
        )
        categoriesRoute.getAndPost("gem", use: WeatherApiController(
            has15minutely: false,
            defaultModel: .gem_seamless).query
        )
        categoriesRoute.getAndPost("ecmwf", use: WeatherApiController(
            has15minutely: false,
            hasCurrentWeather: false,
            defaultModel: .ecmwf_ifs025).query
        )
        categoriesRoute.getAndPost("cma", use: WeatherApiController(
            has15minutely: false,
            defaultModel: .cma_grapes_global).query
        )
        categoriesRoute.getAndPost("bom", use: WeatherApiController(
            has15minutely: false,
            defaultModel: .bom_access_global).query
        )
        categoriesRoute.getAndPost("arpae", use: WeatherApiController(
            has15minutely: false,
            defaultModel: .arpae_cosmo_seamless).query
        )

        categoriesRoute.getAndPost("elevation", use: DemController().query)
        categoriesRoute.getAndPost("air-quality", use: CamsController().query)
        categoriesRoute.getAndPost("seasonal", use: SeasonalForecastController().query)
        categoriesRoute.getAndPost("flood", use: GloFasController().query)
        categoriesRoute.getAndPost("climate", use: CmipController().query)
        categoriesRoute.getAndPost("marine", use: IconWaveController().query)
        categoriesRoute.getAndPost("ensemble", use: EnsembleApiController().query)
    }
}

struct WeatherApiController {
    let has15minutely: Bool
    let hasCurrentWeather: Bool
    let defaultModel: MultiDomains
    let subdomain: String
    let alias: [String]

    init(has15minutely: Bool = true, hasCurrentWeather: Bool = true, defaultModel: MultiDomains, subdomain: String = "api", alias: [String] = []) {
        self.has15minutely = has15minutely
        self.hasCurrentWeather = hasCurrentWeather
        self.defaultModel = defaultModel
        self.subdomain = subdomain
        self.alias = alias
    }
    
    enum ApiType {
        /// Self-host or localhost
        case none
        case forecast
        case archive
        case historicalForecast
        case previousRuns
        case satellite
        
        static func detect(host: String?) -> Self {
            guard let host else {
                return .none
            }
            if host.starts(with: "historical-forecast-api") || host.starts(with: "customer-historical-forecast-api") {
                return .historicalForecast
            }
            if host.starts(with: "previous-runs-api") || host.starts(with: "customer-previous-runs-api") {
                return .previousRuns
            }
            if host.starts(with: "archive-api") || host.starts(with: "customer-archive-api") {
                return .archive
            }
            if host.starts(with: "satellite-api") || host.starts(with: "customer-satellite-api") {
                return .satellite
            }
            return .forecast
        }
    }

    func query(_ req: Request) async throws -> Response {
        try await req.withApiParameter(subdomain, alias: alias) { host, params in
            let type = ApiType.detect(host: host)
            let currentTime = Timestamp.now()
            let currentTimeHour0 = currentTime.with(hour: 0)
            
            let forecastDaysMax: Int
            let forecastDayDefault: Int
            let historyStartDate: Timestamp
            switch type {
            case .none:
                forecastDaysMax = 16
                forecastDayDefault = 7
                historyStartDate = Timestamp(1940, 1, 1)
            case .forecast:
                forecastDaysMax = 16
                forecastDayDefault = 7
                historyStartDate = currentTimeHour0.subtract(days: 93)
            case .archive:
                forecastDaysMax = 1
                forecastDayDefault = 1
                historyStartDate = Timestamp(1940, 1, 1)
            case .historicalForecast:
                forecastDaysMax = 16
                forecastDayDefault = 1
                historyStartDate = Timestamp(2016, 1, 1)
            case .previousRuns:
                forecastDaysMax = 16
                forecastDayDefault = 7
                historyStartDate = Timestamp(2016, 1, 1)
            case .satellite:
                forecastDaysMax = 1
                forecastDayDefault = 1
                historyStartDate = Timestamp(1983, 1, 1)
            }
            
            let pastDaysMax = (currentTimeHour0.timeIntervalSince1970 - historyStartDate.timeIntervalSince1970) / 86400
            let allowedRange = historyStartDate ..< currentTimeHour0.add(days: forecastDaysMax)

            let domains = try MultiDomains.load(commaSeparatedOptional: params.models)?.map({ $0 == .best_match ? defaultModel : $0 }) ?? [defaultModel]
            let paramsMinutely = has15minutely ? try ForecastVariable.load(commaSeparatedOptional: params.minutely_15) : nil
            let defaultCurrentWeather = [ForecastVariable.surface(.init(.temperature, 0)), .surface(.init(.windspeed, 0)), .surface(.init(.winddirection, 0)), .surface(.init(.is_day, 0)), .surface(.init(.weathercode, 0))]
            let paramsCurrent: [ForecastVariable]? = !hasCurrentWeather ? nil : params.current_weather == true ? defaultCurrentWeather : try ForecastVariable.load(commaSeparatedOptional: params.current)
            let paramsHourly = try ForecastVariable.load(commaSeparatedOptional: params.hourly)
            let paramsDaily = try ForecastVariableDaily.load(commaSeparatedOptional: params.daily)
            let nParamsHourly = paramsHourly?.count ?? 0
            let nParamsMinutely = paramsMinutely?.count ?? 0
            let nParamsCurrent = paramsCurrent?.count ?? 0
            let nParamsDaily = paramsDaily?.count ?? 0
            let nVariables = (nParamsHourly + nParamsMinutely + nParamsCurrent + nParamsDaily) * domains.count
            let options = try params.readerOptions(for: req)

            /// Prepare readers based on geometry
            /// Readers are returned as a callback to release memory after data has been retrieved
            let prepared = try await GenericReaderMulti<ForecastVariable, MultiDomains>.prepareReaders(domains: domains, params: params, options: options, currentTime: currentTime, forecastDayDefault: forecastDayDefault, forecastDaysMax: forecastDaysMax, pastDaysMax: pastDaysMax, allowedRange: allowedRange)

            let locations: [ForecastapiResult<MultiDomains>.PerLocation] = try await prepared.asyncMap { prepared in
                let timezone = prepared.timezone
                let time = prepared.time
                let timeLocal = TimerangeLocal(range: time.dailyRead.range, utcOffsetSeconds: timezone.utcOffsetSeconds)
                let currentTimeRange = TimerangeDt(start: currentTime.floor(toNearest: 3600 / 4), nTime: 1, dtSeconds: 3600 / 4)

                let readers: [ForecastapiResult<MultiDomains>.PerModel] = try await prepared.perModel.asyncCompactMap { readerAndDomain in
                    guard let reader = try await readerAndDomain.reader() else {
                        return nil
                    }
                    let hourlyDt = (params.temporal_resolution ?? .hourly).dtSeconds ?? reader.modelDtSeconds
                    let timeHourlyRead = time.hourlyRead.with(dtSeconds: hourlyDt)
                    let timeHourlyDisplay = time.hourlyDisplay.with(dtSeconds: hourlyDt)
                    let domain = readerAndDomain.domain

                    return .init(
                        model: domain,
                        latitude: reader.modelLat,
                        longitude: reader.modelLon,
                        elevation: reader.targetElevation,
                        prefetch: {
                            if let paramsCurrent {
                                for variable in paramsCurrent {
                                    let (v, previousDay) = variable.variableAndPreviousDay
                                    try await reader.prefetchData(variable: v, time: currentTimeRange.toSettings(previousDay: previousDay))
                                }
                            }
                            if let paramsMinutely {
                                for variable in paramsMinutely {
                                    let (v, previousDay) = variable.variableAndPreviousDay
                                    try await reader.prefetchData(variable: v, time: time.minutely15.toSettings(previousDay: previousDay))
                                }
                            }
                            if let paramsHourly {
                                for variable in paramsHourly {
                                    let (v, previousDay) = variable.variableAndPreviousDay
                                    try await reader.prefetchData(variable: v, time: timeHourlyRead.toSettings(previousDay: previousDay))
                                }
                            }
                            if let paramsDaily {
                                try await reader.prefetchData(variables: paramsDaily, time: time.dailyRead.toSettings())
                            }
                        },
                        current: paramsCurrent.map { variables in
                            return {
                                .init(name: params.current_weather == true ? "current_weather" : "current", time: currentTimeRange.range.lowerBound, dtSeconds: currentTimeRange.dtSeconds, columns: try await variables.asyncMap { variable in
                                    let (v, previousDay) = variable.variableAndPreviousDay
                                    guard let d = try await reader.get(variable: v, time: currentTimeRange.toSettings(previousDay: previousDay))?.convertAndRound(params: params) else {
                                        return .init(variable: variable.resultVariable, unit: .undefined, value: .nan)
                                    }
                                    return .init(variable: variable.resultVariable, unit: d.unit, value: d.data.first ?? .nan)
                                })
                            }
                        },
                        hourly: paramsHourly.map { variables in
                            return {
                                return .init(name: "hourly", time: timeHourlyDisplay, columns: try await variables.asyncMap { variable in
                                    let (v, previousDay) = variable.variableAndPreviousDay
                                    guard let d = try await reader.get(variable: v, time: timeHourlyRead.toSettings(previousDay: previousDay))?.convertAndRound(params: params) else {
                                        return .init(variable: variable.resultVariable, unit: .undefined, variables: [.float([Float](repeating: .nan, count: timeHourlyRead.count))])
                                    }
                                    assert(timeHourlyRead.count == d.data.count)
                                    return .init(variable: variable.resultVariable, unit: d.unit, variables: [.float(d.data)])
                                })
                            }
                        },
                        daily: paramsDaily.map { dailyVariables in
                            return {
                                var riseSet: (rise: [Timestamp], set: [Timestamp])?
                                return ApiSection(name: "daily", time: time.dailyDisplay, columns: try await dailyVariables.asyncMap { variable -> ApiColumn<ForecastVariableDaily> in
                                    if variable == .sunrise || variable == .sunset {
                                        // only calculate sunrise/set once. Need to use `dailyDisplay` to make sure half-hour time zone offsets are applied correctly
                                        let times = riseSet ?? Zensun.calculateSunRiseSet(timeRange: time.dailyDisplay.range, lat: reader.modelLat, lon: reader.modelLon, utcOffsetSeconds: timezone.utcOffsetSeconds)
                                        riseSet = times
                                        if variable == .sunset {
                                            return ApiColumn(variable: .sunset, unit: params.timeformatOrDefault.unit, variables: [.timestamp(times.set)])
                                        } else {
                                            return ApiColumn(variable: .sunrise, unit: params.timeformatOrDefault.unit, variables: [.timestamp(times.rise)])
                                        }
                                    }
                                    if variable == .daylight_duration {
                                        let duration = Zensun.calculateDaylightDuration(localMidnight: time.dailyDisplay.range, lat: reader.modelLat)
                                        return ApiColumn(variable: .daylight_duration, unit: .seconds, variables: [.float(duration)])
                                    }

                                    guard let d = try await reader.getDaily(variable: variable, params: params, time: time.dailyRead.toSettings()) else {
                                        return ApiColumn(variable: variable, unit: .undefined, variables: [.float([Float](repeating: .nan, count: time.dailyRead.count))])
                                    }
                                    assert(time.dailyRead.count == d.data.count)
                                    return ApiColumn(variable: variable, unit: d.unit, variables: [.float(d.data)])
                                })
                            }
                        },
                        sixHourly: nil,
                        minutely15: paramsMinutely.map { variables in
                            return {
                                return .init(name: "minutely_15", time: time.minutely15, columns: try await variables.asyncMap { variable in
                                    let (v, previousDay) = variable.variableAndPreviousDay
                                    guard let d = try await reader.get(variable: v, time: time.minutely15.toSettings(previousDay: previousDay))?.convertAndRound(params: params) else {
                                        return ApiColumn(variable: variable.resultVariable, unit: .undefined, variables: [.float([Float](repeating: .nan, count: time.minutely15.count))])
                                    }
                                    assert(time.minutely15.count == d.data.count)
                                    return .init(variable: variable.resultVariable, unit: d.unit, variables: [.float(d.data)])
                                })
                            }
                        }
                    )
                }
                guard !readers.isEmpty else {
                    throw ForecastapiError.noDataAvilableForThisLocation
                }
                return .init(timezone: timezone, time: timeLocal, locationId: prepared.locationId, results: readers)
            }
            return ForecastapiResult<MultiDomains>(timeformat: params.timeformatOrDefault, results: locations, nVariablesTimesDomains: nVariables)
        }
    }
}

extension ForecastVariable {
    var resultVariable: ForecastapiResult<MultiDomains>.SurfacePressureAndHeightVariable {
        switch self {
        case .pressure(let p):
            return .pressure(.init(p.variable, p.level))
        case .surface(let s):
            return .surface(s)
        case .height(let h):
            return .height(.init(h.variable, h.level))
        }
    }
}

/**
 Automatic domain selection rules:
 - If HRRR domain matches, use HRRR+GFS+ICON
 - If Western Europe, use Arome + ICON_EU+ ICON + GFS
 - If Central Europe, use ICON_D2, ICON_EU, ICON + GFS
 - If Japan, use JMA_MSM + ICON + GFS
 - default ICON + GFS
 
 Note Nov 2022: Use the term `seamless` instead of `mix`
 */
enum MultiDomains: String, RawRepresentableString, CaseIterable, MultiDomainMixerDomain, Sendable {
    case best_match

    case gfs_seamless
    case gfs_mix
    case gfs_global
    case gfs025
    case gfs013
    case gfs_hrrr
    case gfs_graphcast025
    
    case ncep_seamless
    case ncep_gfs_global
    case ncep_nbm_conus
    case ncep_gfs025
    case ncep_gfs013
    case ncep_hrrr_conus
    case ncep_hrrr_conus_15min
    case ncep_gfs_graphcast025
    
    case meteofrance_seamless
    case meteofrance_mix
    case meteofrance_arpege_seamless
    case meteofrance_arpege_world
    case meteofrance_arpege_europe
    case meteofrance_arome_seamless
    case meteofrance_arome_france
    case meteofrance_arome_france0025
    case meteofrance_arpege_world025
    case meteofrance_arome_france_hd
    case meteofrance_arome_france_hd_15min
    case meteofrance_arome_france_15min
    case arpege_seamless
    case arpege_world
    case arpege_europe
    case arome_seamless
    case arome_france
    case arome_france_hd

    case jma_seamless
    case jma_mix
    case jma_msm
    case jms_gsm
    case jma_gsm

    case gem_seamless
    case gem_global
    case gem_regional
    case gem_hrdps_continental
    case cmc_gem_gdps
    case cmc_gem_hrdps
    case cmc_gem_rdps

    case icon_seamless
    case icon_mix
    case icon_global
    case icon_eu
    case icon_d2
    case dwd_icon_seamless
    case dwd_icon_global
    case dwd_icon
    case dwd_icon_eu
    case dwd_icon_d2
    case dwd_icon_d2_15min

    case ecmwf_ifs04
    case ecmwf_ifs025
    case ecmwf_aifs025
    case ecmwf_aifs025_single

    case metno_nordic

    case cma_grapes_global

    case bom_access_global

    case archive_best_match
    case era5_seamless
    case era5
    case cerra
    case era5_land
    case era5_ensemble
    case copernicus_era5_seamless
    case copernicus_era5
    case copernicus_cerra
    case copernicus_era5_land
    case copernicus_era5_ensemble
    case ecmwf_ifs
    case ecmwf_ifs_analysis
    case ecmwf_ifs_analysis_long_window
    case ecmwf_ifs_long_window

    case arpae_cosmo_seamless
    case arpae_cosmo_2i
    case arpae_cosmo_2i_ruc
    case arpae_cosmo_5m

    case knmi_harmonie_arome_europe
    case knmi_harmonie_arome_netherlands
    case dmi_harmonie_arome_europe
    case knmi_seamless
    case dmi_seamless
    case metno_seamless

    case ukmo_seamless
    case ukmo_global_deterministic_10km
    case ukmo_uk_deterministic_2km

    case satellite_radiation_seamless
    case eumetsat_sarah3
    case eumetsat_lsa_saf_msg
    case eumetsat_lsa_saf_iodc
    case jma_jaxa_himawari

    case kma_seamless
    case kma_gdps
    case kma_ldps

    case italia_meteo_arpae_icon_2i

    case meteoswiss_icon_ch1
    case meteoswiss_icon_ch2
    case meteoswiss_icon_seamless
    
    /// Return the required readers for this domain configuration
    /// Note: last reader has highes resolution data
    func getReader(lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode, options: GenericReaderOptions) async throws -> [any GenericReaderProtocol] {
        switch self {
        case .best_match:
            guard let icon: any GenericReaderProtocol = try await IconReader(domain: .icon, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) else {
                throw ModelError.domainInitFailed(domain: IconDomains.icon.rawValue)
            }
            let gfsProbabilites = try await ProbabilityReader.makeGfsReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let iconProbabilities = try await ProbabilityReader.makeIconReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)

            guard let gfs: any GenericReaderProtocol = try await GfsReader(domains: [.gfs025, .gfs013], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) else {
                throw ModelError.domainInitFailed(domain: IconDomains.icon.rawValue)
            }
            // For Netherlands and Belgium use KNMI
            if (49.35..<53.79).contains(lat), (2.19..<7.66).contains(lon), let knmiNetherlands = try await KnmiReader(domain: KnmiDomain.harmonie_arome_netherlands, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                let probabilities = try await ProbabilityReader.makeEcmwfReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let ecmwf = try await EcmwfReader(domain: .ifs025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let iconEu = try await IconReader(domain: .iconEu, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let iconD2 = try await IconReader(domain: .iconD2, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                return Array([gfsProbabilites, probabilities, gfs, icon, iconEu, iconD2, ecmwf, knmiNetherlands].compacted())
            }
            // Scandinavian region, combine with ICON
            if lat >= 54.9, let metno = try await MetNoReader(domain: .nordic_pp, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                let iconEu = try await IconReader(domain: .iconEu, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let probabilities = try await ProbabilityReader.makeEcmwfReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let ecmwf = try await EcmwfReader(domain: .ifs025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let iconD2 = try await IconReader(domain: .iconD2, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                return Array([gfsProbabilites, probabilities, gfs, icon, iconEu, iconD2, ecmwf, metno].compacted())
            }
            // If Icon-d2 is available, use icon domains
            if let iconD2 = try await IconReader(domain: .iconD2, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options),
               let iconD2_15min = try await IconReader(domain: .iconD2_15min, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                // TODO: check how out of projection areas are handled
                guard let iconEu = try await IconReader(domain: .iconEu, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) else {
                    throw ModelError.domainInitFailed(domain: IconDomains.icon.rawValue)
                }
                return [gfsProbabilites, iconProbabilities, gfs, icon, iconEu, iconD2, iconD2_15min]
            }
            // For western europe, use arome models
            if (42.10..<51.32).contains(lat), (-6.18..<8.35).contains(lon), let arome_france_hd = try await MeteoFranceReader(domain: .arome_france_hd, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                let arome_france_hd_15min = try await MeteoFranceReader(domain: .arome_france_hd_15min, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let arome_france = try await MeteoFranceReader(domain: .arome_france, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let arome_france_15min = try await MeteoFranceReader(domain: .arome_france_15min, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let arpege_europe = try await MeteoFranceReader(domain: .arpege_europe, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                return Array([gfsProbabilites, iconProbabilities, gfs, icon, arpege_europe, arome_france, arome_france_hd, arome_france_15min, arome_france_hd_15min].compacted())
            }
            // For Northern Europe and Iceland use DMI Harmonie
            if (44..<66).contains(lat), let dmiEurope = try await DmiReader(domain: DmiDomain.harmonie_arome_europe, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                let probabilities = try await ProbabilityReader.makeEcmwfReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let ecmwf = try await EcmwfReader(domain: .ifs025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                let iconEu = try await IconReader(domain: .iconEu, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                return Array([gfsProbabilites, probabilities, gfs, icon, iconEu, ecmwf, dmiEurope].compacted())
            }
            // For North America, use HRRR
            if let hrrr = try await GfsReader(domains: [.hrrr_conus, .hrrr_conus_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                let nbmProbabilities = try await ProbabilityReader.makeNbmReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                return Array([gfsProbabilites, nbmProbabilities, icon, gfs, hrrr].compacted())
            }
            // For Japan use JMA MSM with ICON. Does not use global JMA model because of poor resolution
            if (22.4 + 5..<47.65 - 5).contains(lat), (120 + 5..<150 - 5).contains(lon), let jma_msm = try await JmaReader(domain: .msm, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                return [gfsProbabilites, iconProbabilities, gfs, icon, jma_msm]
            }

            // Remaining eastern europe
            if let iconEu = try await IconReader(domain: .iconEu, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                return [gfsProbabilites, iconProbabilities, gfs, icon, iconEu]
            }

            // Northern africa
            if let arpege_europe = try await MeteoFranceReader(domain: .arpege_europe, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) {
                let arpegeProbabilities: (any GenericReaderProtocol)? = try await ProbabilityReader.makeMeteoFranceEuropeReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
                return [gfsProbabilites, iconProbabilities, arpegeProbabilities, gfs, icon, arpege_europe].compactMap({ $0 })
            }

            // Remaining parts of the world
            return [gfsProbabilites, iconProbabilities, gfs, icon]
        case .gfs_mix, .gfs_seamless, .ncep_seamless:
            return [
                try await ProbabilityReader.makeGfsReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) as any GenericReaderProtocol,
                try await ProbabilityReader.makeNbmReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) as (any GenericReaderProtocol)?,
                try await GfsReader(domains: [.gfs025, .gfs013, .hrrr_conus, .hrrr_conus_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            ].compactMap({ $0 })
        case .gfs_global, .ncep_gfs_global:
            let gfsProbabilites = try await ProbabilityReader.makeGfsReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [gfsProbabilites] + (try await GfsReader(domains: [.gfs025, .gfs013], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? [])
        case .gfs025, .ncep_gfs025:
            return try await GfsReader(domains: [.gfs025], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .gfs013, .ncep_gfs013:
            return try await GfsReader(domains: [.gfs013], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .gfs_hrrr, .ncep_hrrr_conus:
            return [
                try await ProbabilityReader.makeNbmReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) as (any GenericReaderProtocol)?,
                try await GfsReader(domains: [.hrrr_conus, .hrrr_conus_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            ].compactMap({ $0 })
        case .ncep_hrrr_conus_15min:
            return try await GfsReader(domains: [.hrrr_conus_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .gfs_graphcast025, .ncep_gfs_graphcast025:
            return try await GfsGraphCastReader(domain: .graphcast025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .meteofrance_mix, .meteofrance_seamless:
            let arpegeProbabilities: (any GenericReaderProtocol)? = try await ProbabilityReader.makeMeteoFranceEuropeReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return ([arpegeProbabilities] + (try await MeteoFranceMixer(domains: [.arpege_world, .arpege_europe, .arome_france, .arome_france_hd, .arome_france_15min, .arome_france_hd_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? [])).compactMap({ $0 })
        case .meteofrance_arpege_seamless, .arpege_seamless:
            let arpegeProbabilities: (any GenericReaderProtocol)? = try await ProbabilityReader.makeMeteoFranceEuropeReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return ([arpegeProbabilities] + (try await MeteoFranceMixer(domains: [.arpege_world, .arpege_europe], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? [])).compactMap({ $0 })
        case .meteofrance_arome_seamless, .arome_seamless:
            return try await MeteoFranceMixer(domains: [.arome_france, .arome_france_hd, .arome_france_15min, .arome_france_hd_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? []
        case .meteofrance_arpege_world, .arpege_world, .meteofrance_arpege_world025:
            return try await MeteoFranceReader(domain: .arpege_world, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .meteofrance_arpege_europe, .arpege_europe:
            let arpegeProbabilities: (any GenericReaderProtocol)? = try await ProbabilityReader.makeMeteoFranceEuropeReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return ([arpegeProbabilities] + (try await MeteoFranceReader(domain: .arpege_europe, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? [])).compactMap({ $0 })
        case .meteofrance_arome_france, .arome_france, .meteofrance_arome_france0025:
            // Note: AROME PI 15min is not used for consistency here
            return try await MeteoFranceMixer(domains: [.arome_france], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? []
        case .meteofrance_arome_france_hd, .arome_france_hd:
            // Note: AROME PI 15min is not used for consistency here
            return try await MeteoFranceMixer(domains: [.arome_france_hd], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? []
        case .meteofrance_arome_france_15min:
            return try await MeteoFranceMixer(domains: [.arome_france_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? []
        case .meteofrance_arome_france_hd_15min:
            return try await MeteoFranceMixer(domains: [.arome_france_hd_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? []
        case .jma_mix, .jma_seamless:
            return try await JmaMixer(domains: [.gsm, .msm], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? []
        case .jma_msm:
            return try await JmaReader(domain: .msm, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .jms_gsm, .jma_gsm:
            return try await JmaReader(domain: .gsm, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .icon_seamless, .icon_mix, .dwd_icon_seamless:
            let iconProbabilities = try await ProbabilityReader.makeIconReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [iconProbabilities] + (try await IconMixer(domains: [.icon, .iconEu, .iconD2, .iconD2_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? [])
        case .icon_global, .dwd_icon_global, .dwd_icon:
            let iconProbabilities = try await ProbabilityReader.makeIconGlobalReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [iconProbabilities] + (try await IconReader(domain: .icon, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? [])
        case .icon_eu, .dwd_icon_eu:
            let iconProbabilities = try await ProbabilityReader.makeIconEuReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return (iconProbabilities.flatMap({ [$0] }) ?? []) + (try await IconReader(domain: .iconEu, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? [])
        case .icon_d2, .dwd_icon_d2:
            let iconProbabilities = try await ProbabilityReader.makeIconD2Reader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return (iconProbabilities.flatMap({ [$0] }) ?? []) + (try await IconMixer(domains: [.iconD2, .iconD2_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? [])
        case .dwd_icon_d2_15min:
            return (try await IconMixer(domains: [.iconD2_15min], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? [])
        case .ecmwf_ifs04:
            return try await EcmwfReader(domain: .ifs04, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .ecmwf_ifs025:
            let probabilities = try await ProbabilityReader.makeEcmwfReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities] + (try await EcmwfReader(domain: .ifs025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? [])
        case .ecmwf_aifs025:
            return try await EcmwfReader(domain: .aifs025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .ecmwf_aifs025_single:
            return try await EcmwfReader(domain: .aifs025_single, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .metno_nordic:
            return try await MetNoReader(domain: .nordic_pp, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .gem_seamless:
            let probabilities = try await ProbabilityReader.makeGemReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities] + (try await GemMixer(domains: [.gem_global, .gem_regional, .gem_hrdps_continental], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)?.reader ?? [])
        case .gem_global, .cmc_gem_gdps:
            let probabilities = try await ProbabilityReader.makeGemReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities] + (try await GemReader(domain: .gem_global, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? [])
        case .gem_regional, .cmc_gem_rdps:
            return try await GemReader(domain: .gem_regional, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .gem_hrdps_continental, .cmc_gem_hrdps:
            return try await GemReader(domain: .gem_hrdps_continental, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .archive_best_match:
            return [try await Era5Factory.makeArchiveBestMatch(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .era5_seamless, .copernicus_era5_seamless:
            return [try await Era5Factory.makeEra5CombinedLand(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .era5, .copernicus_era5:
            // If explicitly selected ERA5, combine with ensemble to read spread variables
            return [try await Era5Factory.makeEra5WithEnsemble(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .era5_land, .copernicus_era5_land:
            return [try await Era5Factory.makeReader(domain: .era5_land, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .cerra, .copernicus_cerra:
            return try await CerraReader(domain: .cerra, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .ecmwf_ifs:
            return [try await Era5Factory.makeReader(domain: .ecmwf_ifs, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .cma_grapes_global:
            return try await CmaReader(domain: .grapes_global, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .bom_access_global:
            let probabilities = try await ProbabilityReader.makeBomReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities] + (try await BomReader(domain: .access_global, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? [])
        case .arpae_cosmo_seamless, .arpae_cosmo_2i, .arpae_cosmo_2i_ruc, .arpae_cosmo_5m:
            throw ForecastapiError.generic(message: "ARPAE COSMO models are not available anymore")
        case .knmi_harmonie_arome_europe:
            return try await KnmiReader(domain: KnmiDomain.harmonie_arome_europe, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .knmi_harmonie_arome_netherlands:
            return try await KnmiReader(domain: KnmiDomain.harmonie_arome_netherlands, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .dmi_harmonie_arome_europe:
            return try await DmiReader(domain: DmiDomain.harmonie_arome_europe, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .knmi_seamless:
            let probabilities = try await ProbabilityReader.makeEcmwfReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let knmiNetherlands: (any GenericReaderProtocol)? = try await KnmiReader(domain: KnmiDomain.harmonie_arome_netherlands, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let knmiEurope = try await KnmiReader(domain: KnmiDomain.harmonie_arome_europe, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let ecmwf = try await EcmwfReader(domain: .ifs025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities, ecmwf, knmiEurope, knmiNetherlands].compactMap({ $0 })
        case .dmi_seamless:
            let probabilities = try await ProbabilityReader.makeEcmwfReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let dmiEurope: (any GenericReaderProtocol)? = try await DmiReader(domain: DmiDomain.harmonie_arome_europe, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let ecmwf = try await EcmwfReader(domain: .ifs025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities, ecmwf, dmiEurope].compactMap({ $0 })
        case .metno_seamless:
            let probabilities = try await ProbabilityReader.makeEcmwfReader(lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let metno: (any GenericReaderProtocol)? = try await MetNoReader(domain: .nordic_pp, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let ecmwf = try await EcmwfReader(domain: .ifs025, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities, ecmwf, metno].compactMap({ $0 })
        case .ecmwf_ifs_analysis_long_window:
            return [try await Era5Factory.makeReader(domain: .ecmwf_ifs_analysis_long_window, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .ecmwf_ifs_analysis:
            return [try await Era5Factory.makeReader(domain: .ecmwf_ifs_analysis, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .ecmwf_ifs_long_window:
            return [try await Era5Factory.makeReader(domain: .ecmwf_ifs_long_window, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .era5_ensemble, .copernicus_era5_ensemble:
            return [try await Era5Factory.makeReader(domain: .era5_ensemble, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)]
        case .ukmo_seamless:
            let ukmoGlobal: (any GenericReaderProtocol)? = try await UkmoReader(domain: UkmoDomain.global_deterministic_10km, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let ukmoUk = try await UkmoReader(domain: UkmoDomain.uk_deterministic_2km, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [ukmoGlobal, ukmoUk].compactMap({ $0 })
        case .ukmo_global_deterministic_10km:
            let ukmoGlobal: (any GenericReaderProtocol)? = try await UkmoReader(domain: UkmoDomain.global_deterministic_10km, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [ukmoGlobal].compactMap({ $0 })
        case .ukmo_uk_deterministic_2km:
            let ukmoUk = try await UkmoReader(domain: UkmoDomain.uk_deterministic_2km, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [ukmoUk].compactMap({ $0 })
        case .ncep_nbm_conus:
            return try await NbmReader(domains: [.nbm_conus], lat: lat, lon: lon, elevation: elevation, mode: mode, options: options).flatMap({ [$0] }) ?? []
        case .eumetsat_sarah3:
            let sarah3 = try await EumetsatSarahReader(domain: EumetsatSarahDomain.sarah3_30min, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [sarah3].compactMap({ $0 })
        case .jma_jaxa_himawari:
            let sat = try await JaxaHimawariReader(domain: JaxaHimawariDomain.himawari_10min, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [sat].compactMap({ $0 })
        case .eumetsat_lsa_saf_msg:
            let sat = try await EumetsatLsaSafReader(domain: .msg, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [sat].compactMap({ $0 })
        case .eumetsat_lsa_saf_iodc:
            let sat = try await EumetsatLsaSafReader(domain: .iodc, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [sat].compactMap({ $0 })
        case .satellite_radiation_seamless:
            if (-60..<50).contains(lon) { // MSG on 0°
                return [try await EumetsatLsaSafReader(domain: .msg, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)].compactMap({ $0 })
            }
            if (50..<90).contains(lon) { // IODC on 41.5°
                return [try await EumetsatLsaSafReader(domain: .iodc, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)].compactMap({ $0 })
            }
            if (90...).contains(lon) { // Himawari on 140°
                return [try await JaxaHimawariReader(domain: JaxaHimawariDomain.himawari_10min, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)].compactMap({ $0 })
            }
            // TODO GOES east + west
            return []
        case .kma_seamless:
            let ldps = try await KmaReader(domain: .ldps, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let gdps = try await KmaReader(domain: .gdps, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [gdps, ldps].compactMap({ $0 })
        case .kma_gdps:
            let reader = try await KmaReader(domain: .gdps, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [reader].compactMap({ $0 })
        case .kma_ldps:
            let reader = try await KmaReader(domain: .ldps, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [reader].compactMap({ $0 })
        case .italia_meteo_arpae_icon_2i:
            let reader = try await ItaliaMeteoArpaeReader(domain: .icon_2i, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [reader].compactMap({ $0 })
        case .meteoswiss_icon_ch1:
            let probabilities: (any GenericReaderProtocol) = try await ProbabilityReader.makeMeteoSwissReader(domain: .icon_ch1_ensemble, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let reader: (any GenericReaderProtocol)? = try await MeteoSwissReader(domain: .icon_ch1, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities, reader].compactMap({ $0 })
        case .meteoswiss_icon_ch2:
            let probabilities: (any GenericReaderProtocol) = try await ProbabilityReader.makeMeteoSwissReader(domain: .icon_ch2_ensemble, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let reader: (any GenericReaderProtocol)? = try await MeteoSwissReader(domain: .icon_ch2, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilities, reader].compactMap({ $0 })
        case .meteoswiss_icon_seamless:
            let probabilitiesCh1: (any GenericReaderProtocol) = try await ProbabilityReader.makeMeteoSwissReader(domain: .icon_ch1_ensemble, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let probabilitiesCh2: (any GenericReaderProtocol) = try await ProbabilityReader.makeMeteoSwissReader(domain: .icon_ch2_ensemble, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let ch1: (any GenericReaderProtocol)? = try await MeteoSwissReader(domain: .icon_ch1, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            let ch2: (any GenericReaderProtocol)? = try await MeteoSwissReader(domain: .icon_ch2, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
            return [probabilitiesCh2, probabilitiesCh1, ch2, ch1].compactMap({ $0 })
        }
    }

    var genericDomain: (any GenericDomain)? {
        switch self {
        case .gfs025, .ncep_gfs025:
            return GfsDomain.gfs025
        case .gfs013, .ncep_gfs013:
            return GfsDomain.gfs013
        case .gfs_hrrr, .ncep_hrrr_conus:
            return GfsDomain.hrrr_conus
        case .ncep_hrrr_conus_15min:
            return GfsDomain.hrrr_conus_15min
        case .gfs_graphcast025, .ncep_gfs_graphcast025:
            return GfsGraphCastDomain.graphcast025
        case .meteofrance_arpege_world, .arpege_world, .meteofrance_arpege_world025:
            return MeteoFranceDomain.arpege_world
        case .meteofrance_arpege_europe, .arpege_europe:
            return MeteoFranceDomain.arpege_europe
        case .meteofrance_arome_france, .arome_france, .meteofrance_arome_france0025:
            return MeteoFranceDomain.arome_france
        case .meteofrance_arome_france_hd, .arome_france_hd:
            return MeteoFranceDomain.arome_france_hd
        case .icon_global, .dwd_icon_global, .dwd_icon:
            return IconDomains.icon
        case .icon_eu, .dwd_icon_eu:
            return IconDomains.iconEu
        case .icon_d2, .dwd_icon_d2:
            return IconDomains.iconD2
        case .dwd_icon_d2_15min:
            return IconDomains.iconD2_15min
        case .ecmwf_ifs04:
            return EcmwfDomain.ifs04
        case .ecmwf_ifs025:
            return EcmwfDomain.ifs025
        case .ecmwf_aifs025:
            return EcmwfDomain.aifs025
        case .metno_nordic:
            return MetNoDomain.nordic_pp
        case .gem_global, .cmc_gem_gdps:
            return GemDomain.gem_global
        case .gem_regional, .cmc_gem_rdps:
            return GemDomain.gem_regional
        case .gem_hrdps_continental, .cmc_gem_hrdps:
            return GemDomain.gem_hrdps_continental
        case .era5, .copernicus_era5:
            return CdsDomain.era5
        case .era5_land, .copernicus_era5_land:
            return CdsDomain.era5_land
        case .cerra, .copernicus_cerra:
            return CdsDomain.cerra
        case .ecmwf_ifs:
            return CdsDomain.ecmwf_ifs
        case .cma_grapes_global:
            return CmaDomain.grapes_global
        case .bom_access_global:
            return BomDomain.access_global
        case .best_match:
            return nil
        case .gfs_seamless, .gfs_mix, .ncep_seamless:
            return nil
        case .gfs_global, .ncep_gfs_global:
            return nil
        case .ncep_nbm_conus:
            return NbmDomain.nbm_conus
        case .meteofrance_seamless:
            return nil
        case .meteofrance_mix:
            return nil
        case .meteofrance_arpege_seamless:
            return nil
        case .meteofrance_arome_seamless:
            return nil
        case .meteofrance_arome_france_hd_15min:
            return MeteoFranceDomain.arome_france_hd_15min
        case .meteofrance_arome_france_15min:
            return MeteoFranceDomain.arome_france_15min
        case .arpege_seamless:
            return nil
        case .arome_seamless:
            return nil
        case .jma_seamless:
            return nil
        case .jma_mix:
            return nil
        case .jma_msm:
            return JmaDomain.msm
        case .jms_gsm, .jma_gsm:
            return JmaDomain.gsm
        case .gem_seamless:
            return nil
        case .icon_seamless, .icon_mix, .dwd_icon_seamless:
            return nil
        case .ecmwf_aifs025_single:
            return EcmwfDomain.aifs025_single
        case .archive_best_match:
            return nil
        case .era5_seamless, .copernicus_era5_seamless:
            return CdsDomain.era5_land
        case .era5_ensemble, .copernicus_era5_ensemble:
            return CdsDomain.era5_ensemble
        case .ecmwf_ifs_analysis:
            return CdsDomain.ecmwf_ifs_analysis
        case .ecmwf_ifs_analysis_long_window:
            return CdsDomain.ecmwf_ifs_analysis_long_window
        case .ecmwf_ifs_long_window:
            return CdsDomain.ecmwf_ifs_long_window
        case .arpae_cosmo_seamless:
            return nil
        case .arpae_cosmo_2i:
            return nil
        case .arpae_cosmo_2i_ruc:
            return nil
        case .arpae_cosmo_5m:
            return nil
        case .knmi_harmonie_arome_europe:
            return KnmiDomain.harmonie_arome_europe
        case .knmi_harmonie_arome_netherlands:
            return KnmiDomain.harmonie_arome_netherlands
        case .dmi_harmonie_arome_europe:
            return DmiDomain.harmonie_arome_europe
        case .knmi_seamless:
            return nil
        case .dmi_seamless:
            return nil
        case .metno_seamless:
            return nil
        case .ukmo_seamless:
            return nil
        case .ukmo_global_deterministic_10km:
            return UkmoDomain.global_deterministic_10km
        case .ukmo_uk_deterministic_2km:
            return UkmoDomain.uk_deterministic_2km
        case .satellite_radiation_seamless:
            return nil
        case .eumetsat_sarah3:
            return EumetsatSarahDomain.sarah3_30min
        case .eumetsat_lsa_saf_msg:
            return EumetsatLsaSafDomain.msg
        case .eumetsat_lsa_saf_iodc:
            return EumetsatLsaSafDomain.iodc
        case .jma_jaxa_himawari:
            return JaxaHimawariDomain.himawari_10min
        case .kma_seamless:
            return nil
        case .kma_gdps:
            return KmaDomain.gdps
        case .kma_ldps:
            return KmaDomain.ldps
        case .italia_meteo_arpae_icon_2i:
            return ItaliaMeteoArpaeDomain.icon_2i
        case .meteoswiss_icon_ch1:
            return MeteoSwissDomain.icon_ch1
        case .meteoswiss_icon_ch2:
            return MeteoSwissDomain.icon_ch2
        case .meteoswiss_icon_seamless:
            return nil
        }
    }

    func getReader(gridpoint: Int, options: GenericReaderOptions) async throws -> (any GenericReaderProtocol)? {
        switch self {
        case .gfs025, .ncep_gfs025:
            return try await GfsReader(domain: .gfs025, gridpoint: gridpoint, options: options)
        case .gfs013, .ncep_gfs013:
            return try await GfsReader(domain: .gfs013, gridpoint: gridpoint, options: options)
        case .gfs_hrrr, .ncep_hrrr_conus:
            return try await GfsReader(domain: .hrrr_conus, gridpoint: gridpoint, options: options)
        case .ncep_hrrr_conus_15min:
            return try await GfsReader(domain: .hrrr_conus_15min, gridpoint: gridpoint, options: options)
        case .gfs_graphcast025, .ncep_gfs_graphcast025:
            return try await GfsGraphCastReader(domain: .graphcast025, gridpoint: gridpoint, options: options)
        case .meteofrance_arpege_world, .arpege_world, .meteofrance_arpege_world025:
            return try await MeteoFranceReader(domain: .arpege_world, gridpoint: gridpoint, options: options)
        case .meteofrance_arpege_europe, .arpege_europe, .meteofrance_arome_france0025:
            return try await MeteoFranceReader(domain: .arpege_europe, gridpoint: gridpoint, options: options)
        case .meteofrance_arome_france, .arome_france:
            return try await MeteoFranceReader(domain: .arome_france, gridpoint: gridpoint, options: options)
        case .meteofrance_arome_france_hd, .arome_france_hd:
            return try await MeteoFranceReader(domain: .arome_france_hd, gridpoint: gridpoint, options: options)
        case .meteofrance_seamless:
            return nil
        case .meteofrance_mix:
            return nil
        case .meteofrance_arpege_seamless:
            return nil
        case .meteofrance_arome_seamless:
            return nil
        case .meteofrance_arome_france_hd_15min:
            return try await MeteoFranceReader(domain: .arome_france_hd_15min, gridpoint: gridpoint, options: options)
        case .meteofrance_arome_france_15min:
            return try await MeteoFranceReader(domain: .arome_france_15min, gridpoint: gridpoint, options: options)
        case .arpege_seamless:
            return nil
        case .arome_seamless:
            return nil
        case .icon_global, .dwd_icon_global, .dwd_icon:
            return try await IconReader(domain: .icon, gridpoint: gridpoint, options: options)
        case .icon_eu, .dwd_icon_eu:
            return try await IconReader(domain: .iconEu, gridpoint: gridpoint, options: options)
        case .icon_d2, .dwd_icon_d2:
            return try await IconReader(domain: .iconD2, gridpoint: gridpoint, options: options)
        case .dwd_icon_d2_15min:
            return try await IconReader(domain: .iconD2_15min, gridpoint: gridpoint, options: options)
        case .ecmwf_ifs04:
            return try await EcmwfReader(domain: .ifs04, gridpoint: gridpoint, options: options)
        case .ecmwf_ifs025:
            return try await EcmwfReader(domain: .ifs025, gridpoint: gridpoint, options: options)
        case .ecmwf_aifs025:
            return try await EcmwfReader(domain: .aifs025, gridpoint: gridpoint, options: options)
        case .metno_nordic:
            return try await MetNoReader(domain: .nordic_pp, gridpoint: gridpoint, options: options)
        case .gem_global, .cmc_gem_gdps:
            return try await GemReader(domain: .gem_global, gridpoint: gridpoint, options: options)
        case .gem_regional, .cmc_gem_rdps:
            return try await GemReader(domain: .gem_regional, gridpoint: gridpoint, options: options)
        case .gem_hrdps_continental, .cmc_gem_hrdps:
            return try await GemReader(domain: .gem_hrdps_continental, gridpoint: gridpoint, options: options)
        case .era5, .copernicus_era5:
            return try await Era5Factory.makeReader(domain: .era5, gridpoint: gridpoint, options: options)
        case .era5_land, .copernicus_era5_land:
            return try await Era5Factory.makeReader(domain: .era5_land, gridpoint: gridpoint, options: options)
        case .cerra, .copernicus_cerra:
            return try await CerraReader(domain: .cerra, gridpoint: gridpoint, options: options)
        case .ecmwf_ifs:
            return try await Era5Factory.makeReader(domain: .ecmwf_ifs, gridpoint: gridpoint, options: options)
        case .cma_grapes_global:
            return try await CmaReader(domain: .grapes_global, gridpoint: gridpoint, options: options)
        case .bom_access_global:
            return try await BomReader(domain: .access_global, gridpoint: gridpoint, options: options)
        case .arpae_cosmo_2i, .arpae_cosmo_2i_ruc, .arpae_cosmo_5m, .arpae_cosmo_seamless:
            throw ForecastapiError.generic(message: "ARPAE COSMO models are not available anymore")
        case .best_match:
            return nil
        case .gfs_seamless, .ncep_seamless, .gfs_mix:
            return nil
        case .gfs_global, .ncep_gfs_global:
            return nil
        case .ncep_nbm_conus:
            return try await NbmReader(domain: .nbm_conus, gridpoint: gridpoint, options: options)
        case .jma_seamless, .jma_mix:
            return nil
        case .jma_msm:
            return try await JmaReader(domain: .msm, gridpoint: gridpoint, options: options)
        case .jms_gsm, .jma_gsm:
            return try await JmaReader(domain: .gsm, gridpoint: gridpoint, options: options)
        case .gem_seamless:
            return nil
        case .icon_seamless, .icon_mix, .dwd_icon_seamless:
            return nil
        case .ecmwf_aifs025_single:
            return try await EcmwfReader(domain: .aifs025_single, gridpoint: gridpoint, options: options)
        case .archive_best_match:
            return nil
        case .era5_seamless, .copernicus_era5_seamless:
            let era5land = try await GenericReader<CdsDomain, Era5Variable>(domain: .era5_land, position: gridpoint, options: options)
            guard
                let era5 = try await GenericReader<CdsDomain, Era5Variable>(domain: .era5, lat: era5land.modelLat, lon: era5land.modelLon, elevation: era5land.targetElevation, mode: .nearest, options: options)
            else {
                // Not possible
                throw ForecastapiError.noDataAvilableForThisLocation
            }
            return Era5Reader<GenericReaderMixerSameDomain<GenericReaderCached<CdsDomain, Era5Variable>>>(reader: GenericReaderMixerSameDomain(reader: [GenericReaderCached(reader: era5), GenericReaderCached(reader: era5land)]), options: options)
        case .era5_ensemble, .copernicus_era5_ensemble:
            return try await Era5Factory.makeReader(domain: .era5_ensemble, gridpoint: gridpoint, options: options)
        case .ecmwf_ifs_analysis:
            return try await Era5Factory.makeReader(domain: .ecmwf_ifs_analysis, gridpoint: gridpoint, options: options)
        case .ecmwf_ifs_analysis_long_window:
            return try await Era5Factory.makeReader(domain: .ecmwf_ifs_analysis_long_window, gridpoint: gridpoint, options: options)
        case .ecmwf_ifs_long_window:
            return try await Era5Factory.makeReader(domain: .ecmwf_ifs_long_window, gridpoint: gridpoint, options: options)
        case .knmi_harmonie_arome_europe:
            return try await KnmiReader(domain: .harmonie_arome_europe, gridpoint: gridpoint, options: options)
        case .knmi_harmonie_arome_netherlands:
            return try await KnmiReader(domain: .harmonie_arome_netherlands, gridpoint: gridpoint, options: options)
        case .dmi_harmonie_arome_europe:
            return try await DmiReader(domain: .harmonie_arome_europe, gridpoint: gridpoint, options: options)
        case .knmi_seamless:
            return nil
        case .dmi_seamless:
            return nil
        case .metno_seamless:
            return nil
        case .ukmo_seamless:
            return nil
        case .ukmo_global_deterministic_10km:
            return try await UkmoReader(domain: .global_deterministic_10km, gridpoint: gridpoint, options: options)
        case .ukmo_uk_deterministic_2km:
            return try await UkmoReader(domain: .uk_deterministic_2km, gridpoint: gridpoint, options: options)
        case .satellite_radiation_seamless:
            return nil
        case .eumetsat_sarah3:
            return try await EumetsatSarahReader(domain: .sarah3_30min, gridpoint: gridpoint, options: options)
        case .eumetsat_lsa_saf_msg:
            return try await EumetsatLsaSafReader(domain: .msg, gridpoint: gridpoint, options: options)
        case .eumetsat_lsa_saf_iodc:
            return try await EumetsatLsaSafReader(domain: .iodc, gridpoint: gridpoint, options: options)
        case .jma_jaxa_himawari:
            return try await JaxaHimawariReader(domain: .himawari_10min, gridpoint: gridpoint, options: options)
        case .kma_seamless:
            return nil
        case .kma_gdps:
            return try await KmaReader(domain: .gdps, gridpoint: gridpoint, options: options)
        case .kma_ldps:
            return try await KmaReader(domain: .ldps, gridpoint: gridpoint, options: options)
        case .italia_meteo_arpae_icon_2i:
            return try await ItaliaMeteoArpaeReader(domain: .icon_2i, gridpoint: gridpoint, options: options)
        case .meteoswiss_icon_ch1:
            return try await MeteoSwissReader(domain: .icon_ch1, gridpoint: gridpoint, options: options)
        case .meteoswiss_icon_ch2:
            return try await MeteoSwissReader(domain: .icon_ch2, gridpoint: gridpoint, options: options)
        case .meteoswiss_icon_seamless:
            return nil
        }
    }

    var countEnsembleMember: Int {
        return 1
    }
}

enum ModelError: AbortError {
    var status: NIOHTTP1.HTTPResponseStatus {
        return .badRequest
    }

    case domainInitFailed(domain: String)
}

/// Define all available surface weather variables
enum ForecastSurfaceVariable: String, GenericVariableMixable {
    /// Maps to `temperature_2m`. Used for compatibility with `current_weather` block
    case temperature
    /// Maps to `windspeed_10m`. Used for compatibility with `current_weather` block
    case windspeed
    /// Maps to `winddirection_10m`. Used for compatibility with `current_weather` block
    case winddirection

    case wet_bulb_temperature_2m
    case apparent_temperature
    case cape
    case cloudcover
    case cloudcover_high
    case cloudcover_low
    case cloudcover_mid
    case cloud_cover
    case cloud_cover_high
    case cloud_cover_low
    case cloud_cover_mid
    case cloud_cover_2m
    case cloud_base
    case cloud_top
    case convective_cloud_base
    case convective_cloud_top
    case dewpoint_2m
    case dew_point_2m
    case diffuse_radiation
    case diffuse_radiation_instant
    case direct_normal_irradiance
    case direct_normal_irradiance_instant
    case direct_radiation
    case direct_radiation_instant
    case et0_fao_evapotranspiration
    case evapotranspiration
    case freezinglevel_height
    case freezing_level_height
    case growing_degree_days_base_0_limit_50
    case is_day
    case latent_heatflux
    case latent_heat_flux
    case lifted_index
    case convective_inhibition
    case leaf_wetness_probability
    case lightning_potential
    case mass_density_8m
    case precipitation
    case precipitation_probability
    case precipitation_type
    case pressure_msl
    case rain
    case relativehumidity_2m
    case relative_humidity_2m
    case runoff
    case sensible_heatflux
    case sensible_heat_flux
    case shortwave_radiation
    case shortwave_radiation_instant
    case showers
    case skin_temperature
    case snow_depth
    case snow_depth_water_equivalent
    case snow_height
    case hail
    case snowfall
    case snowfall_water_equivalent
    case sunshine_duration
    case soil_moisture_0_1cm
    case soil_moisture_0_to_1cm
    case soil_moisture_0_to_100cm
    case soil_moisture_0_to_10cm
    case soil_moisture_0_to_7cm
    case soil_moisture_100_to_200cm
    case soil_moisture_100_to_255cm
    case soil_moisture_10_to_40cm
    case soil_moisture_1_3cm
    case soil_moisture_1_to_3cm
    case soil_moisture_27_81cm
    case soil_moisture_27_to_81cm
    case soil_moisture_28_to_100cm
    case soil_moisture_3_9cm
    case soil_moisture_3_to_9cm
    case soil_moisture_40_to_100cm
    case soil_moisture_7_to_28cm
    case soil_moisture_9_27cm
    case soil_moisture_9_to_27cm
    case soil_moisture_81_to_243cm
    case soil_moisture_243_to_729cm
    case soil_moisture_729_to_2187cm
    case soil_moisture_index_0_to_100cm
    case soil_moisture_index_0_to_7cm
    case soil_moisture_index_100_to_255cm
    case soil_moisture_index_28_to_100cm
    case soil_moisture_index_7_to_28cm
    case soil_temperature_0_to_100cm
    case soil_temperature_0_to_10cm
    case soil_temperature_0_to_7cm
    case soil_temperature_0cm
    case soil_temperature_100_to_200cm
    case soil_temperature_100_to_255cm
    case soil_temperature_10_to_40cm
    case soil_temperature_18cm
    case soil_temperature_28_to_100cm
    case soil_temperature_40_to_100cm
    case soil_temperature_54cm
    case soil_temperature_6cm
    case soil_temperature_7_to_28cm
    case soil_temperature_162cm
    case soil_temperature_486cm
    case soil_temperature_1458cm
    case surface_air_pressure
    case snowfall_height
    case surface_pressure
    case surface_temperature
    case temperature_100m
    case temperature_120m
    case temperature_150m
    case temperature_180m
    case temperature_2m
    case temperature_20m
    case temperature_200m
    case temperature_50m
    case temperature_40m
    case temperature_80m
    case temperature_2m_max
    case temperature_2m_min
    case terrestrial_radiation
    case terrestrial_radiation_instant
    case total_column_integrated_water_vapour
    case updraft
    case uv_index
    case uv_index_clear_sky
    case vapor_pressure_deficit
    case vapour_pressure_deficit
    case visibility
    case weathercode
    case weather_code
    case winddirection_100m
    case winddirection_10m
    case winddirection_120m
    case winddirection_150m
    case winddirection_180m
    case winddirection_200m
    case winddirection_20m
    case winddirection_40m
    case winddirection_50m
    case winddirection_80m
    case windgusts_10m
    case windspeed_100m
    case windspeed_10m
    case windspeed_120m
    case windspeed_150m
    case windspeed_180m
    case windspeed_200m
    case windspeed_20m
    case windspeed_40m
    case windspeed_50m
    case windspeed_80m
    case wind_direction_250m
    case wind_direction_300m
    case wind_direction_350m
    case wind_direction_450m
    case wind_direction_100m
    case wind_direction_10m
    case wind_direction_120m
    case wind_direction_140m
    case wind_direction_150m
    case wind_direction_160m
    case wind_direction_180m
    case wind_direction_200m
    case wind_direction_20m
    case wind_direction_40m
    case wind_direction_30m
    case wind_direction_50m
    case wind_direction_80m
    case wind_direction_70m
    case wind_gusts_10m
    case wind_speed_250m
    case wind_speed_300m
    case wind_speed_350m
    case wind_speed_450m
    case wind_speed_100m
    case wind_speed_10m
    case wind_speed_120m
    case wind_speed_140m
    case wind_speed_150m
    case wind_speed_160m
    case wind_speed_180m
    case wind_speed_200m
    case wind_speed_20m
    case wind_speed_40m
    case wind_speed_30m
    case wind_speed_50m
    case wind_speed_70m
    case wind_speed_80m
    case soil_temperature_10_to_35cm
    case soil_temperature_35_to_100cm
    case soil_temperature_100_to_300cm
    case soil_moisture_10_to_35cm
    case soil_moisture_35_to_100cm
    case soil_moisture_100_to_300cm
    case shortwave_radiation_clear_sky
    case global_tilted_irradiance
    case global_tilted_irradiance_instant
    case boundary_layer_height
    case thunderstorm_probability
    case rain_probability
    case freezing_rain_probability
    case ice_pellets_probability
    case snowfall_probability
    case albedo

    case wind_speed_10m_spread
    case wind_speed_100m_spread
    case wind_direction_10m_spread
    case wind_direction_100m_spread
    case snowfall_spread
    case temperature_2m_spread
    case wind_gusts_10m_spread
    case dew_point_2m_spread
    case cloud_cover_low_spread
    case cloud_cover_mid_spread
    case cloud_cover_high_spread
    case pressure_msl_spread
    case snowfall_water_equivalent_spread
    case snow_depth_spread
    case soil_temperature_0_to_7cm_spread
    case soil_temperature_7_to_28cm_spread
    case soil_temperature_28_to_100cm_spread
    case soil_temperature_100_to_255cm_spread
    case soil_moisture_0_to_7cm_spread
    case soil_moisture_7_to_28cm_spread
    case soil_moisture_28_to_100cm_spread
    case soil_moisture_100_to_255cm_spread
    case shortwave_radiation_spread
    case precipitation_spread
    case direct_radiation_spread
    case boundary_layer_height_spread
    case sea_surface_temperature

    /// Some variables are kept for backwards compatibility
    var remapped: Self {
        switch self {
        case .temperature:
            return .temperature_2m
        case .windspeed:
            return .wind_speed_10m
        case .winddirection:
            return .wind_direction_10m
        case .surface_air_pressure:
            return .surface_pressure
        default:
            return self
        }
    }

    /// Soil moisture or snow depth are cumulative processes and have offests if mutliple models are mixed
    var requiresOffsetCorrectionForMixing: Bool {
        switch self {
        case .soil_moisture_0_1cm: return true
        case .soil_moisture_0_to_100cm: return true
        case .soil_moisture_0_to_10cm: return true
        case .soil_moisture_0_to_7cm: return true
        case .soil_moisture_100_to_200cm: return true
        case .soil_moisture_100_to_255cm: return true
        case .soil_moisture_10_to_40cm: return true
        case .soil_moisture_1_3cm: return true
        case .soil_moisture_27_81cm: return true
        case .soil_moisture_28_to_100cm: return true
        case .soil_moisture_3_9cm: return true
        case .soil_moisture_40_to_100cm: return true
        case .soil_moisture_7_to_28cm: return true
        case .soil_moisture_9_27cm: return true
        case .snow_depth: return true
        default: return false
        }
    }
}

/// Available pressure level variables
enum ForecastPressureVariableType: String, GenericVariableMixable {
    case temperature
    case geopotential_height
    case relativehumidity
    case relative_humidity
    case windspeed
    case wind_speed
    case winddirection
    case wind_direction
    case dewpoint
    case dew_point
    case cloudcover
    case cloud_cover
    case vertical_velocity

    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

struct ForecastPressureVariable: PressureVariableRespresentable, GenericVariableMixable {
    let variable: ForecastPressureVariableType
    let level: Int

    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

/// Available pressure level variables
enum ForecastHeightVariableType: String, GenericVariableMixable {
    case temperature
    case relativehumidity
    case relative_humidity
    case windspeed
    case wind_speed
    case winddirection
    case wind_direction
    case dewpoint
    case dew_point
    case cloudcover
    case cloud_cover
    case vertical_velocity

    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

struct ForecastHeightVariable: HeightVariableRespresentable, GenericVariableMixable {
    let variable: ForecastHeightVariableType
    let level: Int

    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

typealias ForecastVariable = SurfacePressureAndHeightVariable<VariableAndPreviousDay, ForecastPressureVariable, ForecastHeightVariable>

extension ForecastVariable {
    var variableAndPreviousDay: (ForecastVariable, Int) {
        switch self {
        case .surface(let surface):
            return (ForecastVariable.surface(.init(surface.variable.remapped, 0)), surface.previousDay)
        case .pressure(let pressure):
            return (ForecastVariable.pressure(pressure), 0)
        case .height(let height):
            return (ForecastVariable.height(height), 0)
        }
    }
}

/// Available daily aggregations
enum ForecastVariableDaily: String, DailyVariableCalculatable, RawRepresentableString {
    case apparent_temperature_max
    case apparent_temperature_mean
    case apparent_temperature_min
    case cape_max
    case cape_mean
    case cape_min
    case cloudcover_max
    case cloudcover_mean
    case cloudcover_min
    case cloud_cover_max
    case cloud_cover_mean
    case cloud_cover_min
    case dewpoint_2m_max
    case dewpoint_2m_mean
    case dewpoint_2m_min
    case dew_point_2m_max
    case dew_point_2m_mean
    case dew_point_2m_min
    case et0_fao_evapotranspiration
    case et0_fao_evapotranspiration_sum
    case growing_degree_days_base_0_limit_50
    case leaf_wetness_probability_mean
    case precipitation_hours
    case precipitation_probability_max
    case precipitation_probability_mean
    case precipitation_probability_min
    case precipitation_sum
    case pressure_msl_max
    case pressure_msl_mean
    case pressure_msl_min
    case rain_sum
    case relative_humidity_2m_max
    case relative_humidity_2m_mean
    case relative_humidity_2m_min
    case shortwave_radiation_sum
    case showers_sum
    case snowfall_sum
    case snowfall_water_equivalent_sum
    case snow_depth_min
    case snow_depth_mean
    case snow_depth_max
    case soil_moisture_0_to_100cm_mean
    case soil_moisture_0_to_10cm_mean
    case soil_moisture_0_to_7cm_mean
    case soil_moisture_28_to_100cm_mean
    case soil_moisture_7_to_28cm_mean
    case soil_moisture_index_0_to_100cm_mean
    case soil_moisture_index_0_to_7cm_mean
    case soil_moisture_index_100_to_255cm_mean
    case soil_moisture_index_28_to_100cm_mean
    case soil_moisture_index_7_to_28cm_mean
    case soil_temperature_0_to_100cm_mean
    case soil_temperature_0_to_7cm_mean
    case soil_temperature_28_to_100cm_mean
    case soil_temperature_7_to_28cm_mean
    case sunrise
    case sunset
    case daylight_duration
    case sunshine_duration
    case surface_pressure_max
    case surface_pressure_mean
    case surface_pressure_min
    case temperature_2m_max
    case temperature_2m_mean
    case temperature_2m_min
    case updraft_max
    case uv_index_clear_sky_max
    case uv_index_max
    case vapor_pressure_deficit_max
    case vapour_pressure_deficit_max
    case visibility_max
    case visibility_mean
    case visibility_min
    case weathercode
    case weather_code
    case winddirection_10m_dominant
    case windgusts_10m_max
    case windgusts_10m_mean
    case windgusts_10m_min
    case windspeed_10m_max
    case windspeed_10m_mean
    case windspeed_10m_min
    case wind_direction_10m_dominant
    case wind_gusts_10m_max
    case wind_gusts_10m_mean
    case wind_gusts_10m_min
    case wind_speed_10m_max
    case wind_speed_10m_mean
    case wind_speed_10m_min
    case wet_bulb_temperature_2m_max
    case wet_bulb_temperature_2m_mean
    case wet_bulb_temperature_2m_min

    var aggregation: DailyAggregation<ForecastVariable> {
        switch self {
        case .temperature_2m_max:
            return .max(.surface(.init(.temperature_2m, 0)))
        case .temperature_2m_min:
            return .min(.surface(.init(.temperature_2m, 0)))
        case .temperature_2m_mean:
            return .mean(.surface(.init(.temperature_2m, 0)))
        case .apparent_temperature_max:
            return .max(.surface(.init(.apparent_temperature, 0)))
        case .apparent_temperature_mean:
            return .mean(.surface(.init(.apparent_temperature, 0)))
        case .apparent_temperature_min:
            return .min(.surface(.init(.apparent_temperature, 0)))
        case .precipitation_sum:
            return .sum(.surface(.init(.precipitation, 0)))
        case .snowfall_sum:
            return .sum(.surface(.init(.snowfall, 0)))
        case .rain_sum:
            return .sum(.surface(.init(.rain, 0)))
        case .showers_sum:
            return .sum(.surface(.init(.showers, 0)))
        case .weathercode, .weather_code:
            return .max(.surface(.init(.weathercode, 0)))
        case .shortwave_radiation_sum:
            return .radiationSum(.surface(.init(.shortwave_radiation, 0)))
        case .windspeed_10m_max, .wind_speed_10m_max:
            return .max(.surface(.init(.wind_speed_10m, 0)))
        case .windspeed_10m_min, .wind_speed_10m_min:
            return .min(.surface(.init(.wind_speed_10m, 0)))
        case .windspeed_10m_mean, .wind_speed_10m_mean:
            return .mean(.surface(.init(.wind_speed_10m, 0)))
        case .windgusts_10m_max, .wind_gusts_10m_max:
            return .max(.surface(.init(.wind_gusts_10m, 0)))
        case .windgusts_10m_min, .wind_gusts_10m_min:
            return .min(.surface(.init(.wind_gusts_10m, 0)))
        case .windgusts_10m_mean, .wind_gusts_10m_mean:
            return .mean(.surface(.init(.wind_gusts_10m, 0)))
        case .winddirection_10m_dominant, .wind_direction_10m_dominant:
            return .dominantDirection(velocity: .surface(.init(.wind_speed_10m, 0)), direction: .surface(.init(.wind_direction_10m, 0)))
        case .precipitation_hours:
            return .precipitationHours(.surface(.init(.precipitation, 0)))
        case .sunrise:
            return .none
        case .sunset:
            return .none
        case .et0_fao_evapotranspiration:
            return .sum(.surface(.init(.et0_fao_evapotranspiration, 0)))
        case .visibility_max:
            return .max(.surface(.init(.visibility, 0)))
        case .visibility_min:
            return .min(.surface(.init(.visibility, 0)))
        case .visibility_mean:
            return .mean(.surface(.init(.visibility, 0)))
        case .pressure_msl_max:
            return .max(.surface(.init(.pressure_msl, 0)))
        case .pressure_msl_min:
            return .min(.surface(.init(.pressure_msl, 0)))
        case .pressure_msl_mean:
            return .mean(.surface(.init(.pressure_msl, 0)))
        case .surface_pressure_max:
            return .max(.surface(.init(.surface_pressure, 0)))
        case .surface_pressure_min:
            return .min(.surface(.init(.surface_pressure, 0)))
        case .surface_pressure_mean:
            return .mean(.surface(.init(.surface_pressure, 0)))
        case .cape_max:
            return .max(.surface(.init(.cape, 0)))
        case .cape_min:
            return .min(.surface(.init(.cape, 0)))
        case .cape_mean:
            return .mean(.surface(.init(.cape, 0)))
        case .cloudcover_max, .cloud_cover_max:
            return .max(.surface(.init(.cloudcover, 0)))
        case .cloudcover_min, .cloud_cover_min:
            return .min(.surface(.init(.cloudcover, 0)))
        case .cloudcover_mean, .cloud_cover_mean:
            return .mean(.surface(.init(.cloudcover, 0)))
        case .uv_index_max:
            return .max(.surface(.init(.uv_index, 0)))
        case .uv_index_clear_sky_max:
            return .max(.surface(.init(.uv_index_clear_sky, 0)))
        case .precipitation_probability_max:
            return .max(.surface(.init(.precipitation_probability, 0)))
        case .precipitation_probability_min:
            return .min(.surface(.init(.precipitation_probability, 0)))
        case .precipitation_probability_mean:
            return .mean(.surface(.init(.precipitation_probability, 0)))
        case .dewpoint_2m_max, .dew_point_2m_max:
            return .max(.surface(.init(.dewpoint_2m, 0)))
        case .dewpoint_2m_mean, .dew_point_2m_mean:
            return .mean(.surface(.init(.dewpoint_2m, 0)))
        case .dewpoint_2m_min, .dew_point_2m_min:
            return .min(.surface(.init(.dewpoint_2m, 0)))
        case .et0_fao_evapotranspiration_sum:
            return .sum(.surface(.init(.et0_fao_evapotranspiration, 0)))
        case .growing_degree_days_base_0_limit_50:
            return .sum(.surface(.init(.growing_degree_days_base_0_limit_50, 0)))
        case .leaf_wetness_probability_mean:
            return .mean(.surface(.init(.leaf_wetness_probability, 0)))
        case .relative_humidity_2m_max:
            return .max(.surface(.init(.relativehumidity_2m, 0)))
        case .relative_humidity_2m_mean:
            return .mean(.surface(.init(.relativehumidity_2m, 0)))
        case .relative_humidity_2m_min:
            return .min(.surface(.init(.relativehumidity_2m, 0)))
        case .snowfall_water_equivalent_sum:
            return .sum(.surface(.init(.snowfall_water_equivalent, 0)))
        case .soil_moisture_0_to_100cm_mean:
            return .mean(.surface(.init(.soil_moisture_0_to_100cm, 0)))
        case .soil_moisture_0_to_10cm_mean:
            return .mean(.surface(.init(.soil_moisture_0_to_10cm, 0)))
        case .soil_moisture_0_to_7cm_mean:
            return .mean(.surface(.init(.soil_moisture_0_to_7cm, 0)))
        case .soil_moisture_28_to_100cm_mean:
            return .mean(.surface(.init(.soil_moisture_28_to_100cm, 0)))
        case .soil_moisture_7_to_28cm_mean:
            return .mean(.surface(.init(.soil_moisture_7_to_28cm, 0)))
        case .soil_moisture_index_0_to_100cm_mean:
            return .mean(.surface(.init(.soil_moisture_index_0_to_100cm, 0)))
        case .soil_moisture_index_0_to_7cm_mean:
            return .mean(.surface(.init(.soil_moisture_index_0_to_7cm, 0)))
        case .soil_moisture_index_100_to_255cm_mean:
            return .mean(.surface(.init(.soil_moisture_index_100_to_255cm, 0)))
        case .soil_moisture_index_28_to_100cm_mean:
            return .mean(.surface(.init(.soil_moisture_index_28_to_100cm, 0)))
        case .soil_moisture_index_7_to_28cm_mean:
            return .mean(.surface(.init(.soil_moisture_index_7_to_28cm, 0)))
        case .soil_temperature_0_to_100cm_mean:
            return .mean(.surface(.init(.soil_temperature_0_to_100cm, 0)))
        case .soil_temperature_0_to_7cm_mean:
            return .mean(.surface(.init(.soil_temperature_0_to_7cm, 0)))
        case .soil_temperature_28_to_100cm_mean:
            return .mean(.surface(.init(.soil_temperature_28_to_100cm, 0)))
        case .soil_temperature_7_to_28cm_mean:
            return .mean(.surface(.init(.soil_temperature_7_to_28cm, 0)))
        case .updraft_max:
            return .max(.surface(.init(.updraft, 0)))
        case .vapor_pressure_deficit_max, .vapour_pressure_deficit_max:
            return .max(.surface(.init(.vapor_pressure_deficit, 0)))
        case .wet_bulb_temperature_2m_max:
            return .max(.surface(.init(.wet_bulb_temperature_2m, 0)))
        case .wet_bulb_temperature_2m_min:
            return .min(.surface(.init(.wet_bulb_temperature_2m, 0)))
        case .wet_bulb_temperature_2m_mean:
            return .mean(.surface(.init(.wet_bulb_temperature_2m, 0)))
        case .daylight_duration:
            return .none
        case .sunshine_duration:
            return .sum(.surface(.init(.sunshine_duration, 0)))
        case .snow_depth_min:
            return .min(.surface(.init(.snow_depth, 0)))
        case .snow_depth_mean:
            return .mean(.surface(.init(.snow_depth, 0)))
        case .snow_depth_max:
            return .max(.surface(.init(.snow_depth, 0)))
        }
    }
}
