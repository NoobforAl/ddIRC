//! Removing everything a file carries beyond its content.
//!
//! A photograph taken on a phone arrives with more than the picture: where it
//! was taken, when, on what, with which lens and which software. None of that
//! is visible, all of it is sent, and a user who shares a holiday snap is not
//! consenting to share their home address because an earlier picture in the
//! same roll was taken there.
//!
//! # Rewritten, never re-encoded
//!
//! Every format here is a container with the image data inside it, so the
//! metadata can be removed by rebuilding the container and copying the image
//! data across untouched. The pixels come out byte-identical.
//!
//! The alternative — decode, then re-encode — would lose quality on every JPEG
//! to delete a text field, and would need an image codec in the dependency
//! tree to do it. Rewriting the container needs neither.
//!
//! # What is deliberately kept
//!
//! Not everything that is not pixels is metadata worth removing. Colour
//! profiles (`iCCP`, JPEG's APP2), the JFIF density header, and Adobe's APP14
//! colour-transform marker all change how the image *renders*: strip them and
//! the recipient sees different colours from the sender. They carry no
//! meaningful information about a person — they name a colour space, of which
//! there are a handful in use — so they stay.
//!
//! What goes is the rest: EXIF, XMP, IPTC/Photoshop blocks, text chunks,
//! comments, and timestamps.
//!
//! # Never panics
//!
//! These parsers are handed whatever the user picked, which includes files
//! that are truncated, mislabelled, or not images at all. Every read is
//! bounds-checked and every malformed input becomes a [`StripError`], because
//! a crash while attaching a file would take the conversation with it.

mod gif;
mod jpeg;
mod png;
mod webp;

/// A container this module can rewrite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Jpeg,
    Png,
    Gif,
    WebP,
}

impl MediaKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Jpeg => "JPEG",
            Self::Png => "PNG",
            Self::Gif => "GIF",
            Self::WebP => "WebP",
        }
    }
}

/// One thing taken out, so the UI can say what was removed rather than
/// claiming a file was cleaned and leaving the user to trust it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Removed {
    /// What it was: `"EXIF"`, `"XMP"`, `"comment"`, and so on.
    pub what: &'static str,
    /// How much of the file it occupied, including its own framing.
    pub bytes: usize,
}

/// The result of cleaning a file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stripped {
    pub kind: MediaKind,
    pub bytes: Vec<u8>,
    /// Everything removed, in the order it appeared.
    pub removed: Vec<Removed>,
}

impl Stripped {
    /// Total bytes removed.
    pub fn removed_bytes(&self) -> usize {
        self.removed.iter().map(|r| r.bytes).sum()
    }

    /// Whether the file had nothing to remove.
    ///
    /// Worth distinguishing from a failure: a screenshot usually carries no
    /// metadata at all, and telling the user it was cleaned when there was
    /// nothing to clean is a claim they cannot check.
    pub fn was_already_clean(&self) -> bool {
        self.removed.is_empty()
    }
}

/// Why a file could not be cleaned.
///
/// Refusing is the safe direction: a file this module does not understand is
/// one whose metadata it cannot promise to have removed, so the caller must
/// decide whether to send it as-is rather than being told it was cleaned.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum StripError {
    #[error("the file is empty")]
    Empty,
    #[error(
        "this is not a JPEG, PNG, GIF or WebP, so its metadata cannot be \
         removed here"
    )]
    Unsupported,
    #[error("the file is not a valid {kind}: {detail}")]
    Malformed {
        kind: &'static str,
        detail: &'static str,
    },
}

impl StripError {
    pub(crate) fn malformed(kind: MediaKind, detail: &'static str) -> Self {
        Self::Malformed {
            kind: kind.as_str(),
            detail,
        }
    }
}

/// Identify a file by its leading bytes.
///
/// By content rather than by extension: the extension is chosen by whoever
/// named the file, and stripping a JPEG as though it were a PNG would either
/// fail or, worse, appear to succeed.
pub fn detect(bytes: &[u8]) -> Option<MediaKind> {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(MediaKind::Jpeg);
    }
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some(MediaKind::Png);
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some(MediaKind::Gif);
    }
    // RIFF is a family; only the WEBP form is one of ours, and it is named
    // four bytes after the container length.
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        return Some(MediaKind::WebP);
    }
    None
}

/// Remove everything but the image.
pub fn strip(bytes: &[u8]) -> Result<Stripped, StripError> {
    if bytes.is_empty() {
        return Err(StripError::Empty);
    }
    match detect(bytes).ok_or(StripError::Unsupported)? {
        MediaKind::Jpeg => jpeg::strip(bytes),
        MediaKind::Png => png::strip(bytes),
        MediaKind::Gif => gif::strip(bytes),
        MediaKind::WebP => webp::strip(bytes),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_are_identified_by_content() {
        assert_eq!(detect(&[0xFF, 0xD8, 0xFF, 0xE0]), Some(MediaKind::Jpeg));
        assert_eq!(detect(b"\x89PNG\r\n\x1a\n...."), Some(MediaKind::Png));
        assert_eq!(detect(b"GIF89a...."), Some(MediaKind::Gif));
        assert_eq!(detect(b"GIF87a...."), Some(MediaKind::Gif));
        assert_eq!(detect(b"RIFF\0\0\0\0WEBPVP8 "), Some(MediaKind::WebP));
    }

    #[test]
    fn other_riff_files_are_not_mistaken_for_webp() {
        // A WAV is RIFF too. Handing one to the WebP path would rewrite a
        // container whose chunks mean something else entirely.
        assert_eq!(detect(b"RIFF\0\0\0\0WAVEfmt "), None);
    }

    #[test]
    fn what_it_cannot_clean_it_refuses() {
        assert_eq!(strip(&[]), Err(StripError::Empty));
        assert_eq!(strip(b"%PDF-1.7"), Err(StripError::Unsupported));
        // Not "cleaned it, found nothing" — that would be a claim the user
        // cannot check about a file we did not understand.
        assert_eq!(strip(b"just some text"), Err(StripError::Unsupported));
    }

    /// A small valid file of each kind, for the sweeps below.
    fn samples() -> Vec<Vec<u8>> {
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08];
        jpeg.extend_from_slice(b"Exif\0\0");
        jpeg.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x02]);
        jpeg.extend_from_slice(b"scan\xFF\xD9");

        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        for (kind, data) in [
            (&b"IHDR"[..], &[0u8; 13][..]),
            (b"tEXt", b"a\0b"),
            (b"IDAT", b"px"),
            (b"IEND", b""),
        ] {
            png.extend_from_slice(&(data.len() as u32).to_be_bytes());
            png.extend_from_slice(kind);
            png.extend_from_slice(data);
            png.extend_from_slice(&[0; 4]);
        }

        let mut gif = b"GIF89a".to_vec();
        gif.extend_from_slice(&[0x10, 0, 0x10, 0, 0x00, 0, 0]);
        gif.extend_from_slice(&[0x21, 0xFE, 3]);
        gif.extend_from_slice(b"hi\0");
        gif.push(0x00);
        gif.push(0x3B);

        let mut webp = b"RIFF".to_vec();
        webp.extend_from_slice(&24u32.to_le_bytes());
        webp.extend_from_slice(b"WEBPEXIF");
        webp.extend_from_slice(&4u32.to_le_bytes());
        webp.extend_from_slice(b"II*\0");
        webp.extend_from_slice(b"VP8 ");
        webp.extend_from_slice(&4u32.to_le_bytes());
        webp.extend_from_slice(b"pix!");

        vec![jpeg, png, gif, webp]
    }

    #[test]
    fn no_truncation_of_a_valid_file_can_panic() {
        // A file cut short at any point is the shape a half-copied or
        // half-downloaded one arrives in, and it must come back as an error.
        // Sweeping every length is cheap and covers every branch that reads
        // ahead — which, in four hand-written parsers, is most of them.
        for sample in samples() {
            for cut in 0..sample.len() {
                let _ = strip(&sample[..cut]);
            }
        }
    }

    #[test]
    fn no_single_byte_corruption_can_panic() {
        // Lengths and offsets are read straight out of the file, so one wrong
        // byte is all it takes to point a parser somewhere absurd. The result
        // may be an error or a strange-but-valid rewrite; it may not be a
        // crash while the user is attaching a photograph.
        for sample in samples() {
            for i in 0..sample.len() {
                for byte in [0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF] {
                    let mut broken = sample.clone();
                    broken[i] = byte;
                    let _ = strip(&broken);
                }
            }
        }
    }

    #[test]
    fn stripping_is_idempotent() {
        // The second pass has nothing left to find. If it did, the first pass
        // missed something — or worse, the first pass produced a file the
        // parser reads differently the second time.
        for sample in samples() {
            let Ok(once) = strip(&sample) else { continue };
            let twice = strip(&once.bytes).expect("output should still parse");
            assert!(
                twice.was_already_clean(),
                "second pass still found {:?}",
                twice.removed
            );
            assert_eq!(twice.bytes, once.bytes, "output changed on a second pass");
        }
    }

    #[test]
    fn a_truncated_header_is_refused_rather_than_panicking() {
        // Every one of these is a plausible mis-selected file.
        for truncated in [
            &b"\xFF\xD8\xFF"[..],
            &b"\x89PNG\r\n\x1a\n"[..],
            &b"GIF89a"[..],
            &b"RIFF\0\0\0\0WEBP"[..],
        ] {
            let result = strip(truncated);
            assert!(result.is_err(), "{truncated:?} should not have parsed");
        }
    }
}
