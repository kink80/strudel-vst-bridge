use std::env;
use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    // Compile the Objective-C AUv3 host
    cc::Build::new()
        .file("src/auv3_host.m")
        .flag("-fobjc-arc")
        .flag("-fmodules")
        .compile("auv3_host");

    // Link required frameworks
    println!("cargo:rustc-link-lib=framework=AudioToolbox");
    println!("cargo:rustc-link-lib=framework=CoreAudioKit");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");

    println!("cargo:rerun-if-changed=src/auv3_host.m");
}
