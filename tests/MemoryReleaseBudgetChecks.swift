@main struct MemoryReleaseBudgetChecks {
    static func main(){
        let MiB:UInt64=1_048_576
        let cases:[(UInt64,UInt64)]=[(0,128),(512,128),(1024,128),
            (1152,128),(1279,128),(1280,256),(1536,512),(8192,512)]
        for (available,expected) in cases {
            precondition(MemoryReleaseBudget.step(available:available*MiB,reserve:512*MiB)==expected*MiB,
                         "Release budget at \(available) MiB")
        }
        precondition(MemoryReleaseBudget.step(available:UInt64.max,reserve:UInt64.max)==128*MiB)
        precondition(MemoryReleaseBudget.step(available:UInt64.max,reserve:UInt64.max/2+1)==128*MiB)
        print("Memory release: reserve boundaries, ample headroom, cap and overflow passed")
    }
}
