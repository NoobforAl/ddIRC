//! PNG: a signature, then a list of length-prefixed chunks.
//!
//! Each chunk is `<four-byte length> <four-byte type> <data> <four-byte CRC>`,
//! and the type says what it is. Dropping a chunk needs no other change: the
//! CRC covers only that chunk, so the ones that stay keep the checksums they
//! arrived with.

use super::{MediaKind, Removed, StripError, Stripped};

const KIND: MediaKind = MediaKind::Png;
const SIGNATURE: usize = 8;

/// Chunks that describe the file rather than draw it.
///
/// `tEXt`/`zTXt`/`iTXt` are free text, and phone and camera software fills
/// them with everything from the device name to the original EXIF re-encoded
/// as XML. `eXIf` is EXIF proper. `tIME` is the last-modified timestamp, which
/// is a fact about the sender's day.
fn describe(kind: &[u8; 4]) -> Option<&'static str> {
    match kind {
        b"tEXt" | b"zTXt" => Some("text"),
        b"iTXt" => Some("text"),
        b"eXIf" => Some("EXIF"),
        b"tIME" => Some("timestamp"),
        // Kept on purpose: iCCP is the colour profile, and gAMA/cHRM/sRGB
        // describe how the colours should be interpreted.
        _ => None,
    }
}

pub(super) fn strip(bytes: &[u8]) -> Result<Stripped, StripError> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut removed = Vec::new();

    out.extend_from_slice(&bytes[..SIGNATURE]);
    let mut i = SIGNATURE;

    // A PNG with no chunks at all is not a PNG; it has no header and no image.
    if bytes.len() <= SIGNATURE {
        return Err(StripError::malformed(KIND, "no chunks after the signature"));
    }

    while i < bytes.len() {
        let Some(length) = bytes
            .get(i..i + 4)
            .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize)
        else {
            return Err(StripError::malformed(KIND, "truncated chunk length"));
        };
        let Some(kind) = bytes.get(i + 4..i + 8) else {
            return Err(StripError::malformed(KIND, "truncated chunk type"));
        };
        let kind: [u8; 4] = kind.try_into().expect("checked to be four bytes");

        // Length, type, data and CRC. Computed with checked arithmetic because
        // the length is four attacker-chosen bytes and 4 GiB of it would wrap
        // a 32-bit `usize` straight back to a small number.
        let Some(total) = length.checked_add(12) else {
            return Err(StripError::malformed(KIND, "impossible chunk length"));
        };
        let Some(chunk) = bytes.get(i..i + total) else {
            return Err(StripError::malformed(KIND, "chunk runs past the end"));
        };

        match describe(&kind) {
            Some(what) => removed.push(Removed { what, bytes: total }),
            None => out.extend_from_slice(chunk),
        }

        i += total;

        // IEND closes the file. Anything after it is not part of the image,
        // and some tools have been known to hide things there.
        if &kind == b"IEND" {
            if i < bytes.len() {
                removed.push(Removed {
                    what: "data after the end of the image",
                    bytes: bytes.len() - i,
                });
            }
            break;
        }
    }

    Ok(Stripped {
        kind: KIND,
        bytes: out,
        removed,
    })
}

#[cfg(test)]
mod tests {
    use super::super::strip as strip_any;

    fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(kind);
        out.extend_from_slice(data);
        // A real CRC, which this module never recomputes because it never
        // alters a chunk it keeps. Any four bytes prove that.
        out.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]);
        out
    }

    fn png(chunks: &[(&[u8; 4], &[u8])]) -> Vec<u8> {
        let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
        out.extend_from_slice(&chunk(b"IHDR", &[0; 13]));
        for (kind, data) in chunks {
            out.extend_from_slice(&chunk(kind, data));
        }
        out.extend_from_slice(&chunk(b"IDAT", b"compressed pixels"));
        out.extend_from_slice(&chunk(b"IEND", b""));
        out
    }

    #[test]
    fn text_exif_and_timestamps_are_removed() {
        let original = png(&[
            (b"tEXt", b"Software\0A Phone Camera 4.1"),
            (b"eXIf", b"II*\0GPS"),
            (b"tIME", &[0x07, 0xE8, 1, 2, 3, 4, 5]),
        ]);
        let result = strip_any(&original).expect("should strip");

        let names: Vec<_> = result.removed.iter().map(|r| r.what).collect();
        assert_eq!(names, vec!["text", "EXIF", "timestamp"]);
        assert!(!result.bytes.windows(5).any(|w| w == b"Phone"));
        assert!(!result.bytes.windows(3).any(|w| w == b"GPS"));
        // The image survives, and so does its header.
        assert!(result.bytes.windows(17).any(|w| w == b"compressed pixels"));
        assert!(result.bytes.windows(4).any(|w| w == b"IHDR"));
        assert!(result.bytes.windows(4).any(|w| w == b"IEND"));
    }

    #[test]
    fn the_colour_profile_stays() {
        // Removing it changes the colours the recipient sees. It names a
        // colour space, not a person.
        let original = png(&[(b"iCCP", b"sRGB\0\0compressed profile")]);
        let result = strip_any(&original).expect("should strip");
        assert!(result.was_already_clean(), "{:?}", result.removed);
        assert_eq!(result.bytes, original);
    }

    #[test]
    fn anything_hidden_after_the_end_marker_is_dropped() {
        // IEND ends the image. A decoder stops there, so bytes after it are
        // invisible and travel anyway.
        let mut original = png(&[]);
        let appended = b"a whole other file";
        original.extend_from_slice(appended);

        let result = strip_any(&original).expect("should strip");
        assert_eq!(result.removed.len(), 1);
        assert_eq!(result.removed[0].what, "data after the end of the image");
        assert_eq!(result.removed[0].bytes, appended.len());
        assert!(!result.bytes.windows(5).any(|w| w == b"other"));
    }

    #[test]
    fn a_clean_png_is_returned_byte_for_byte() {
        let original = png(&[]);
        let result = strip_any(&original).expect("should strip");
        assert!(result.was_already_clean());
        assert_eq!(result.bytes, original);
    }

    #[test]
    fn malformed_input_is_an_error_and_never_a_panic() {
        let signature = b"\x89PNG\r\n\x1a\n";

        // Nothing after the signature.
        assert!(strip_any(signature).is_err());

        // A length that runs past the end of the file.
        let mut bad = signature.to_vec();
        bad.extend_from_slice(&[0xFF, 0xFF, 0xFF, 0x00]);
        bad.extend_from_slice(b"IDAT");
        assert!(strip_any(&bad).is_err());

        // A length near `u32::MAX`, which would wrap the total on a 32-bit
        // target and turn a huge chunk into a tiny one.
        let mut bad = signature.to_vec();
        bad.extend_from_slice(&u32::MAX.to_be_bytes());
        bad.extend_from_slice(b"tEXt");
        assert!(strip_any(&bad).is_err());

        // A truncated type field.
        let mut bad = signature.to_vec();
        bad.extend_from_slice(&[0, 0, 0, 0, b'I', b'H']);
        assert!(strip_any(&bad).is_err());
    }
}
