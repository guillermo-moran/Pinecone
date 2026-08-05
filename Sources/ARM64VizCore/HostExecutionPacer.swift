public struct HostExecutionPacer: Sendable, Equatable {
    public let runShareNumerator: UInt64
    public let cycleShareDenominator: UInt64
    public let interactionGraceNanoseconds: UInt64
    public let maximumDelayNanoseconds: UInt64

    public init(
        runShareNumerator: UInt64 = 4,
        cycleShareDenominator: UInt64 = 5,
        interactionGraceNanoseconds: UInt64 = 250_000_000,
        maximumDelayNanoseconds: UInt64 = 2_000_000
    ) {
        let denominator = max(2, cycleShareDenominator)
        self.runShareNumerator = min(max(1, runShareNumerator), denominator - 1)
        self.cycleShareDenominator = denominator
        self.interactionGraceNanoseconds = interactionGraceNanoseconds
        self.maximumDelayNanoseconds = maximumDelayNanoseconds
    }

    public func delayNanoseconds(
        afterRunDuration runDurationNanoseconds: UInt64,
        nowNanoseconds: UInt64,
        latestInteractionNanoseconds: UInt64?
    ) -> UInt64 {
        guard runDurationNanoseconds > 0, maximumDelayNanoseconds > 0 else {
            return 0
        }
        if let latestInteractionNanoseconds,
           nowNanoseconds <= latestInteractionNanoseconds ||
            nowNanoseconds - latestInteractionNanoseconds < interactionGraceNanoseconds {
            return 0
        }

        let idleShare = cycleShareDenominator - runShareNumerator
        let whole = runDurationNanoseconds / runShareNumerator
        let remainder = runDurationNanoseconds % runShareNumerator
        let (wholeDelay, overflowed) = whole.multipliedReportingOverflow(by: idleShare)
        let (remainderProduct, remainderOverflowed) =
            remainder.multipliedReportingOverflow(by: idleShare)
        let remainderDelay = remainderOverflowed
            ? UInt64.max
            : remainderProduct / runShareNumerator
        let (combinedDelay, additionOverflowed) =
            wholeDelay.addingReportingOverflow(remainderDelay)
        let calculatedDelay = overflowed || remainderOverflowed || additionOverflowed
            ? UInt64.max
            : combinedDelay
        return min(calculatedDelay, maximumDelayNanoseconds)
    }
}
