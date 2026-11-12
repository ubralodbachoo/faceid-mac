import Darwin

/// Includes time spent asleep, so a suspended process cannot extend a credential lease.
public enum ContinuousTime {
    public static var now: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
