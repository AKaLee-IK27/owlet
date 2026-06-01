//! `owlet-engine` — the per-keystroke inline-completion sidecar (feat-021).
//!
//! Binds a Unix domain socket, speaks the framed protocol (see `proto`), and answers
//! `ContextUpdate`s with cascade suggestions. v1 implements Tier 0 (instant fst word
//! completion, `tier0_fst`); Tier 1 (symspell) and Tier 2 (llama-cpp-2) are added in
//! later build-order steps (design §9).

mod proto;
mod tier0_fst;

use proto::{EngineMessage, HostMessage, Tier};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use tier0_fst::WordCompleter;

/// macOS `sockaddr_un.sun_path` holds ~104 bytes; bind() silently truncates a longer
/// path, so we fail loud instead (design §5.4).
const SUN_PATH_MAX: usize = 104;

/// Starter English dictionary for Tier 0, compiled into the binary. Expandable; the
/// design leaves personalization to a later step.
const WORDLIST_EN: &str = include_str!("words_en.txt");

fn main() {
    let Some(socket_path) = parse_socket_arg() else {
        eprintln!("usage: owlet-engine --socket <path>");
        std::process::exit(2);
    };
    if let Err(e) = run(&socket_path) {
        eprintln!("owlet-engine: fatal: {e}");
        std::process::exit(1);
    }
}

fn parse_socket_arg() -> Option<String> {
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if let Some(value) = arg.strip_prefix("--socket=") {
            return Some(value.to_string());
        }
        if arg == "--socket" {
            return args.next();
        }
    }
    None
}

fn run(socket_path: &str) -> io::Result<()> {
    if socket_path.len() >= SUN_PATH_MAX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "socket path too long ({} >= {SUN_PATH_MAX} bytes): {socket_path}",
                socket_path.len()
            ),
        ));
    }

    let engine = Engine::new().map_err(|e| {
        io::Error::new(io::ErrorKind::InvalidData, format!("dictionary load failed: {e}"))
    })?;

    // Remove a stale socket file so bind() doesn't fail EADDRINUSE after a hard crash.
    // The Host supervisor also unlinks before respawn (design §5.4); this is the
    // engine-side belt-and-suspenders for a direct relaunch.
    let _ = std::fs::remove_file(socket_path);

    let listener = UnixListener::bind(socket_path)?;
    eprintln!("owlet-engine: listening on {socket_path}");

    // v1 holds a single Host connection at a time. A returning Ok means the peer
    // disconnected or asked to shut down; we accept the next connection.
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(e) = handle_connection(&engine, stream) {
                    eprintln!("owlet-engine: connection ended: {e}");
                }
            }
            Err(e) => eprintln!("owlet-engine: accept error: {e}"),
        }
    }
    Ok(())
}

/// What the protocol loop should do with one decoded message.
enum Action {
    Send(EngineMessage),
    Nothing,
    Stop,
}

struct Engine {
    completer: WordCompleter,
}

impl Engine {
    fn new() -> Result<Self, fst::Error> {
        Ok(Self {
            completer: WordCompleter::from_wordlist(WORDLIST_EN)?,
        })
    }

    fn handle(&self, msg: HostMessage) -> Action {
        match msg {
            HostMessage::Ping => Action::Send(EngineMessage::Pong),
            HostMessage::Shutdown => Action::Stop,
            // No in-flight async work yet (Tier 0 is synchronous) — nothing to cancel.
            HostMessage::Cancel { .. } => Action::Nothing,
            HostMessage::ContextUpdate { seq, prefix, .. } => {
                match self.completer.complete_prefix(&prefix) {
                    Some(text) => Action::Send(EngineMessage::Suggestion {
                        seq,
                        tier: Tier::Complete,
                        text,
                        replace_range: None,
                    }),
                    None => Action::Nothing,
                }
            }
        }
    }
}

fn handle_connection(engine: &Engine, stream: UnixStream) -> io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = BufWriter::new(stream);
    serve(engine, &mut reader, &mut writer)
}

/// The protocol loop, generic over reader/writer so it can be unit-tested without a
/// real socket. Returns `Ok(())` on a clean EOF or an explicit `Shutdown`.
fn serve<R: Read, W: Write>(engine: &Engine, reader: &mut R, writer: &mut W) -> io::Result<()> {
    while let Some(msg) = proto::read_msg::<_, HostMessage>(reader)? {
        match engine.handle(msg) {
            Action::Send(reply) => proto::write_msg(writer, &reply)?,
            Action::Nothing => {}
            Action::Stop => {
                eprintln!("owlet-engine: shutdown requested");
                return Ok(());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto::Trigger;
    use std::io::Cursor;

    fn test_engine() -> Engine {
        Engine {
            completer: WordCompleter::from_pairs([
                ("going".to_string(), 100),
                ("good".to_string(), 90),
                ("hello".to_string(), 70),
            ])
            .unwrap(),
        }
    }

    fn ctx(seq: u64, prefix: &str) -> HostMessage {
        HostMessage::ContextUpdate {
            seq,
            prefix: prefix.to_string(),
            suffix: String::new(),
            app_id: "test".to_string(),
            trigger: Trigger::Keystroke,
        }
    }

    fn responses(engine: &Engine, input: &[HostMessage]) -> Vec<EngineMessage> {
        let mut buf = Vec::new();
        for m in input {
            proto::write_msg(&mut buf, m).unwrap();
        }
        let mut reader = Cursor::new(buf);
        let mut out = Vec::new();
        serve(engine, &mut reader, &mut out).unwrap();
        let mut cursor = Cursor::new(out);
        let mut msgs = Vec::new();
        while let Some(m) = proto::read_msg::<_, EngineMessage>(&mut cursor).unwrap() {
            msgs.push(m);
        }
        msgs
    }

    #[test]
    fn ping_gets_pong() {
        assert_eq!(responses(&test_engine(), &[HostMessage::Ping]), vec![EngineMessage::Pong]);
    }

    #[test]
    fn shutdown_stops_and_drops_later_messages() {
        let out = responses(
            &test_engine(),
            &[HostMessage::Ping, HostMessage::Shutdown, HostMessage::Ping],
        );
        assert_eq!(out, vec![EngineMessage::Pong]);
    }

    #[test]
    fn cancel_produces_no_output() {
        assert!(responses(&test_engine(), &[HostMessage::Cancel { seq: 3 }]).is_empty());
    }

    #[test]
    fn context_update_emits_tier0_completion() {
        let out = responses(&test_engine(), &[ctx(99, "I am goi")]);
        assert_eq!(
            out,
            vec![EngineMessage::Suggestion {
                seq: 99,
                tier: Tier::Complete,
                text: "ng".to_string(),
                replace_range: None,
            }]
        );
    }

    #[test]
    fn context_update_with_no_completion_is_silent() {
        // Trailing space → word finished → no Tier 0 ghost.
        assert!(responses(&test_engine(), &[ctx(1, "I am going ")]).is_empty());
        // Unknown word → no match.
        assert!(responses(&test_engine(), &[ctx(2, "xyzzy")]).is_empty());
    }

    #[test]
    fn embedded_dictionary_loads() {
        // The compiled-in wordlist must parse and answer a common prefix.
        let engine = Engine::new().unwrap();
        let out = responses(&engine, &[ctx(1, "becaus")]);
        assert_eq!(
            out,
            vec![EngineMessage::Suggestion {
                seq: 1,
                tier: Tier::Complete,
                text: "e".to_string(),
                replace_range: None,
            }]
        );
    }
}
