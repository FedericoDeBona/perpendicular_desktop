/// Keep the small release step near the guest reserve. With abundant measured
/// availability, avoid spending minutes returning memory after Desktop closes.
enum MemoryReleaseBudget {
    static func step(available:UInt64,reserve:UInt64)->UInt64 {
        let quantum:UInt64=128*1_048_576
        guard available>reserve,available-reserve>reserve else{return quantum}
        let surplus=available-reserve-reserve
        return min(4*quantum,max(quantum,(surplus/quantum)*quantum))
    }
}
