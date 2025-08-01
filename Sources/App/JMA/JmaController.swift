import Foundation
import Vapor

enum JmaVariableDerivedSurface: String, CaseIterable, GenericVariableMixable {
    case apparent_temperature
    case relativehumidity_2m
    case dewpoint_2m
    case dew_point_2m
    case windspeed_10m
    case wind_speed_10m
    case winddirection_10m
    case wind_direction_10m
    case direct_normal_irradiance
    case direct_normal_irradiance_instant
    case direct_radiation
    case direct_radiation_instant
    case diffuse_radiation_instant
    case diffuse_radiation
    case shortwave_radiation_instant
    case global_tilted_irradiance
    case global_tilted_irradiance_instant
    case et0_fao_evapotranspiration
    case vapour_pressure_deficit
    case vapor_pressure_deficit
    case surface_pressure
    case terrestrial_radiation
    case terrestrial_radiation_instant
    case weathercode
    case weather_code
    case snowfall
    case rain
    case showers
    case is_day
    case wet_bulb_temperature_2m
    case cloudcover
    case cloudcover_low
    case cloudcover_mid
    case cloudcover_high
    case sunshine_duration

    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

/**
 Types of pressure level variables
 */
enum JmaPressureVariableDerivedType: String, CaseIterable {
    case windspeed
    case winddirection
    case dewpoint
    case cloudcover
    case wind_speed
    case wind_direction
    case dew_point
    case cloud_cover
    case relativehumidity
}

/**
 A pressure level variable on a given level in hPa / mb
 */
struct JmaPressureVariableDerived: PressureVariableRespresentable, GenericVariableMixable {
    let variable: JmaPressureVariableDerivedType
    let level: Int

    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

typealias JmaVariableDerived = SurfaceAndPressureVariable<JmaVariableDerivedSurface, JmaPressureVariableDerived>

typealias JmaVariableCombined = VariableOrDerived<JmaVariable, JmaVariableDerived>

struct JmaReader: GenericReaderDerivedSimple, GenericReaderProtocol {
    typealias MixingVar = JmaVariableCombined

    typealias Domain = JmaDomain

    typealias Variable = JmaVariable

    typealias Derived = JmaVariableDerived

    let reader: GenericReaderCached<JmaDomain, JmaVariable>

    let options: GenericReaderOptions

    public init?(domain: Domain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode, options: GenericReaderOptions) async throws {
        guard let reader = try await GenericReader<Domain, Variable>(domain: domain, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) else {
            return nil
        }
        self.reader = GenericReaderCached(reader: reader)
        self.options = options
    }
    
    public init?(domain: Domain, gridpoint: Int, options: GenericReaderOptions) async throws {
        let reader = try await GenericReader<Domain, Variable>(domain: domain, position: gridpoint, options: options)
        self.reader = GenericReaderCached(reader: reader)
        self.options = options
    }

    func get(raw: SurfaceAndPressureVariable<JmaSurfaceVariable, JmaPressureVariable>, time: TimerangeDtAndSettings) async throws -> DataAndUnit {
        switch raw {
        case .pressure(let variable):
            if variable.variable == .geopotential_height {
                let data = try await self.reader.get(variable: raw, time: time)
                return DataAndUnit(data.data.map { $0 * 9.80665 }, data.unit)
            }
        default:
            break
        }

        return try await self.reader.get(variable: raw, time: time)
    }

    func prefetchData(raw: JmaSurfaceVariable, time: TimerangeDtAndSettings) async throws {
        try await prefetchData(raw: .surface(raw), time: time)
    }

    func get(raw: JmaSurfaceVariable, time: TimerangeDtAndSettings) async throws -> DataAndUnit {
        try await get(raw: .surface(raw), time: time)
    }

    func prefetchData(derived: JmaVariableDerived, time: TimerangeDtAndSettings) async throws {
        switch derived {
        case .surface(let surface):
            switch surface {
            case .apparent_temperature:
                try await prefetchData(raw: .temperature_2m, time: time)
                try await prefetchData(raw: .wind_u_component_10m, time: time)
                try await prefetchData(raw: .wind_v_component_10m, time: time)
                try await prefetchData(raw: .relative_humidity_2m, time: time)
                try await prefetchData(raw: .shortwave_radiation, time: time)
            case .relativehumidity_2m:
                try await prefetchData(raw: .relative_humidity_2m, time: time)
            case .wind_speed_10m, .windspeed_10m, .wind_direction_10m, .winddirection_10m:
                try await prefetchData(raw: .wind_u_component_10m, time: time)
                try await prefetchData(raw: .wind_v_component_10m, time: time)
            case .vapour_pressure_deficit, .vapor_pressure_deficit:
                try await prefetchData(raw: .temperature_2m, time: time)
                try await prefetchData(raw: .relative_humidity_2m, time: time)
            case .et0_fao_evapotranspiration:
                try await prefetchData(raw: .shortwave_radiation, time: time)
                try await prefetchData(raw: .temperature_2m, time: time)
                try await prefetchData(raw: .relative_humidity_2m, time: time)
                try await prefetchData(raw: .wind_u_component_10m, time: time)
                try await prefetchData(raw: .wind_v_component_10m, time: time)
            case .surface_pressure:
                try await prefetchData(raw: .pressure_msl, time: time)
                try await prefetchData(raw: .temperature_2m, time: time)
            case .terrestrial_radiation:
                break
            case .terrestrial_radiation_instant:
                break
            case .dew_point_2m, .dewpoint_2m:
                try await prefetchData(raw: .temperature_2m, time: time)
                try await prefetchData(raw: .relative_humidity_2m, time: time)
            case .diffuse_radiation, .diffuse_radiation_instant, .direct_normal_irradiance, .direct_normal_irradiance_instant, .direct_radiation, .direct_radiation_instant, .global_tilted_irradiance, .global_tilted_irradiance_instant, .shortwave_radiation_instant:
                try await prefetchData(raw: .shortwave_radiation, time: time)
            case .weather_code, .weathercode:
                try await prefetchData(raw: .cloud_cover, time: time)
                try await prefetchData(variable: .derived(.surface(.snowfall)), time: time)
                try await prefetchData(raw: .precipitation, time: time)
            case .snowfall:
                try await prefetchData(raw: .temperature_2m, time: time)
                try await prefetchData(raw: .precipitation, time: time)
            case .showers:
                try await prefetchData(raw: .precipitation, time: time)
            case .rain:
                try await prefetchData(raw: .temperature_2m, time: time)
                try await prefetchData(raw: .precipitation, time: time)
            case .is_day:
                break
            case .wet_bulb_temperature_2m:
                try await prefetchData(raw: .temperature_2m, time: time)
                try await prefetchData(raw: .relative_humidity_2m, time: time)
            case .cloudcover:
                try await prefetchData(raw: .cloud_cover, time: time)
            case .cloudcover_low:
                try await prefetchData(raw: .cloud_cover_low, time: time)
            case .cloudcover_mid:
                try await prefetchData(raw: .cloud_cover_mid, time: time)
            case .cloudcover_high:
                try await prefetchData(raw: .cloud_cover_high, time: time)
            case .sunshine_duration:
                try await prefetchData(derived: .surface(.direct_radiation), time: time)
            }
        case .pressure(let v):
            switch v.variable {
            case .wind_speed, .windspeed, .wind_direction, .winddirection:
                try await prefetchData(raw: .pressure(JmaPressureVariable(variable: .wind_u_component, level: v.level)), time: time)
                try await prefetchData(raw: .pressure(JmaPressureVariable(variable: .wind_v_component, level: v.level)), time: time)
            case .dew_point, .dewpoint:
                try await prefetchData(raw: .pressure(JmaPressureVariable(variable: .temperature, level: v.level)), time: time)
                try await prefetchData(raw: .pressure(JmaPressureVariable(variable: .relative_humidity, level: v.level)), time: time)
            case .cloud_cover, .cloudcover, .relativehumidity:
                try await prefetchData(raw: .pressure(JmaPressureVariable(variable: .relative_humidity, level: v.level)), time: time)
            }
        }
    }

    func get(derived: JmaVariableDerived, time: TimerangeDtAndSettings) async throws -> DataAndUnit {
        switch derived {
        case .surface(let variableDerivedSurface):
            switch variableDerivedSurface {
            case .wind_speed_10m, .windspeed_10m:
                let u = try await get(raw: .wind_u_component_10m, time: time).data
                let v = try await get(raw: .wind_v_component_10m, time: time).data
                let speed = zip(u, v).map(Meteorology.windspeed)
                return DataAndUnit(speed, .metrePerSecond)
            case .wind_direction_10m, .winddirection_10m:
                let u = try await get(raw: .wind_u_component_10m, time: time).data
                let v = try await get(raw: .wind_v_component_10m, time: time).data
                let direction = Meteorology.windirectionFast(u: u, v: v)
                return DataAndUnit(direction, .degreeDirection)
            case .apparent_temperature:
                let windspeed = try await get(derived: .surface(.windspeed_10m), time: time).data
                let temperature = try await get(raw: .temperature_2m, time: time).data
                let relhum = try await get(raw: .relative_humidity_2m, time: time).data
                let radiation = try await get(raw: .shortwave_radiation, time: time).data
                return DataAndUnit(Meteorology.apparentTemperature(temperature_2m: temperature, relativehumidity_2m: relhum, windspeed_10m: windspeed, shortwave_radiation: radiation), .celsius)
            case .vapour_pressure_deficit, .vapor_pressure_deficit:
                let temperature = try await get(raw: .temperature_2m, time: time).data
                let rh = try await get(raw: .relative_humidity_2m, time: time).data
                let dewpoint = zip(temperature, rh).map(Meteorology.dewpoint)
                return DataAndUnit(zip(temperature, dewpoint).map(Meteorology.vaporPressureDeficit), .kilopascal)
            case .et0_fao_evapotranspiration:
                let exrad = Zensun.extraTerrestrialRadiationBackwards(latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
                let swrad = try await get(raw: .shortwave_radiation, time: time).data
                let temperature = try await get(raw: .temperature_2m, time: time).data
                let windspeed = try await get(derived: .surface(.windspeed_10m), time: time).data
                let rh = try await get(raw: .relative_humidity_2m, time: time).data
                let dewpoint = zip(temperature, rh).map(Meteorology.dewpoint)

                let et0 = swrad.indices.map { i in
                    return Meteorology.et0Evapotranspiration(temperature2mCelsius: temperature[i], windspeed10mMeterPerSecond: windspeed[i], dewpointCelsius: dewpoint[i], shortwaveRadiationWatts: swrad[i], elevation: reader.targetElevation, extraTerrestrialRadiation: exrad[i], dtSeconds: time.dtSeconds)
                }
                return DataAndUnit(et0, .millimetre)
            case .relativehumidity_2m:
                return try await get(raw: .relative_humidity_2m, time: time)
            case .surface_pressure:
                let temperature = try await get(raw: .temperature_2m, time: time).data
                let pressure = try await get(raw: .pressure_msl, time: time)
                return DataAndUnit(Meteorology.surfacePressure(temperature: temperature, pressure: pressure.data, elevation: reader.targetElevation), pressure.unit)
            case .terrestrial_radiation:
                /// Use center averaged
                let solar = Zensun.extraTerrestrialRadiationBackwards(latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
                return DataAndUnit(solar, .wattPerSquareMetre)
            case .terrestrial_radiation_instant:
                /// Use center averaged
                let solar = Zensun.extraTerrestrialRadiationInstant(latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
                return DataAndUnit(solar, .wattPerSquareMetre)
            case .dew_point_2m, .dewpoint_2m:
                let temperature = try await get(raw: .temperature_2m, time: time)
                let rh = try await get(raw: .relative_humidity_2m, time: time)
                return DataAndUnit(zip(temperature.data, rh.data).map(Meteorology.dewpoint), temperature.unit)
            case .shortwave_radiation_instant:
                let sw = try await get(raw: .shortwave_radiation, time: time)
                let factor = Zensun.backwardsAveragedToInstantFactor(time: time.time, latitude: reader.modelLat, longitude: reader.modelLon)
                return DataAndUnit(zip(sw.data, factor).map(*), sw.unit)
            case .direct_normal_irradiance:
                let dhi = try await get(derived: .surface(.direct_radiation), time: time).data
                let dni = Zensun.calculateBackwardsDNI(directRadiation: dhi, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
                return DataAndUnit(dni, .wattPerSquareMetre)
            case .direct_normal_irradiance_instant:
                let direct = try await get(derived: .surface(.direct_radiation), time: time)
                let dni = Zensun.calculateBackwardsDNI(directRadiation: direct.data, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time, convertToInstant: true)
                return DataAndUnit(dni, direct.unit)
            case .diffuse_radiation:
                let swrad = try await get(raw: .shortwave_radiation, time: time)
                let diffuse = Zensun.calculateDiffuseRadiationBackwards(shortwaveRadiation: swrad.data, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
                return DataAndUnit(diffuse, swrad.unit)
            case .direct_radiation:
                let swrad = try await get(raw: .shortwave_radiation, time: time)
                let diffuse = Zensun.calculateDiffuseRadiationBackwards(shortwaveRadiation: swrad.data, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
                return DataAndUnit(zip(swrad.data, diffuse).map(-), swrad.unit)
            case .direct_radiation_instant:
                let direct = try await get(derived: .surface(.direct_radiation), time: time)
                let factor = Zensun.backwardsAveragedToInstantFactor(time: time.time, latitude: reader.modelLat, longitude: reader.modelLon)
                return DataAndUnit(zip(direct.data, factor).map(*), direct.unit)
            case .diffuse_radiation_instant:
                let diff = try await get(derived: .surface(.diffuse_radiation), time: time)
                let factor = Zensun.backwardsAveragedToInstantFactor(time: time.time, latitude: reader.modelLat, longitude: reader.modelLon)
                return DataAndUnit(zip(diff.data, factor).map(*), diff.unit)
            case .weather_code, .weathercode:
                let cloudcover = try await get(raw: .cloud_cover, time: time).data
                let precipitation = try await get(raw: .precipitation, time: time).data
                let snowfall = try await get(derived: .surface(.snowfall), time: time).data
                return DataAndUnit(WeatherCode.calculate(
                    cloudcover: cloudcover,
                    precipitation: precipitation,
                    convectivePrecipitation: nil,
                    snowfallCentimeters: snowfall,
                    gusts: nil,
                    cape: nil,
                    liftedIndex: nil,
                    visibilityMeters: nil,
                    categoricalFreezingRain: nil,
                    modelDtSeconds: time.dtSeconds), .wmoCode
                )
            case .snowfall:
                let temperature = try await get(raw: .temperature_2m, time: time)
                let precipitation = try await get(raw: .precipitation, time: time)
                return DataAndUnit(zip(temperature.data, precipitation.data).map({ $1 * ($0 >= 0 ? 0 : 0.7) }), .centimetre)
            case .rain:
                let temperature = try await get(raw: .temperature_2m, time: time)
                let precipitation = try await get(raw: .precipitation, time: time)
                return DataAndUnit(zip(temperature.data, precipitation.data).map({ $1 * ($0 >= 0 ? 1 : 0) }), .millimetre)
            case .showers:
                let precipitation = try await get(raw: .precipitation, time: time)
                return DataAndUnit(precipitation.data.map({ min($0, 0) }), precipitation.unit)
            case .is_day:
                return DataAndUnit(Zensun.calculateIsDay(timeRange: time.time, lat: reader.modelLat, lon: reader.modelLon), .dimensionlessInteger)
            case .wet_bulb_temperature_2m:
                let temperature = try await get(raw: .temperature_2m, time: time)
                let rh = try await get(raw: .relative_humidity_2m, time: time)
                return DataAndUnit(zip(temperature.data, rh.data).map(Meteorology.wetBulbTemperature), temperature.unit)
            case .cloudcover:
                return try await get(raw: .cloud_cover, time: time)
            case .cloudcover_low:
                return try await get(raw: .cloud_cover_low, time: time)
            case .cloudcover_mid:
                return try await get(raw: .cloud_cover_mid, time: time)
            case .cloudcover_high:
                return try await get(raw: .cloud_cover_high, time: time)
            case .sunshine_duration:
                let directRadiation = try await get(derived: .surface(.direct_radiation), time: time)
                let duration = Zensun.calculateBackwardsSunshineDuration(directRadiation: directRadiation.data, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
                return DataAndUnit(duration, .seconds)
            case .global_tilted_irradiance:
                let directRadiation = try await get(derived: .surface(.direct_radiation), time: time).data
                let diffuseRadiation = try await get(derived: .surface(.diffuse_radiation), time: time).data
                let gti = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: options.tilt, azimuth: options.azimuth, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time, convertBackwardsToInstant: false)
                return DataAndUnit(gti, .wattPerSquareMetre)
            case .global_tilted_irradiance_instant:
                let directRadiation = try await get(derived: .surface(.direct_radiation), time: time).data
                let diffuseRadiation = try await get(derived: .surface(.diffuse_radiation), time: time).data
                let gti = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: options.tilt, azimuth: options.azimuth, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time, convertBackwardsToInstant: true)
                return DataAndUnit(gti, .wattPerSquareMetre)
            }
        case .pressure(let v):
            switch v.variable {
            case .wind_speed, .windspeed:
                let u = try await get(raw: .pressure(JmaPressureVariable(variable: .wind_u_component, level: v.level)), time: time)
                let v = try await get(raw: .pressure(JmaPressureVariable(variable: .wind_v_component, level: v.level)), time: time)
                let speed = zip(u.data, v.data).map(Meteorology.windspeed)
                return DataAndUnit(speed, u.unit)
            case .wind_direction, .winddirection:
                let u = try await get(raw: .pressure(JmaPressureVariable(variable: .wind_u_component, level: v.level)), time: time).data
                let v = try await get(raw: .pressure(JmaPressureVariable(variable: .wind_v_component, level: v.level)), time: time).data
                let direction = Meteorology.windirectionFast(u: u, v: v)
                return DataAndUnit(direction, .degreeDirection)
            case .dew_point, .dewpoint:
                let temperature = try await get(raw: .pressure(JmaPressureVariable(variable: .temperature, level: v.level)), time: time)
                let rh = try await get(raw: .pressure(JmaPressureVariable(variable: .relative_humidity, level: v.level)), time: time)
                return DataAndUnit(zip(temperature.data, rh.data).map(Meteorology.dewpoint), temperature.unit)
            case .cloud_cover, .cloudcover:
                let rh = try await get(raw: .pressure(JmaPressureVariable(variable: .relative_humidity, level: v.level)), time: time)
                return DataAndUnit(rh.data.map({ Meteorology.relativeHumidityToCloudCover(relativeHumidity: $0, pressureHPa: Float(v.level)) }), .percentage)
            case .relativehumidity:
                return try await get(raw: .pressure(JmaPressureVariable(variable: .relative_humidity, level: v.level)), time: time)
            }
        }
    }
}

struct JmaMixer: GenericReaderMixer {
    let reader: [JmaReader]

    static func makeReader(domain: JmaReader.Domain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode, options: GenericReaderOptions) async throws -> JmaReader? {
        return try await JmaReader(domain: domain, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options)
    }
}
