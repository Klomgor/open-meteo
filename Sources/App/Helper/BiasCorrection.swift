import Foundation


/// QDM bias correction to preserve deltas in data. E.g. events of temperature > 20°C are better represented
/// Calculates CDFs for reference and control data on a monthly basis.
/// CDFs for forecast data are sliding averages over 10 years to preserve climat change signal.
/// Without sliding CDF, it is a regular Quantile Mapping QM that reduces climage change signals.
///
/// QM and QDM based on https://link.springer.com/article/10.1007/s00382-020-05447-4
/// QDM paper https://journals.ametsoc.org/view/journals/clim/28/17/jcli-d-14-00754.1.xml
/// Loosly based on https://github.com/btschwertfeger/BiasAdjustCXX/blob/master/src/CMethods.cxx
struct QuantileDeltaMappingBiasCorrection {
    
    enum ChangeType {
        /// Correct offset. E.g. temperature
        case absoluteChage
        
        /// Scale. E.g. Precipitation
        case relativeChange
    }
    
    /// Important note: If CDF of `forecast` is the same as `control` the climate change signal might be canceled out. It can be used however to just do a simple BIAS transfer from one model to another
    static func quantileDeltaMappingMonthly(reference: ArraySlice<Float>, control: ArraySlice<Float>, referenceTime: TimerangeDt, forecast: ArraySlice<Float>, forecastTime: TimerangeDt, type: ChangeType) -> [Float] {
        let nQuantiles = 100
        
        // Compute reference distributions
        let binsControl = calculateBins(control, nQuantiles: nQuantiles, min: type == .relativeChange ? 0 : nil)
        let binsRefernce = calculateBins(reference, nQuantiles: nQuantiles, min: type == .relativeChange ? 0 : nil)
        let cdfRefernce = CdfMonthly10YearSliding(vector: reference, time: referenceTime, bins: binsRefernce)
        let cdfControl = CdfMonthly10YearSliding(vector: control, time: referenceTime, bins: binsControl)
        
        // Apply
        let binsForecast = calculateBins(forecast, nQuantiles: nQuantiles, min: type == .relativeChange ? 0 : nil)
        let cdfForecast = CdfMonthly10YearSliding(vector: forecast, time: forecastTime, bins: binsForecast)

        switch type {
        case .absoluteChage:
            return zip(forecastTime, forecast).map { (time, forecast) in
                let epsilon = interpolate(binsForecast, cdfForecast, x: forecast, time: time, extrapolate: false)
                let qdm1 = interpolate(cdfRefernce, binsRefernce, x: epsilon, time: time, extrapolate: false)
                return qdm1 + forecast - interpolate(cdfControl, binsControl, x: epsilon, time: time, extrapolate: false)
            }
        case .relativeChange:
            let maxScaleFactor: Float = 10
            return zip(forecastTime, forecast).map { (time, forecast) in
                let epsilon = interpolate(binsForecast, cdfForecast, x: forecast, time: time, extrapolate: false)
                let qdm1 = interpolate(cdfRefernce, binsRefernce, x: epsilon, time: time, extrapolate: false)
                let scale = forecast / interpolate(cdfControl, binsControl, x: epsilon, time: time, extrapolate: false)
                return scale == 0 ? 0 : qdm1 * min(max(scale, maxScaleFactor * -1), maxScaleFactor)
            }
        }
    }
    
    /// Calcualte min/max from vector and return bins
    /// nQuantiles of 100 should be sufficient
    static func calculateBins(_ vector: ArraySlice<Float>, nQuantiles: Int = 100, min: Float? = nil) -> Bins {
        guard let minMax = vector.minAndMax() else {
            return Bins(min: .nan, max: .nan, nQuantiles: nQuantiles)
        }
        return Bins(min: min ?? minMax.min, max: minMax.max, nQuantiles: nQuantiles)
    }
    
    /// Find value `x` on first array, then interpolate on the second array to return the value
    static func interpolate<Cdf: MonthlyBinable>(_ xData: Bins, _ yData: Cdf, x: Float, time: Timestamp, extrapolate: Bool) -> Float {
        //assert(xData.count == yData.count)
        let size = xData.count

        var i = 0;  // find left end of interval for interpolation
        if x >= xData[xData.index(xData.startIndex, offsetBy: size - 2)] {
            i = size - 2;  // special case: beyond right end
        } else {
            while (x > xData[xData.index(xData.startIndex, offsetBy: i + 1)]) { i += 1 }
        }
        let xL = xData[xData.index(xData.startIndex, offsetBy: i)]
        var yL = yData.get(bin: i, time: time)
        let xR = xData[xData.index(xData.startIndex, offsetBy: i + 1)]
        var yR = yData.get(bin: i+1, time: time) // points on either side (unless beyond ends)

        if !extrapolate {  // if beyond ends of array and not extrapolating
            if (x < xL) { yR = yL }
            if (x > xR) { yL = yR }
        }
        let dydx = xR - xL == 0 ? 0 : (yR - yL) / (xR - xL);  // gradient
        return yL + dydx * (x - xL);       // linear interpolation
    }
    
    /// Find value `x` on first array, then interpolate on the second array to return the value
    static func interpolate<Cdf: MonthlyBinable>(_ xData: Cdf, _ yData: Bins, x: Float, time: Timestamp, extrapolate: Bool) -> Float {
        //assert(xData.count == yData.count)
        let size = xData.nBins

        var i = 0;  // find left end of interval for interpolation
        if x >= xData.get(bin: size - 2, time: time) {
            i = size - 2;  // special case: beyond right end
        } else {
            while (x > xData.get(bin: i+1, time: time)) { i += 1 }
        }
        let xL = xData.get(bin: i, time: time)
        var yL = yData[yData.index(yData.startIndex, offsetBy: i)]
        let xR = xData.get(bin: i+1, time: time)
        var yR = yData[yData.index(yData.startIndex, offsetBy: i + 1)] // points on either side (unless beyond ends)

        if !extrapolate {  // if beyond ends of array and not extrapolating
            if (x < xL) { yR = yL }
            if (x > xR) { yL = yR }
        }
        let dydx = xR - xL == 0 ? 0 : (yR - yL) / (xR - xL);  // gradient
        return yL + dydx * (x - xL);       // linear interpolation
    }
}

/// Calculate and/or apply a linear bias correction to correct a fixed offset
/// Deltas are calculated for each month individually and use linear interpolation
struct BiasCorrectionSeasonalLinear {
    /// Could be one mean value for each month. Depends on `binsPerYear`
    /// Values are a mean of input data
    let meansPerYear: [Float]
    
    /// Calculate means using the inverse of linear interpolation
    public init(_ data: ArraySlice<Float>, time: TimerangeDt, binsPerYear: Int = 12) {
        var sums = [Float](repeating: 0, count: binsPerYear)
        var weights = [Float](repeating: 0, count: binsPerYear)
        for (t, v) in zip(time, data) {
            let monthBin = t.secondInAverageYear / (31_557_600 / binsPerYear)
            let fraction = Float(t.secondInAverageYear).truncatingRemainder(dividingBy: Float(31_557_600 / binsPerYear)) / Float(31_557_600 / binsPerYear)
            let weighted = Interpolations.linearWeighted(value: v, fraction: fraction)
            sums[monthBin] += weighted.a
            weights[monthBin] += weighted.weightA
            sums[(monthBin+1) % binsPerYear] += weighted.b
            weights[(monthBin+1) % binsPerYear] += weighted.weightB
        }
        self.meansPerYear = zip(weights, sums).map({ $0.0 <= 0.001 ? .nan : $0.1 / $0.0 })
    }
    
    func applyOffset(on data: inout [Float], otherWeights: BiasCorrectionSeasonalLinear, time: TimerangeDt, type: QuantileDeltaMappingBiasCorrection.ChangeType, indices: Range<Int>? = nil) {
        let indices = indices ?? data.indices
        let binsPerYear = meansPerYear.count
        assert(time.count == indices.count)
        for (i ,t) in zip(indices, time) {
            let monthBin = t.secondInAverageYear / (31_557_600 / binsPerYear)
            let fraction = Float(t.secondInAverageYear).truncatingRemainder(dividingBy: Float(31_557_600 / binsPerYear)) / Float(31_557_600 / binsPerYear)
            let m = Interpolations.linear(a: meansPerYear[monthBin], b: meansPerYear[(monthBin+1) % binsPerYear], fraction: fraction)
            let o = Interpolations.linear(a: otherWeights.meansPerYear[monthBin], b: otherWeights.meansPerYear[(monthBin+1) % binsPerYear], fraction: fraction)
            switch type {
            case .absoluteChage:
                data[i] += m - o
            case .relativeChange:
                data[i] *= m / o
            }
        }
    }
}

/// Calculate and/or apply a linear bias correction to correct a fixed offset
/// Deltas are calculated for each month individually and use linear interpolation
struct BiasCorrectionSeasonalHermite {
    /// Could be one mean value for each month. Depends on `binsPerYear`
    /// Values are a mean of input data
    let meansPerYear: [Float]
    
    /// Calculate means using the inverse of linear interpolation
    public init(_ data: ArraySlice<Float>, time: TimerangeDt, binsPerYear: Int = 12) {
        var sums = [Double](repeating: 0, count: binsPerYear)
        var weights = [Double](repeating: 0, count: binsPerYear)
        for (t, v) in zip(time, data) {
            let monthBin = t.secondInAverageYear / (31_557_600 / binsPerYear)
            let fraction = Float(t.secondInAverageYear).truncatingRemainder(dividingBy: Float(31_557_600 / binsPerYear)) / Float(31_557_600 / binsPerYear)
            let weighted = Interpolations.hermiteWeighted(value: v, fraction: fraction)
            sums[(monthBin-1+binsPerYear) % binsPerYear] += Double(weighted.a)
            weights[(monthBin-1+binsPerYear) % binsPerYear] +=  Double(weighted.weightA)
            sums[monthBin] +=  Double(weighted.b)
            weights[monthBin] +=  Double(weighted.weightB)
            sums[(monthBin+1) % binsPerYear] +=  Double(weighted.c)
            weights[(monthBin+1) % binsPerYear] +=  Double(weighted.weightC)
            sums[(monthBin+2) % binsPerYear] +=  Double(weighted.d)
            weights[(monthBin+2) % binsPerYear] +=  Double(weighted.weightD)

        }
        self.meansPerYear = zip(weights, sums).map({ $0.0 <= 0.001 ? .nan : Float($0.1 / $0.0) })
    }
    
    func applyOffset(on data: inout [Float], otherWeights: BiasCorrectionSeasonalHermite, time: TimerangeDt, type: QuantileDeltaMappingBiasCorrection.ChangeType, indices: Range<Int>? = nil) {
        let indices = indices ?? data.indices
        let binsPerYear = meansPerYear.count
        assert(time.count == indices.count)
        for (i ,t) in zip(indices, time) {
            let monthBin = t.secondInAverageYear / (31_557_600 / binsPerYear)
            let fraction = Float(t.secondInAverageYear).truncatingRemainder(dividingBy: Float(31_557_600 / binsPerYear)) / Float(31_557_600 / binsPerYear)
            let m = Interpolations.hermite(
                A: meansPerYear[(monthBin-1+binsPerYear) % binsPerYear],
                B: meansPerYear[monthBin],
                C: meansPerYear[(monthBin+1) % binsPerYear],
                D: meansPerYear[(monthBin+2) % binsPerYear],
                fraction: fraction
            )
            let o = Interpolations.hermite(
                A: otherWeights.meansPerYear[(monthBin-1+binsPerYear) % binsPerYear],
                B: otherWeights.meansPerYear[monthBin],
                C: otherWeights.meansPerYear[(monthBin+1) % binsPerYear],
                D: otherWeights.meansPerYear[(monthBin+2) % binsPerYear],
                fraction: fraction
            )
            switch type {
            case .absoluteChage:
                data[i] += m - o
            case .relativeChange:
                data[i] *= m / o
            }
        }
    }
}




protocol MonthlyBinable {
    func get(bin: Int, time t: Timestamp) -> Float
    var nBins: Int { get }
}

/// Calculate CDF for each month individually
struct CdfMonthly: MonthlyBinable {
    let cdf: [Float]
    let bins: Bins
    
    static var binsPerYear: Int { 6 }
    
    var nBins: Int {
        cdf.count / Self.binsPerYear
    }
    
    /// input temperature and time axis
    init(vector: ArraySlice<Float>, time: TimerangeDt, bins: Bins) {
        let count = bins.nQuantiles
        var cdf = [Float](repeating: 0, count: count * Self.binsPerYear)
        for (t, value) in zip(time, vector) {
            let monthBin = t.secondInAverageYear / (31_557_600 / Self.binsPerYear)
            let fraction = Float(t.secondInAverageYear).truncatingRemainder(dividingBy: Float(31_557_600 / Self.binsPerYear)) / Float(31_557_600 / Self.binsPerYear)
            for (i, bin) in bins.enumerated().reversed() {
                if value >= bin && value < bins[i+1] {
                    // value exactly inside a bin, adjust weight
                    let interBinFraction = (bins[i+1]-value)/(bins[i+1]-bin)
                    let weigthted = Interpolations.linearWeighted(value: fraction, fraction: interBinFraction)
                    assert(interBinFraction >= 0 && interBinFraction <= 1)
                    cdf[monthBin * count + i] += weigthted.a
                    cdf[((monthBin+1) % Self.binsPerYear) * count + i] += weigthted.b
                } else if value < bin {
                    cdf[monthBin * count + i] += 1-fraction
                    cdf[((monthBin+1) % Self.binsPerYear) * count + i] += fraction
                } else {
                    break
                }
            }
        }
        /// normalise to 1
        for j in 0..<cdf.count / bins.count {
            // last value is always count... could also scale to something between bin min/max to make it compressible more easily
            let count = cdf[(j+1) * bins.count - 1]
            guard count > 0 else {
                continue
            }
            for i in j * bins.count ..< (j+1) * bins.count {
                cdf[i] = cdf[i] / count
            }
        }
        self.cdf = cdf
        self.bins = bins
    }
    
    /// linear interpolate between 2 months CDF
    func get(bin: Int, time t: Timestamp) -> Float {
        let monthBin = t.secondInAverageYear / (31_557_600 / Self.binsPerYear)
        let fraction = Float(t.secondInAverageYear).truncatingRemainder(dividingBy: Float(31_557_600 / Self.binsPerYear)) / Float(31_557_600 / Self.binsPerYear)
        
        let binLength = cdf.count / Self.binsPerYear
        return Interpolations.linear(a: cdf[binLength * monthBin + bin], b: cdf[binLength * ((monthBin+1) % Self.binsPerYear) + bin], fraction: fraction)
    }
}


/// Calculate CDF for each month individually, but over a sliding window of 10 years
struct CdfMonthly10YearSliding: MonthlyBinable {
    let cdf: [Float]
    var nBins: Int { bins.nQuantiles }
    let yearMin: Float
    let yearMax: Float
    let bins: Bins
    
    static var binsPerYear: Int { 6 }
    
    /// input temperature and time axis
    init(vector: ArraySlice<Float>, time: TimerangeDt, bins: Bins) {
        let yearMax = Float(time.range.upperBound.timeIntervalSince1970 / 3600) / 24 / 365.25
        let yearMin = Float(time.range.lowerBound.timeIntervalSince1970 / 3600) / 24 / 365.25
        let nYears = Int(yearMax - yearMin) + 2
        print("n Years \(nYears)")
        
        let count = bins.nQuantiles
        var cdf = [Float](repeating: 0, count: count * Self.binsPerYear * nYears)
        for (t, value) in zip(time, vector) {
            let monthBin = t.secondInAverageYear / (31_557_600 / Self.binsPerYear)
            let fraction = Float(t.secondInAverageYear).truncatingRemainder(dividingBy: Float(31_557_600 / Self.binsPerYear)) / Float(31_557_600 / Self.binsPerYear)
            
            let fractionalYear = Float(t.timeIntervalSince1970 / 3600) / 24 / 365.25
            let yearBin = Int(fractionalYear - yearMin)
            
            let dYear = 4
            for (i, bin) in bins.enumerated().reversed() {
                if value >= bin && value < bins[i+1] {
                    // value exactly inside a bin, adjust weight
                    let interBinFraction = (bins[i+1]-value)/(bins[i+1]-bin)
                    assert(interBinFraction >= 0 && interBinFraction <= 1)
                    let weigthted = Interpolations.linearWeighted(value: fraction, fraction: interBinFraction)
                    for y in max(yearBin-dYear, 0) ..< min(yearBin+dYear+1, nYears) {
                        cdf[(monthBin * count + i) + count * Self.binsPerYear * y] += weigthted.a
                        cdf[(((monthBin+1) % Self.binsPerYear) * count + i) + count * Self.binsPerYear * y] += weigthted.b
                    }
                } else if value < bin {
                    for y in max(yearBin-dYear, 0) ..< min(yearBin+dYear+1, nYears) {
                        cdf[(monthBin * count + i) + count * Self.binsPerYear * y] += 1-fraction
                        cdf[(((monthBin+1) % Self.binsPerYear) * count + i) + count * Self.binsPerYear * y] += fraction
                    }
                } else {
                    break
                }
            }
        }
        /// normalise to 1
        for j in 0..<cdf.count / bins.count {
            // last value is always count... could also scale to something between bin min/max to make it compressible more easily
            let count = cdf[(j+1) * bins.count - 1]
            guard count > 0 else {
                continue
            }
            for i in j * bins.count ..< (j+1) * bins.count {
                cdf[i] = cdf[i] / count
            }
        }
        self.cdf = cdf
        self.bins = bins
        self.yearMin = yearMin
        self.yearMax = yearMax
    }
    
    /// linear interpolate between 2 months CDF
    func get(bin: Int, time t: Timestamp) -> Float {
        let monthBin = t.secondInAverageYear / (31_557_600 / Self.binsPerYear)
        let fraction = Float(t.secondInAverageYear).truncatingRemainder(dividingBy: Float(31_557_600 / Self.binsPerYear)) / Float(31_557_600 / Self.binsPerYear)
        
        let fractionalYear = Float(t.timeIntervalSince1970 / 3600) / 24 / 365.25
        // Cut off 4 years... This was it is always using longer averages... The last year, might only have 3 year averages
        let yearBin = Int(min(fractionalYear, yearMax-4) - yearMin)
        
        
        return Interpolations.linear(
            a: cdf[nBins * Self.binsPerYear * yearBin + nBins * monthBin + bin],
            b: cdf[nBins * Self.binsPerYear * yearBin + nBins * ((monthBin+1) % Self.binsPerYear) + bin],
            fraction: fraction)
    }
}

/// Represent bin sizes. Iteratable like an array, but only stores min/max/nQuantiles
struct Bins {
    let min: Float
    let max: Float
    let nQuantiles: Int
}

extension Bins: RandomAccessCollection {
    subscript(position: Int) -> Float {
        get {
            return min + (max - min) / Float(nQuantiles) * Float(position)
        }
    }
    
    var indices: Range<Int> {
        return startIndex..<endIndex
    }
    
    var startIndex: Int {
        return 0
    }
    
    var endIndex: Int {
        return nQuantiles
    }
    
    func index(before i: Int) -> Int {
        i - 1
    }
    
    func index(after i: Int) -> Int {
        i + 1
    }
}

struct Interpolations {
    @inlinable static func linear(a: Float, b: Float, fraction: Float) -> Float {
        return a * (1-fraction) + b * fraction
    }
    
    @inlinable static func linearWeighted(value: Float, fraction: Float) -> (a: Float, b: Float, weightA: Float, weightB: Float) {
        return (value * (1-fraction), value * fraction, (1-fraction), fraction)
    }
    
    // Hermite interpolate between point B and C
    @inlinable static func hermite(A: Float, B: Float, C: Float, D: Float, fraction: Float) -> Float {
        let a = -A/2.0 + (3.0*B)/2.0 - (3.0*C)/2.0 + D/2.0
        let b = A - (5.0*B)/2.0 + 2.0*C - D / 2.0
        let c = -A/2.0 + C/2.0
        let d = B
        return a*fraction*fraction*fraction + b*fraction*fraction + c*fraction + d
    }
    
    @inlinable static func hermiteWeighted(value: Float, fraction: Float) -> (a: Float, b: Float, c: Float, d: Float, weightA: Float, weightB: Float, weightC: Float, weightD: Float) {
        return (value*fraction*fraction*fraction, value*fraction*fraction, value*fraction, value, fraction*fraction*fraction, fraction*fraction, fraction, 1)
    }
}
