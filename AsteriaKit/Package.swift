// swift-tools-version: 6.2
import PackageDescription

// AsteriaKit — Swift-native, headless, TDD-tested core. Apple Silicon / macOS 26+.
let package = Package(
    name: "AsteriaKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AsteriaKit", targets: ["AsteriaKit"]),
        .library(name: "GameStreamProtocol", targets: ["GameStreamProtocol"]),
        .library(name: "Pairing", targets: ["Pairing"]),
        .library(name: "Discovery", targets: ["Discovery"]),
        .library(name: "VideoEngine", targets: ["VideoEngine"]),
        .library(name: "LiveSession", targets: ["LiveSession"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "InputEngine", targets: ["InputEngine"]),
        .library(name: "AsteriaModel", targets: ["AsteriaModel"]),
    ],
    dependencies: [
        // Apache-2.0 (permissive, commercial-safe): RSA-2048 client-cert generation + crypto for pairing.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .target(name: "AsteriaCore"),
        // Vendored MIT ENet (Lee Salzman) — reliable-UDP control stream, wire-compatible with the host.
        .target(name: "CENet", exclude: ["LICENSE"]),
        // Pinned upstream MIT nanors with an Asteria-owned Host audio adapter.
        .target(
            name: "CNanors",
            exclude: ["LICENSE", "UPSTREAM.md"],
            cSettings: [.headerSearchPath("deps/obl")]
        ),
        // Vendored BSD libopus 1.5.2 (decoder-focused float build, portable C, no SIMD/RTCD).
        // silk/fixed/*.c excluded (fixed-point encoder path); their headers stay for the float encoder.
        .target(
            name: "COpus",
            exclude: [
                "LICENSE",
                "silk/fixed/apply_sine_window_FIX.c",
                "silk/fixed/autocorr_FIX.c",
                "silk/fixed/burg_modified_FIX.c",
                "silk/fixed/corrMatrix_FIX.c",
                "silk/fixed/encode_frame_FIX.c",
                "silk/fixed/find_LPC_FIX.c",
                "silk/fixed/find_LTP_FIX.c",
                "silk/fixed/find_pitch_lags_FIX.c",
                "silk/fixed/find_pred_coefs_FIX.c",
                "silk/fixed/k2a_FIX.c",
                "silk/fixed/k2a_Q16_FIX.c",
                "silk/fixed/LTP_analysis_filter_FIX.c",
                "silk/fixed/LTP_scale_ctrl_FIX.c",
                "silk/fixed/noise_shape_analysis_FIX.c",
                "silk/fixed/pitch_analysis_core_FIX.c",
                "silk/fixed/process_gains_FIX.c",
                "silk/fixed/regularize_correlations_FIX.c",
                "silk/fixed/residual_energy_FIX.c",
                "silk/fixed/residual_energy16_FIX.c",
                "silk/fixed/schur_FIX.c",
                "silk/fixed/schur64_FIX.c",
                "silk/fixed/vector_ops_FIX.c",
                "silk/fixed/warped_autocorrelation_FIX.c",
            ],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("silk/fixed"),
                .headerSearchPath("src"),
                .headerSearchPath("include"),
            ]
        ),
        .target(name: "GameStreamProtocol", dependencies: ["AsteriaCore", "CENet", "CNanors"]),
        .target(name: "Pairing", dependencies: [
            "AsteriaCore", "GameStreamProtocol",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .target(name: "Discovery", dependencies: ["AsteriaCore"]),
        .target(name: "VideoEngine", dependencies: ["AsteriaCore", "GameStreamProtocol"]),
        // High-level live-session driver: state machine + control API + pluggable decode/render sink.
        .target(
            name: "LiveSession",
            dependencies: ["GameStreamProtocol", "Pairing", "VideoEngine", "AudioEngine",
                           "Discovery", "InputEngine", "AsteriaModel"]
        ),
        .target(name: "AudioEngine", dependencies: ["AsteriaCore", "GameStreamProtocol", "COpus"]),
        .target(name: "InputEngine", dependencies: ["AsteriaCore", "GameStreamProtocol", "AsteriaModel"]),
        // App data layer: roster, settings (global + per-host merge), persistence, secret store. Pure value types.
        .target(name: "AsteriaModel", dependencies: ["AsteriaCore"]),
        .target(
            name: "AsteriaKit",
            dependencies: [
                "AsteriaCore", "GameStreamProtocol", "Pairing", "Discovery",
                "VideoEngine", "LiveSession", "AudioEngine", "InputEngine", "AsteriaModel",
            ]
        ),

        .testTarget(name: "AsteriaCoreTests", dependencies: ["AsteriaCore"]),
        .testTarget(name: "GameStreamProtocolTests", dependencies: ["GameStreamProtocol"]),
        .testTarget(name: "PairingTests", dependencies: ["Pairing", "AsteriaCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery"], resources: [.copy("Fixtures")]),
        .testTarget(name: "VideoEngineTests", dependencies: ["VideoEngine"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LiveSessionTests", dependencies: ["LiveSession"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine", "COpus"]),
        .testTarget(name: "InputEngineTests", dependencies: ["InputEngine"]),
        .testTarget(name: "AsteriaModelTests", dependencies: ["AsteriaModel"]),
        .testTarget(name: "AsteriaKitTests", dependencies: ["AsteriaKit"]),
    ]
)
