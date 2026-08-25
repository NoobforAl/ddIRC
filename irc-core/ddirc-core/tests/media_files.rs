//! Run the metadata stripper over real files.
//!
//! The unit tests are built on fixtures this repository writes itself, which
//! proves the parsers agree with the author's reading of four specifications
//! and nothing more. Real images come from cameras and editors that use the
//! same formats differently — segments in another order, chunks the fixtures
//! never contain, padding where none was expected.
//!
//! Ignored by default because it needs files to point at:
//!
//! ```bash
//! DDIRC_MEDIA_DIR=/path/to/photos \
//!   cargo test --manifest-path irc-core/Cargo.toml -p ddirc-core \
//!   --test media_files -- --ignored --nocapture
//! ```
//!
//! Every file is stripped and written back beside the original with a
//! `.stripped` suffix, so the results can be opened and compared. Point it at
//! your own photographs: the failure this guards against is a file that comes
//! out subtly broken, and only something that decodes images can see that.

use std::path::Path;

use ddirc_core::media;

#[test]
#[ignore = "needs DDIRC_MEDIA_DIR pointing at real images"]
fn strips_every_file_in_a_directory() {
    let Ok(dir) = std::env::var("DDIRC_MEDIA_DIR") else {
        panic!("set DDIRC_MEDIA_DIR to a directory of images");
    };
    let dir = Path::new(&dir);

    let mut seen = 0;
    let mut skipped = 0;

    for entry in std::fs::read_dir(dir).expect("directory should be readable") {
        let path = entry.expect("entry should be readable").path();
        if !path.is_file() || path.to_string_lossy().ends_with(".stripped") {
            continue;
        }

        let bytes = std::fs::read(&path).expect("file should be readable");
        let name = path.file_name().unwrap_or_default().to_string_lossy();

        match media::strip(&bytes) {
            Ok(result) => {
                seen += 1;
                let saved = bytes.len() - result.bytes.len();
                // What was removed has to account for the change in size, or
                // something left the file without being reported.
                assert_eq!(
                    saved,
                    result.removed_bytes(),
                    "{name}: {saved} bytes smaller but {} reported",
                    result.removed_bytes()
                );
                assert!(
                    result.bytes.len() <= bytes.len(),
                    "{name}: stripping made it larger"
                );

                let what: Vec<_> = result
                    .removed
                    .iter()
                    .map(|r| format!("{} ({} bytes)", r.what, r.bytes))
                    .collect();
                println!(
                    "{name}: {} -> {} bytes [{}]",
                    bytes.len(),
                    result.bytes.len(),
                    if what.is_empty() {
                        "already clean".to_owned()
                    } else {
                        what.join(", ")
                    }
                );

                let out = path.with_extension(format!(
                    "{}.stripped",
                    path.extension().unwrap_or_default().to_string_lossy()
                ));
                std::fs::write(&out, &result.bytes).expect("should be writable");
            }
            Err(e) => {
                skipped += 1;
                println!("{name}: skipped - {e}");
            }
        }
    }

    println!("\n{seen} stripped, {skipped} skipped");
    assert!(seen > 0, "no supported images found in {}", dir.display());
}
