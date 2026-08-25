//! WebP: a RIFF container of four-character chunks.
//!
//! Two things make this one less mechanical than PNG. The container's own
//! length field counts everything after it, so removing a chunk means
//! rewriting it. And an extended WebP begins with a `VP8X` chunk whose flags
//! announce which optional chunks are present — leave the EXIF flag set after
//! removing the EXIF chunk and a decoder is being told to look for something
//! that is no longer there.

use super::{MediaKind, Removed, StripError, Stripped};

const KIND: MediaKind = MediaKind::WebP;
/// `RIFF`, the length, and `WEBP`.
const HEADER: usize = 12;

/// Bits in `VP8X`'s flag byte for the chunks this module removes.
const FLAG_EXIF: u8 = 0b0000_1000;
const FLAG_XMP: u8 = 0b0000_0100;

fn describe(kind: &[u8; 4]) -> Option<&'static str> {
    match kind {
        b"EXIF" => Some("EXIF"),
        b"XMP " => Some("XMP"),
        // ICCP is the colour profile and stays, as it does everywhere else
        // here. ANIM/ANMF/ALPH/VP8 /VP8L/VP8X are the image.
        _ => None,
    }
}

pub(super) fn strip(bytes: &[u8]) -> Result<Stripped, StripError> {
    let mut payload = Vec::with_capacity(bytes.len());
    let mut removed = Vec::new();
    let mut i = HEADER;

    if bytes.len() <= HEADER {
        return Err(StripError::malformed(KIND, "no chunks after the header"));
    }

    while i < bytes.len() {
        let Some(kind) = bytes.get(i..i + 4) else {
            return Err(StripError::malformed(KIND, "truncated chunk type"));
        };
        let kind: [u8; 4] = kind.try_into().expect("checked to be four bytes");

        let Some(size) = bytes
            .get(i + 4..i + 8)
            .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
        else {
            return Err(StripError::malformed(KIND, "truncated chunk size"));
        };

        // Chunks are padded to an even length, and the pad byte is not counted
        // in the size. Checked because the size is four bytes from the file.
        let padded = size + (size & 1);
        let Some(total) = padded.checked_add(8) else {
            return Err(StripError::malformed(KIND, "impossible chunk size"));
        };
        let Some(chunk) = bytes.get(i..i + total) else {
            return Err(StripError::malformed(KIND, "chunk runs past the end"));
        };

        match describe(&kind) {
            Some(what) => removed.push(Removed { what, bytes: total }),
            None => {
                let start = payload.len();
                payload.extend_from_slice(chunk);
                // Correct the announcement of what this file contains, or a
                // decoder goes looking for chunks that have just left.
                if &kind == b"VP8X" {
                    if let Some(flags) = payload.get_mut(start + 8) {
                        *flags &= !(FLAG_EXIF | FLAG_XMP);
                    }
                }
            }
        }

        i += total;
    }

    // RIFF's length covers `WEBP` and everything after it, so it has to be
    // rebuilt around whatever is left.
    let mut out = Vec::with_capacity(HEADER + payload.len());
    out.extend_from_slice(b"RIFF");
    let length = (payload.len() + 4) as u32;
    out.extend_from_slice(&length.to_le_bytes());
    out.extend_from_slice(b"WEBP");
    out.extend_from_slice(&payload);

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

    fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(kind);
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(data);
        if data.len() % 2 == 1 {
            out.push(0);
        }
        out
    }

    fn webp(chunks: &[Vec<u8>]) -> Vec<u8> {
        let payload: Vec<u8> = chunks.concat();
        let mut out = b"RIFF".to_vec();
        out.extend_from_slice(&((payload.len() + 4) as u32).to_le_bytes());
        out.extend_from_slice(b"WEBP");
        out.extend_from_slice(&payload);
        out
    }

    /// A VP8X header announcing EXIF, XMP and a colour profile.
    fn vp8x() -> Vec<u8> {
        let mut data = vec![FLAG_EXIF | FLAG_XMP | 0b0010_0000, 0, 0, 0];
        data.extend_from_slice(&[0; 6]); // canvas size
        chunk(b"VP8X", &data)
    }

    #[test]
    fn exif_and_xmp_are_removed_and_the_length_is_rebuilt() {
        let original = webp(&[
            vp8x(),
            chunk(b"VP8 ", b"the actual picture"),
            chunk(b"EXIF", b"II*\0GPS lives here"),
            chunk(b"XMP ", b"<x:xmpmeta/>"),
        ]);
        let result = strip_any(&original).expect("should strip");

        let names: Vec<_> = result.removed.iter().map(|r| r.what).collect();
        assert_eq!(names, vec!["EXIF", "XMP"]);
        assert!(!result.bytes.windows(3).any(|w| w == b"GPS"));
        assert!(result.bytes.windows(18).any(|w| w == b"the actual picture"));

        // The container length has to match what is left, or the file is
        // truncated or overruns as far as any decoder is concerned.
        let declared = u32::from_le_bytes(result.bytes[4..8].try_into().unwrap());
        assert_eq!(declared as usize, result.bytes.len() - 8);
    }

    #[test]
    fn the_flags_stop_advertising_what_was_removed() {
        let original = webp(&[vp8x(), chunk(b"EXIF", b"II*\0")]);
        let result = strip_any(&original).expect("should strip");

        // VP8X data starts eight bytes into the chunk, which starts at 12.
        let flags = result.bytes[HEADER + 8];
        assert_eq!(flags & FLAG_EXIF, 0, "still claims to carry EXIF");
        assert_eq!(flags & FLAG_XMP, 0, "still claims to carry XMP");
        // The colour-profile flag is untouched, because that chunk stays.
        assert_eq!(flags & 0b0010_0000, 0b0010_0000);
    }

    #[test]
    fn the_colour_profile_chunk_stays() {
        let original = webp(&[chunk(b"ICCP", b"colour profile"), chunk(b"VP8 ", b"pixels")]);
        let result = strip_any(&original).expect("should strip");
        assert!(result.was_already_clean(), "{:?}", result.removed);
        assert_eq!(result.bytes, original);
    }

    #[test]
    fn odd_length_chunks_keep_their_padding() {
        // An odd-sized chunk is followed by a pad byte that its size does not
        // count. Miscounting it shifts every chunk after it.
        let original = webp(&[
            chunk(b"EXIF", b"odd"),
            chunk(b"VP8 ", b"pixels after the padded chunk"),
        ]);
        let result = strip_any(&original).expect("should strip");
        assert_eq!(result.removed.len(), 1);
        assert!(result
            .bytes
            .windows(29)
            .any(|w| w == b"pixels after the padded chunk"));
    }

    #[test]
    fn malformed_input_is_an_error_and_never_a_panic() {
        assert!(strip_any(b"RIFF\0\0\0\0WEBP").is_err());

        // A size that runs past the end.
        let mut bad = b"RIFF\xff\xff\xff\xffWEBP".to_vec();
        bad.extend_from_slice(b"VP8 ");
        bad.extend_from_slice(&u32::MAX.to_le_bytes());
        assert!(strip_any(&bad).is_err());

        // A truncated chunk header.
        let mut bad = b"RIFF\0\0\0\0WEBP".to_vec();
        bad.extend_from_slice(b"VP8");
        assert!(strip_any(&bad).is_err());
    }
}
