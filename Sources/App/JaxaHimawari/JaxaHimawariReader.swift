import Foundation

enum JaxaHimawariVariableDerived: String, GenericVariableMixable {
    case terrestrial_radiation
    case terrestrial_radiation_instant
    case direct_normal_irradiance
    case direct_normal_irradiance_instant
    case direct_radiation
    case direct_radiation_instant
    case diffuse_radiation_instant
    case diffuse_radiation
    case shortwave_radiation_instant
    case global_tilted_irradiance
    case global_tilted_irradiance_instant
    case sunshine_duration
    
    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

struct JaxaHimawariReader: GenericReaderDerived, GenericReaderProtocol {
    let reader: GenericReaderCached<JaxaHimawariDomain, Variable>

    let options: GenericReaderOptions

    typealias Domain = JaxaHimawariDomain

    typealias Variable = JaxaHimawariVariable

    typealias Derived = JaxaHimawariVariableDerived

    public init?(domain: Domain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode, options: GenericReaderOptions) async throws {
        guard let reader = try await GenericReader<Domain, Variable>(domain: domain, lat: lat, lon: lon, elevation: elevation, mode: mode, options: options) else {
            return nil
        }
        self.reader = GenericReaderCached(reader: reader)
        self.options = options
    }

    public init(domain: Domain, gridpoint: Int, options: GenericReaderOptions) async throws {
        let reader = try await GenericReader<Domain, Variable>(domain: domain, position: gridpoint, options: options)
        self.reader = GenericReaderCached(reader: reader)
        self.options = options
    }

    func prefetchData(raw: JaxaHimawariVariable, time: TimerangeDtAndSettings) async throws {
        try await reader.prefetchData(variable: raw, time: time)
    }

    func get(raw: JaxaHimawariVariable, time: TimerangeDtAndSettings) async throws -> DataAndUnit {
        return try await reader.get(variable: raw, time: time)
    }

    func get(derived: Derived, time: TimerangeDtAndSettings) async throws -> DataAndUnit {
        switch derived {
        case .terrestrial_radiation:
            let solar = Zensun.extraTerrestrialRadiationBackwards(latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
            return DataAndUnit(solar, .wattPerSquareMetre)
        case .terrestrial_radiation_instant:
            let solar = Zensun.extraTerrestrialRadiationInstant(latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
            return DataAndUnit(solar, .wattPerSquareMetre)
        case .shortwave_radiation_instant:
            let sw = try await get(raw: .shortwave_radiation, time: time)
            let factor = Zensun.backwardsAveragedToInstantFactor(time: time.time, latitude: reader.modelLat, longitude: reader.modelLon)
            return DataAndUnit(zip(sw.data, factor).map(*), sw.unit)
        case .direct_normal_irradiance:
            let dhi = try await get(derived: .direct_radiation, time: time).data
            let dni = Zensun.calculateBackwardsDNI(directRadiation: dhi, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
            return DataAndUnit(dni, .wattPerSquareMetre)
        case .direct_normal_irradiance_instant:
            let direct = try await get(derived: .direct_radiation, time: time)
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
            let direct = try await get(derived: .direct_radiation, time: time)
            let factor = Zensun.backwardsAveragedToInstantFactor(time: time.time, latitude: reader.modelLat, longitude: reader.modelLon)
            return DataAndUnit(zip(direct.data, factor).map(*), direct.unit)
        case .diffuse_radiation_instant:
            let diff = try await get(derived: .diffuse_radiation, time: time)
            let factor = Zensun.backwardsAveragedToInstantFactor(time: time.time, latitude: reader.modelLat, longitude: reader.modelLon)
            return DataAndUnit(zip(diff.data, factor).map(*), diff.unit)
        case .global_tilted_irradiance:
            let directRadiation = try await get(derived: .direct_radiation, time: time).data
            let diffuseRadiation = try await get(derived: .diffuse_radiation, time: time).data
            let gti = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: options.tilt, azimuth: options.azimuth, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time, convertBackwardsToInstant: false)
            return DataAndUnit(gti, .wattPerSquareMetre)
        case .global_tilted_irradiance_instant:
            let directRadiation = try await get(derived: .direct_radiation, time: time).data
            let diffuseRadiation = try await get(derived: .diffuse_radiation, time: time).data
            let gti = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: options.tilt, azimuth: options.azimuth, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time, convertBackwardsToInstant: true)
            return DataAndUnit(gti, .wattPerSquareMetre)
        case .sunshine_duration:
            let directRadiation = try await get(derived: .direct_radiation, time: time)
            let duration = Zensun.calculateBackwardsSunshineDuration(directRadiation: directRadiation.data, latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.time)
            return DataAndUnit(duration, .seconds)
        }
    }

    func prefetchData(derived: Derived, time: TimerangeDtAndSettings) async throws {
        switch derived {
        case .terrestrial_radiation, .terrestrial_radiation_instant:
            break
        case .shortwave_radiation_instant, .direct_radiation, .direct_normal_irradiance, .direct_normal_irradiance_instant, .direct_radiation_instant, .diffuse_radiation, .diffuse_radiation_instant, .global_tilted_irradiance, .global_tilted_irradiance_instant, .sunshine_duration:
            try await prefetchData(raw: .shortwave_radiation, time: time)
        }
    }
}
