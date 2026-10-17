// Compiles the Swift windows that haven't been ported yet (app/*.swift) into a static
// library and links it, together with the Swift runtime, into the Rust app.
use std::{env, path::PathBuf, process::Command};

fn output(program: &str, args: &[&str]) -> String {
    let result = Command::new(program).args(args).output().unwrap_or_else(|error| panic!("{program}: {error}"));
    assert!(result.status.success(), "{program} {args:?} failed: {}", String::from_utf8_lossy(&result.stderr));
    String::from_utf8(result.stdout).unwrap().trim().to_string()
}

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let swift_dir = manifest.join("../app");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let mut sources: Vec<PathBuf> = std::fs::read_dir(&swift_dir).unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "swift"))
        .collect();
    sources.sort();
    for source in &sources { println!("cargo:rerun-if-changed={}", source.display()); }
    println!("cargo:rerun-if-changed={}", swift_dir.display());

    let target = if env::var("CARGO_CFG_TARGET_ARCH").unwrap() == "x86_64" { "x86_64-apple-macosx13.0" } else { "arm64-apple-macosx13.0" };
    let library = out.join("libAmyfreeUI.a");
    let status = Command::new("swiftc")
        .args(["-O", "-parse-as-library", "-emit-library", "-static", "-module-name", "AmyfreeUI", "-target", target])
        .arg("-module-cache-path").arg(out.join("swift-cache"))
        .arg("-o").arg(&library)
        .args(&sources)
        .status().expect("swiftc not found; install Xcode or the Command Line Tools");
    assert!(status.success(), "compiling the Swift windows failed");

    let sdk = output("xcrun", &["--sdk", "macosx", "--show-sdk-path"]);
    let swiftc = PathBuf::from(output("xcrun", &["-f", "swiftc"]));
    let toolchain_swift = swiftc.parent().unwrap().join("../lib/swift/macosx");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=AmyfreeUI");
    println!("cargo:rustc-link-search=native={sdk}/usr/lib/swift");
    println!("cargo:rustc-link-search=native={}", toolchain_swift.display());
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    for framework in ["AppKit", "Foundation", "Security", "ServiceManagement"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
