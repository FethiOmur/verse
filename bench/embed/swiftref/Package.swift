// swift-tools-version: 6.0
import PackageDescription

// Throwaway reference runner: a verbatim copy of app/Sources/VerseTurns/Bank.swift (see copy_bank.sh)
// so the bench scores the REAL n-gram matcher without building or touching app/.
let package = Package(
    name: "ngramref",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "ngramref", path: "Sources/ngramref")]
)
