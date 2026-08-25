//! GIF: a header, then a stream of blocks ending in a trailer.
//!
//! The awkward part is that most block payloads are not length-prefixed as a
//! whole. They are a chain of sub-blocks, each a single length byte followed
//! by that many bytes, ending with a zero. Everything here has to walk that
//! chain rather than skip a known distance.
//!
//! Two extensions carry metadata: the comment extension, and the application
//! extension when it holds XMP. The application extension is also how looping
//! is declared, so it cannot be dropped wholesale — an animation that stops
//! after one pass is a changed image, not a cleaned one.

use super::{MediaKind, Removed, StripError, Stripped};

const KIND: MediaKind = MediaKind::Gif;
/// Signature, version, logical screen descriptor.
const HEADER: usize = 13;

const EXTENSION: u8 = 0x21;
const IMAGE: u8 = 0x2C;
const TRAILER: u8 = 0x3B;
const COMMENT: u8 = 0xFE;
const APPLICATION: u8 = 0xFF;

/// Walk a chain of sub-blocks and return where it ends.
///
/// The chain runs until a zero-length block. A file that ends mid-chain has no
/// terminator, which is malformed rather than merely short.
fn end_of_sub_blocks(bytes: &[u8], mut i: usize) -> Result<usize, StripError> {
    loop {
        let Some(&len) = bytes.get(i) else {
            return Err(StripError::malformed(KIND, "unterminated block"));
        };
        i += 1;
        if len == 0 {
            return Ok(i);
        }
        i += len as usize;
        if i > bytes.len() {
            return Err(StripError::malformed(KIND, "block runs past the end"));
        }
    }
}

pub(super) fn strip(bytes: &[u8]) -> Result<Stripped, StripError> {
    if bytes.len() <= HEADER {
        return Err(StripError::malformed(KIND, "truncated header"));
    }

    let mut out = Vec::with_capacity(bytes.len());
    let mut removed = Vec::new();

    // The screen descriptor's packed field says whether a global colour table
    // follows, and how big it is: 3 * 2^(n+1) bytes.
    let packed = bytes[10];
    let mut i = HEADER;
    if packed & 0b1000_0000 != 0 {
        let size = 3 * (1usize << ((packed & 0b0000_0111) + 1));
        i += size;
        if i > bytes.len() {
            return Err(StripError::malformed(
                KIND,
                "colour table runs past the end",
            ));
        }
    }
    out.extend_from_slice(&bytes[..i]);

    loop {
        let Some(&block) = bytes.get(i) else {
            return Err(StripError::malformed(KIND, "ended without a trailer"));
        };

        match block {
            TRAILER => {
                out.push(TRAILER);
                i += 1;
                // As with PNG's end marker, a decoder stops here and anything
                // after it rides along unseen.
                if i < bytes.len() {
                    removed.push(Removed {
                        what: "data after the end of the image",
                        bytes: bytes.len() - i,
                    });
                }
                break;
            }

            EXTENSION => {
                let Some(&label) = bytes.get(i + 1) else {
                    return Err(StripError::malformed(KIND, "truncated extension"));
                };
                let body = i + 2;

                // The application extension's first sub-block names it. The
                // looping declaration lives here too, so this cannot simply
                // drop every one it finds.
                let is_xmp = label == APPLICATION
                    && bytes
                        .get(body + 1..body + 12)
                        .is_some_and(|id| id == b"XMP DataXMP");

                let end = end_of_sub_blocks(bytes, body)?;
                if label == COMMENT || is_xmp {
                    removed.push(Removed {
                        what: if label == COMMENT { "comment" } else { "XMP" },
                        bytes: end - i,
                    });
                } else {
                    out.extend_from_slice(&bytes[i..end]);
                }
                i = end;
            }

            IMAGE => {
                // Descriptor is ten bytes, the last of which says whether a
                // local colour table follows.
                let Some(&packed) = bytes.get(i + 9) else {
                    return Err(StripError::malformed(KIND, "truncated image descriptor"));
                };
                let mut data = i + 10;
                if packed & 0b1000_0000 != 0 {
                    data += 3 * (1usize << ((packed & 0b0000_0111) + 1));
                }
                // One byte of LZW minimum code size, then the pixel chain.
                if data >= bytes.len() {
                    return Err(StripError::malformed(KIND, "truncated image data"));
                }
                let end = end_of_sub_blocks(bytes, data + 1)?;
                out.extend_from_slice(&bytes[i..end]);
                i = end;
            }

            _ => return Err(StripError::malformed(KIND, "unknown block")),
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
    use super::*;

    /// Wrap bytes as a chain of sub-blocks.
    fn sub_blocks(data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        for piece in data.chunks(255) {
            out.push(piece.len() as u8);
            out.extend_from_slice(piece);
        }
        out.push(0);
        out
    }

    fn header() -> Vec<u8> {
        // No global colour table, to keep the fixtures readable.
        let mut out = b"GIF89a".to_vec();
        out.extend_from_slice(&[0x10, 0, 0x10, 0, 0x00, 0, 0]);
        out
    }

    fn image() -> Vec<u8> {
        let mut out = vec![IMAGE];
        out.extend_from_slice(&[0, 0, 0, 0, 0x10, 0, 0x10, 0, 0x00]);
        out.push(0x02); // LZW minimum code size
        out.extend_from_slice(&sub_blocks(b"pixel data"));
        out
    }

    fn extension(label: u8, body: &[u8]) -> Vec<u8> {
        let mut out = vec![EXTENSION, label];
        out.extend_from_slice(&sub_blocks(body));
        out
    }

    /// The looping declaration every animated GIF carries.
    fn netscape() -> Vec<u8> {
        let mut out = vec![EXTENSION, APPLICATION];
        out.push(11);
        out.extend_from_slice(b"NETSCAPE2.0");
        out.extend_from_slice(&[3, 1, 0, 0, 0]);
        out
    }

    fn gif(blocks: &[Vec<u8>]) -> Vec<u8> {
        let mut out = header();
        for block in blocks {
            out.extend_from_slice(block);
        }
        out.push(TRAILER);
        out
    }

    #[test]
    fn comments_are_removed_and_the_pixels_are_not() {
        let original = gif(&[extension(COMMENT, b"made at home on Tuesday"), image()]);
        let result = strip_any(&original).expect("should strip");

        assert_eq!(result.removed.len(), 1);
        assert_eq!(result.removed[0].what, "comment");
        assert!(!result.bytes.windows(4).any(|w| w == b"home"));
        assert!(result.bytes.windows(10).any(|w| w == b"pixel data"));
        assert_eq!(result.bytes.last(), Some(&TRAILER));
    }

    #[test]
    fn xmp_goes_but_the_looping_declaration_stays() {
        // Both are application extensions. Dropping the pair would leave an
        // animation that plays once - a changed image, not a cleaned one.
        let mut xmp = vec![EXTENSION, APPLICATION];
        xmp.push(11);
        xmp.extend_from_slice(b"XMP DataXMP");
        xmp.extend_from_slice(&sub_blocks(b"<x:xmpmeta/>"));

        let original = gif(&[netscape(), xmp, image()]);
        let result = strip_any(&original).expect("should strip");

        assert_eq!(result.removed.len(), 1);
        assert_eq!(result.removed[0].what, "XMP");
        assert!(result.bytes.windows(11).any(|w| w == b"NETSCAPE2.0"));
        assert!(!result.bytes.windows(9).any(|w| w == b"xmpmeta/>"));
    }

    #[test]
    fn graphic_control_extensions_are_left_alone() {
        // Frame timing and transparency. Not metadata, and removing it breaks
        // the animation.
        let original = gif(&[extension(0xF9, &[0x04, 0x0A, 0x00, 0x00]), image()]);
        let result = strip_any(&original).expect("should strip");
        assert!(result.was_already_clean(), "{:?}", result.removed);
        assert_eq!(result.bytes, original);
    }

    #[test]
    fn a_global_colour_table_is_carried_across() {
        let mut original = b"GIF89a".to_vec();
        // Global table present, size bits 001 -> 3 * 2^2 = 12 bytes.
        original.extend_from_slice(&[0x10, 0, 0x10, 0, 0b1000_0001, 0, 0]);
        original.extend_from_slice(&[0xAB; 12]);
        original.extend_from_slice(&extension(COMMENT, b"secret"));
        original.extend_from_slice(&image());
        original.push(TRAILER);

        let result = strip_any(&original).expect("should strip");
        assert_eq!(result.removed[0].what, "comment");
        assert!(result.bytes.windows(12).any(|w| w == [0xAB; 12]));
        assert!(!result.bytes.windows(6).any(|w| w == b"secret"));
    }

    #[test]
    fn anything_after_the_trailer_is_dropped() {
        let mut original = gif(&[image()]);
        original.extend_from_slice(b"stowaway");
        let result = strip_any(&original).expect("should strip");
        assert_eq!(result.removed[0].what, "data after the end of the image");
        assert!(!result.bytes.windows(8).any(|w| w == b"stowaway"));
    }

    #[test]
    fn malformed_input_is_an_error_and_never_a_panic() {
        assert!(strip_any(b"GIF89a").is_err());

        // A sub-block chain with no terminator.
        let mut bad = header();
        bad.extend_from_slice(&[EXTENSION, COMMENT, 5]);
        bad.extend_from_slice(b"short");
        assert!(strip_any(&bad).is_err());

        // A colour table larger than the file.
        let mut bad = b"GIF89a".to_vec();
        bad.extend_from_slice(&[0x10, 0, 0x10, 0, 0b1000_0111, 0, 0]);
        assert!(strip_any(&bad).is_err());

        // A block type that is not one of the three.
        let mut bad = header();
        bad.push(0x99);
        assert!(strip_any(&bad).is_err());

        // No trailer at all.
        let mut bad = header();
        bad.extend_from_slice(&image());
        assert!(strip_any(&bad).is_err());
    }
}
