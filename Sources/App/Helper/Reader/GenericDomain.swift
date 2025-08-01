import Foundation
import OmFileFormat
import Vapor

/**
 Generic domain that is required for the reader
 */
protocol GenericDomain: Sendable {
    /// The grid definition. Could later be replaced with a more generic implementation
    var grid: Gridable { get }

    /// Domain name used as data directory
    var domainRegistry: DomainRegistry { get }

    /// Domain which is used for static files. E.g. 15minutes domains refer to the 1-hourly domain
    var domainRegistryStatic: DomainRegistry? { get }

    /// Time resoltuion of the deomain. 3600 for hourly, 10800 for 3-hourly
    var dtSeconds: Int { get }

    /// How often a domain is updated in seconds. `3600` for updates every hour
    var updateIntervalSeconds: Int { get }

    /// If true, domain has yearly files
    var hasYearlyFiles: Bool { get }

    /// If present, the timerange that is available in a master file
    var masterTimeRange: Range<Timestamp>? { get }

    /// The time length of each compressed time series file
    var omFileLength: Int { get }
}

extension GenericDomain {
    var dtHours: Int { dtSeconds / 3600 }

    /// Temporary directory to download data
    var downloadDirectory: String {
        return "\(OpenMeteo.tempDirectory)download-\(domainRegistry.rawValue)/"
    }
    
    /// Temporary directory to download data
    var dataRunDirectory: String? {
        guard let dataRunDirectory = OpenMeteo.dataRunDirectory else {
            return nil
        }
        return "\(dataRunDirectory)\(domainRegistry.rawValue)/"
    }

    /// The the file containing static information for elevation of soil types
    func getStaticFile(type: ReaderStaticVariable, httpClient: HTTPClient, logger: Logger) async -> (any OmFileReaderArrayProtocol<Float>)? {
        guard let domainRegistryStatic else {
            return nil
        }
        switch type {
        case .soilType:
            return try? await RemoteOmFileManager.instance.get(
                file: .staticFile(domain: domainRegistryStatic, variable: "soil_type", chunk: nil),
                client: httpClient,
                logger: logger
            )
        case .elevation:
            return try? await RemoteOmFileManager.instance.get(
                file: .staticFile(domain: domainRegistryStatic, variable: "HSURF", chunk: nil),
                client: httpClient,
                logger: logger
            )
        }
    }

    func getMetaJson() throws -> ModelUpdateMetaJson? {
        return try MetaFileManager.get(OmFileManagerReadable.meta(domain: domainRegistry))
    }

    /// Filename of the surface elevation file
    var surfaceElevationFileOm: OmFileManagerReadable {
        .staticFile(domain: domainRegistryStatic ?? domainRegistry, variable: "HSURF", chunk: nil)
    }

    var soilTypeFileOm: OmFileManagerReadable {
        .staticFile(domain: domainRegistryStatic ?? domainRegistry, variable: "soil_type", chunk: nil)
    }
}

/**
 Generic variable for the reader implementation
 */
protocol GenericVariable: GenericVariableMixable, Sendable {
    /// The filename of the variable. Typically just `temperature_2m`. Level is used to store mutliple levels or ensemble members in one file
    /// NOTE: `level` has been replaced with `ensembleMemberLevel` in settings
    var omFileName: (file: String, level: Int) { get }

    /// The scalefactor to compress data
    var scalefactor: Float { get }

    /// Kind of interpolation for this variable. Used to interpolate from 1 to 3 hours
    var interpolation: ReaderInterpolation { get }

    /// SI unit of this variable
    var unit: SiUnit { get }

    /// If true, temperature will be corrected by 0.65°K per 100 m
    var isElevationCorrectable: Bool { get }

    /// If true, forecasts from the previous model runs will be preserved
    var storePreviousForecast: Bool { get }
}

enum ReaderInterpolation {
    /// Simple linear interpolation
    case linear

    /// Interpolate 0-360° values
    case linearDegrees

    /// Hermite interpolation for more smooth interpolation for temperature
    case hermite(bounds: ClosedRange<Float>?)

    /// Solar fluxes are properly backwards averaged during model run time. Always be the case with weather models
    case solar_backwards_averaged

    /// Solar flux is backwards averaged, but values after missing values are not averaged correctly.
    /// This happens with satellite data and missing time steps
    case solar_backwards_missing_not_averaged

    /// Take the next hour, and devide by `dt` to preserve sums like precipitation
    case backwards_sum

    /// Replicate value backwards. E.g. min/max of previous hours
    case backwards

    /// How many timesteps on the left and right side are used for interpolation
    var padding: Int {
        switch self {
        case .linear, .linearDegrees:
            return 1
        case .hermite:
            return 2
        case .solar_backwards_averaged, .solar_backwards_missing_not_averaged:
            return 2
        case .backwards_sum, .backwards:
            return 1
        }
    }

    var bounds: ClosedRange<Float>? {
        switch self {
        case .hermite(let bounds):
            return bounds
        default:
            return nil
        }
    }
}
