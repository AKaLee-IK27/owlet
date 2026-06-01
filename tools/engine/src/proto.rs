//! UDS wire protocol for the Owlet per-keystroke engine.
//!
//! Transport: length-prefixed frames — a 4-byte big-endian payload length followed
//! by a UTF-8 JSON payload. JSON (not a binary codec) is a deliberate choice so the
//! Swift `Host` can encode/decode with `Codable` and no shared codegen (design §6).
//! Messages are internally tagged (`{"type":"Ping"}`) for symmetric Swift decoding.

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

/// Hard cap so a corrupt length prefix can't make us allocate gigabytes.
const MAX_FRAME: usize = 4 * 1024 * 1024;

/// Which tiers the engine should consider for a context update (design §3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Trigger {
    Keystroke,
    WordBoundary,
    Pause,
    Hotkey,
}

/// The cascade tier a suggestion came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Tier {
    Complete,
    Recorrect,
    Sentence,
}

/// A half-open character range `[start, end)` a correction replaces.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Range {
    pub start: u32,
    pub end: u32,
}

/// Host → Engine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum HostMessage {
    /// New caret context. `suffix` is captured for forward-compat but ignored in v1
    /// (prefix-only continuation, design §4). `seq` is monotonic; the engine always
    /// works the latest one.
    ContextUpdate {
        seq: u64,
        prefix: String,
        suffix: String,
        app_id: String,
        trigger: Trigger,
    },
    /// Abort work for sessions older than `seq`.
    Cancel { seq: u64 },
    /// Clean exit.
    Shutdown,
    /// Health check.
    Ping,
}

/// Engine → Host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum EngineMessage {
    Suggestion {
        seq: u64,
        tier: Tier,
        text: String,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        replace_range: Option<Range>,
    },
    Pong,
    Error {
        #[serde(skip_serializing_if = "Option::is_none", default)]
        seq: Option<u64>,
        message: String,
    },
}

/// Serialize a message to its JSON payload bytes.
pub fn encode<T: Serialize>(msg: &T) -> io::Result<Vec<u8>> {
    serde_json::to_vec(msg).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

/// Deserialize a message from JSON payload bytes.
pub fn decode<T: for<'de> Deserialize<'de>>(payload: &[u8]) -> io::Result<T> {
    serde_json::from_slice(payload).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

/// Write one length-prefixed frame and flush it.
pub fn write_frame<W: Write>(w: &mut W, payload: &[u8]) -> io::Result<()> {
    if payload.len() > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    w.write_all(&(payload.len() as u32).to_be_bytes())?;
    w.write_all(payload)?;
    w.flush()
}

/// Read one length-prefixed frame. `Ok(None)` is a clean EOF *at a frame boundary*
/// (peer closed the socket); EOF mid-frame is an `UnexpectedEof` error.
pub fn read_frame<R: Read>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    if !read_filling(r, &mut len_buf)? {
        return Ok(None);
    }
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload)?;
    Ok(Some(payload))
}

/// Encode + frame a message.
pub fn write_msg<W: Write, T: Serialize>(w: &mut W, msg: &T) -> io::Result<()> {
    let payload = encode(msg)?;
    write_frame(w, &payload)
}

/// Read + decode one message. `Ok(None)` on a clean EOF at a frame boundary.
pub fn read_msg<R: Read, T: for<'de> Deserialize<'de>>(r: &mut R) -> io::Result<Option<T>> {
    match read_frame(r)? {
        Some(payload) => Ok(Some(decode(&payload)?)),
        None => Ok(None),
    }
}

/// Like `read_exact`, but distinguishes a clean EOF before any byte (`Ok(false)`)
/// from EOF after a partial read (`Err(UnexpectedEof)`). Retries on `Interrupted`.
fn read_filling<R: Read>(r: &mut R, buf: &mut [u8]) -> io::Result<bool> {
    let mut filled = 0;
    while filled < buf.len() {
        match r.read(&mut buf[filled..]) {
            Ok(0) => {
                return if filled == 0 {
                    Ok(false)
                } else {
                    Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof mid-frame"))
                };
            }
            Ok(n) => filled += n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// A reader that yields at most `chunk` bytes per `read`, to exercise the
    /// partial-read assembly path that real sockets hit.
    struct ChunkReader<'a> {
        data: &'a [u8],
        pos: usize,
        chunk: usize,
    }
    impl Read for ChunkReader<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let remaining = &self.data[self.pos..];
            let n = remaining.len().min(buf.len()).min(self.chunk);
            buf[..n].copy_from_slice(&remaining[..n]);
            self.pos += n;
            Ok(n)
        }
    }

    fn sample_host_messages() -> Vec<HostMessage> {
        vec![
            HostMessage::Ping,
            HostMessage::Shutdown,
            HostMessage::Cancel { seq: 7 },
            HostMessage::ContextUpdate {
                seq: 42,
                prefix: "the quick brown ".into(),
                suffix: " jumps".into(),
                app_id: "com.apple.TextEdit".into(),
                trigger: Trigger::Keystroke,
            },
        ]
    }

    fn sample_engine_messages() -> Vec<EngineMessage> {
        vec![
            EngineMessage::Pong,
            EngineMessage::Suggestion {
                seq: 42,
                tier: Tier::Complete,
                text: "fox".into(),
                replace_range: None,
            },
            EngineMessage::Suggestion {
                seq: 43,
                tier: Tier::Recorrect,
                text: "their".into(),
                replace_range: Some(Range { start: 4, end: 9 }),
            },
            EngineMessage::Error {
                seq: Some(1),
                message: "boom".into(),
            },
        ]
    }

    #[test]
    fn host_messages_round_trip() {
        for msg in sample_host_messages() {
            let bytes = encode(&msg).unwrap();
            let back: HostMessage = decode(&bytes).unwrap();
            assert_eq!(msg, back);
        }
    }

    #[test]
    fn engine_messages_round_trip() {
        for msg in sample_engine_messages() {
            let bytes = encode(&msg).unwrap();
            let back: EngineMessage = decode(&bytes).unwrap();
            assert_eq!(msg, back);
        }
    }

    #[test]
    fn internally_tagged_json_shape() {
        let json = String::from_utf8(encode(&HostMessage::Ping).unwrap()).unwrap();
        assert_eq!(json, r#"{"type":"Ping"}"#);
    }

    #[test]
    fn suggestion_omits_null_range() {
        let json = String::from_utf8(
            encode(&EngineMessage::Suggestion {
                seq: 1,
                tier: Tier::Sentence,
                text: "hi".into(),
                replace_range: None,
            })
            .unwrap(),
        )
        .unwrap();
        assert!(!json.contains("replace_range"), "null range must be omitted: {json}");
    }

    #[test]
    fn frame_write_then_read() {
        let mut buf = Vec::new();
        for msg in sample_host_messages() {
            write_msg(&mut buf, &msg).unwrap();
        }
        let mut cursor = Cursor::new(buf);
        for expected in sample_host_messages() {
            let got: HostMessage = read_msg(&mut cursor).unwrap().unwrap();
            assert_eq!(expected, got);
        }
        // Clean EOF at the frame boundary.
        let trailing: Option<HostMessage> = read_msg(&mut cursor).unwrap();
        assert!(trailing.is_none());
    }

    #[test]
    fn frame_read_survives_byte_at_a_time() {
        let mut buf = Vec::new();
        for msg in sample_engine_messages() {
            write_msg(&mut buf, &msg).unwrap();
        }
        let mut reader = ChunkReader { data: &buf, pos: 0, chunk: 1 };
        for expected in sample_engine_messages() {
            let got: EngineMessage = read_msg(&mut reader).unwrap().unwrap();
            assert_eq!(expected, got);
        }
        let trailing: Option<EngineMessage> = read_msg(&mut reader).unwrap();
        assert!(trailing.is_none());
    }

    #[test]
    fn eof_mid_frame_is_error() {
        // A length prefix promising 10 bytes but only 3 follow.
        let mut buf = 10u32.to_be_bytes().to_vec();
        buf.extend_from_slice(b"abc");
        let mut cursor = Cursor::new(buf);
        let result: io::Result<Option<HostMessage>> = read_msg(&mut cursor);
        assert!(result.is_err());
    }

    #[test]
    fn oversized_frame_rejected() {
        let mut buf = (MAX_FRAME as u32 + 1).to_be_bytes().to_vec();
        buf.push(0);
        let mut cursor = Cursor::new(buf);
        let result: io::Result<Option<HostMessage>> = read_msg(&mut cursor);
        assert!(result.is_err());
    }
}
