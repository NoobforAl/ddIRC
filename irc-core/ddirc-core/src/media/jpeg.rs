//! JPEG: a chain of marker segments, then the compressed image.
//!
//! Everything before the start-of-scan marker is a sequence of segments, each
//! `FF <marker> <two-byte length> <payload>`. EXIF, XMP, IPTC and comments all
//! live in those segments, so removing them is a matter of copying the chain
//! and leaving some links out. After start-of-scan comes entropy-coded data,
//! which is copied verbatim to the end.

use super::{MediaKind, Removed, StripError, Stripped};

const KIND: MediaKind = MediaKind::Jpeg;

/// Markers that carry no payload and no length field.
///
/// `D0`–`D7` are restart markers, `D8` is start-of-image, `01` is a private
/// no-op. Reading two bytes of length after one of these would consume image
/// data and desynchronise everything that follows.
fn is_standalone(marker: u8) -> bool {
    marker == 0x01 || (0xD0..=0xD8).contains(&marker)
}

/// What an application segment is, if it is one worth keeping.
///
/// APP0 (JFIF) carries pixel density, APP2 carries the ICC colour profile, and
/// APP14 tells a decoder how to interpret the colour channels. Remove any of
/// them and the recipient sees a different image from the sender — which is a
/// change to the content, not the removal of a fact about a person.
fn is_rendering_segment(marker: u8, payload: &[u8]) -> bool {
    match marker {
        // APP0, but only the JFIF form. APP0 has also been used for JFXX
        // thumbnails, which are a picture of where you were.
        0xE0 => payload.starts_with(b"JFIF\0"),
        0xE2 => payload.starts_with(b"ICC_PROFILE\0"),
        0xEE => payload.starts_with(b"Adobe"),
        _ => false,
    }
}

/// What to call a segment we are removing, so the user is told what it was.
fn describe(marker: u8, payload: &[u8]) -> &'static str {
    match marker {
        0xFE => "comment",
        0xE0 => "thumbnail",
        0xE1 if payload.starts_with(b"Exif\0\0") => "EXIF",
        0xE1 if payload.starts_with(b"http://ns.adobe.com/xap/") => "XMP",
        0xE1 => "application data",
        0xED => "Photoshop/IPTC data",
        0xE2 => "multi-picture data",
        _ => "application data",
    }
}

pub(super) fn strip(bytes: &[u8]) -> Result<Stripped, StripError> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut removed = Vec::new();

    // The start-of-image marker, already matched by `detect`.
    out.extend_from_slice(&bytes[..2]);
    let mut i = 2;

    loop {
        // A marker is `FF xx`, and any number of `FF` fill bytes may precede
        // it. Anything else here means the segment chain has desynchronised.
        let start = i;
        while bytes.get(i) == Some(&0xFF) {
            i += 1;
        }
        if i == start {
            return Err(StripError::malformed(KIND, "expected a marker"));
        }
        let Some(&marker) = bytes.get(i) else {
            return Err(StripError::malformed(KIND, "truncated at a marker"));
        };
        i += 1;

        if is_standalone(marker) {
            out.push(0xFF);
            out.push(marker);
            continue;
        }

        let Some(length) = bytes
            .get(i..i + 2)
            .map(|b| u16::from_be_bytes([b[0], b[1]]) as usize)
        else {
            return Err(StripError::malformed(KIND, "truncated segment length"));
        };
        // The length counts itself, so anything under two bytes is nonsense
        // and would make this loop stand still.
        if length < 2 {
            return Err(StripError::malformed(KIND, "impossible segment length"));
        }
        let Some(payload) = bytes.get(i + 2..i + length) else {
            return Err(StripError::malformed(KIND, "segment runs past the end"));
        };

        // Start of scan: the compressed image follows and runs to the end of
        // the file. Nothing in it is metadata, and nothing in it is framed, so
        // it is copied exactly as found.
        if marker == 0xDA {
            out.push(0xFF);
            out.push(marker);
            out.extend_from_slice(&bytes[i..]);
            break;
        }

        let is_metadata = (marker == 0xFE || (0xE0..=0xEF).contains(&marker))
            && !is_rendering_segment(marker, payload);

        if is_metadata {
            removed.push(Removed {
                what: describe(marker, payload),
                // Marker and length included: this is what leaves the file.
                bytes: length + 2,
            });
        } else {
            out.push(0xFF);
            out.push(marker);
            out.extend_from_slice(&bytes[i..i + length]);
        }

        i += length;
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
    use super::*;

    /// Build a JPEG with the given segments between SOI and the scan.
    fn jpeg(segments: &[(u8, &[u8])]) -> Vec<u8> {
        let mut out = vec![0xFF, 0xD8];
        for (marker, payload) in segments {
            out.push(0xFF);
            out.push(*marker);
            let length = (payload.len() + 2) as u16;
            out.extend_from_slice(&length.to_be_bytes());
            out.extend_from_slice(payload);
        }
        // A minimal scan: SOS with an empty header, then "image data", EOI.
        out.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x02]);
        out.extend_from_slice(b"entropy coded data");
        out.extend_from_slice(&[0xFF, 0xD9]);
        out
    }

    const EXIF: &[u8] = b"Exif\0\0II*\0\x08\0\0\0GPS is in here";
    const JFIF: &[u8] = b"JFIF\0\x01\x02\0\0\x01\0\x01\0\0";
    const ICC: &[u8] = b"ICC_PROFILE\0\x01\x01colour data";

    #[test]
    fn exif_is_removed_and_the_image_data_is_not_touched() {
        let original = jpeg(&[(0xE0, JFIF), (0xE1, EXIF)]);
        let result = strip_any(&original).expect("should strip");

        assert!(!result.bytes.windows(4).any(|w| w == b"Exif"));
        assert!(!result.bytes.windows(3).any(|w| w == b"GPS"));
        // The picture itself survives byte for byte.
        assert!(result.bytes.windows(18).any(|w| w == b"entropy coded data"));
        assert_eq!(
            result.removed,
            vec![Removed {
                what: "EXIF",
                bytes: EXIF.len() + 4
            }]
        );
    }

    #[test]
    fn the_things_that_change_how_it_looks_are_kept() {
        // Removing these would alter what the recipient sees, which is not
        // what "strip metadata" is being asked to do.
        let original = jpeg(&[(0xE0, JFIF), (0xE2, ICC), (0xEE, b"Adobe\0d\0\0\0\0")]);
        let result = strip_any(&original).expect("should strip");

        assert!(result.was_already_clean(), "{:?}", result.removed);
        assert_eq!(result.bytes, original);
    }

    #[test]
    fn a_jfxx_thumbnail_is_not_mistaken_for_the_jfif_header() {
        // APP0 is usually the harmless density header, but the JFXX form is a
        // second, smaller copy of the picture — including whatever was in
        // frame, and it survives cropping the main image.
        let original = jpeg(&[(0xE0, b"JFXX\0\x10thumbnail pixels")]);
        let result = strip_any(&original).expect("should strip");

        assert_eq!(result.removed.len(), 1);
        assert_eq!(result.removed[0].what, "thumbnail");
        assert!(!result.bytes.windows(4).any(|w| w == b"JFXX"));
    }

    #[test]
    fn xmp_and_photoshop_blocks_go_too() {
        let xmp = b"http://ns.adobe.com/xap/1.0/\0<x:xmpmeta/>";
        let original = jpeg(&[(0xE1, xmp), (0xED, b"Photoshop 3.0\0 IPTC")]);
        let result = strip_any(&original).expect("should strip");

        let names: Vec<_> = result.removed.iter().map(|r| r.what).collect();
        assert_eq!(names, vec!["XMP", "Photoshop/IPTC data"]);
        assert!(!result.bytes.windows(9).any(|w| w == b"xmpmeta/>"));
        assert!(!result.bytes.windows(4).any(|w| w == b"IPTC"));
    }

    #[test]
    fn comments_go() {
        let original = jpeg(&[(0xFE, b"taken at home")]);
        let result = strip_any(&original).expect("should strip");
        assert_eq!(result.removed[0].what, "comment");
        assert!(!result.bytes.windows(4).any(|w| w == b"home"));
    }

    #[test]
    fn a_file_with_nothing_to_remove_comes_back_identical() {
        let original = jpeg(&[]);
        let result = strip_any(&original).expect("should strip");
        assert!(result.was_already_clean());
        assert_eq!(result.bytes, original);
        assert_eq!(result.removed_bytes(), 0);
    }

    #[test]
    fn restart_markers_do_not_desynchronise_the_chain() {
        // These carry no length. Reading two bytes of length after one would
        // swallow whatever followed and corrupt the rest of the file.
        let mut original = vec![0xFF, 0xD8, 0xFF, 0xD0, 0xFF, 0xD1];
        original.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x02]);
        original.extend_from_slice(b"scan");
        let result = strip_any(&original).expect("should strip");
        assert_eq!(result.bytes, original);
    }

    #[test]
    fn fill_bytes_before_a_marker_are_tolerated() {
        // Padding with FF is legal and some encoders emit it.
        let mut original = vec![0xFF, 0xD8, 0xFF, 0xFF, 0xFF];
        original.extend_from_slice(&[0xDA, 0x00, 0x02]);
        original.extend_from_slice(b"scan");
        let result = strip_any(&original).expect("should strip");
        assert!(result.bytes.windows(4).any(|w| w == b"scan"));
    }

    #[test]
    fn malformed_input_is_an_error_and_never_a_panic() {
        for (bad, why) in [
            (vec![0xFF, 0xD8, 0xFF], "truncated at a marker"),
            (vec![0xFF, 0xD8, 0xFF, 0xE1, 0x00], "truncated length"),
            // A length under two would leave the cursor where it was.
            (
                vec![0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x01],
                "impossible length",
            ),
            (
                vec![0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 0x00],
                "runs past the end",
            ),
            (vec![0xFF, 0xD8, 0x12, 0x34], "not a marker"),
        ] {
            assert!(strip_any(&bad).is_err(), "{why}: {bad:?} should not parse");
        }
    }
}
