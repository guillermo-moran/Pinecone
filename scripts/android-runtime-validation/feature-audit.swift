@main
struct FeatureAudit {
    static func main() {
        var bank = ARM64SystemRegisterBank()
        let registers: [(String, ARM64SystemRegisterKey)] = [
            ("ID_AA64PFR0_EL1", ARM64SystemRegister.idAA64PFR0EL1),
            ("ID_AA64ISAR0_EL1", ARM64SystemRegister.idAA64ISAR0EL1),
            ("ID_AA64ISAR1_EL1", ARM64SystemRegister.idAA64ISAR1EL1)
        ]
        var cpu = CPUState()
        for (name, key) in registers {
            let value = bank.rawValue(for: key)
            bank.write(key, value: .max, cpu: &cpu)
            precondition(bank.rawValue(for: key) == value, "ID registers must be guest read-only")
            bank.reset()
            precondition(bank.rawValue(for: key) == value, "reset must preserve default feature policy")
            print("\(name)=0x\(String(value, radix: 16))")
        }
        let pfr = bank.rawValue(for: ARM64SystemRegister.idAA64PFR0EL1)
        let isar0 = bank.rawValue(for: ARM64SystemRegister.idAA64ISAR0EL1)
        let isar1 = bank.rawValue(for: ARM64SystemRegister.idAA64ISAR1EL1)
        print("FP=\((pfr >> 16) & 15) ASIMD=\((pfr >> 20) & 15) SVE=\((pfr >> 32) & 15)")
        print("AES=\((isar0 >> 4) & 15) CRC32=\((isar0 >> 16) & 15) Atomic=\((isar0 >> 20) & 15)")
        print("APA=\((isar1 >> 4) & 15) API=\((isar1 >> 8) & 15)")
        print("feature_bank_checks=6; instruction semantics are tested separately by run.sh")
    }
}
