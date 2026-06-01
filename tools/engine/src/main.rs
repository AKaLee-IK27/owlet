//! `owlet-engine` — the per-keystroke inline-completion sidecar (feat-021).
//!
//! Binds a Unix domain socket, speaks the framed protocol (see `proto`), and answers
//! `ContextUpdate`s with cascade suggestions. v1 implements Tier 0 (instant fst word
//! completion, `tier0_fst`); Tier 1 (symspell) and Tier 2 (llama-cpp-2) are added in
//! later build-order steps (design §9).

mod proto;
mod tier0_fst;
mod tier1_symspell;
#[cfg(feature = "tier2")]
mod tier2_llm;

use proto::{EngineMessage, HostMessage, Range, Tier, Trigger};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use tier0_fst::WordCompleter;
use tier1_symspell::SpellCorrector;

/// macOS `sockaddr_un.sun_path` holds ~104 bytes; bind() silently truncates a longer
/// path, so we fail loud instead (design §5.4).
const SUN_PATH_MAX: usize = 104;

/// Starter English dictionary for Tier 0, compiled into the binary. Expandable; the
/// design leaves personalization to a later step.
const WORDLIST_EN: &str = include_str!("words_en.txt");

fn main() {
    let Some(args) = parse_args() else {
        eprintln!("usage: owlet-engine --socket <path> [--model <gguf>] [--no-kv-cache]");
        std::process::exit(2);
    };
    if let Err(e) = run(&args) {
        eprintln!("owlet-engine: fatal: {e}");
        std::process::exit(1);
    }
}

struct Args {
    socket: String,
    /// GGUF path for Tier 2. Read only by the `tier2` model thread.
    #[allow(dead_code)]
    model: Option<String>,
    /// Force full re-encode (the KV-cache correctness oracle, design §10). `tier2` only.
    #[allow(dead_code)]
    no_kv_cache: bool,
}

fn parse_args() -> Option<Args> {
    let mut socket: Option<String> = None;
    let mut model: Option<String> = None;
    let mut no_kv_cache = false;
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        if arg == "--socket" {
            socket = it.next();
        } else if let Some(value) = arg.strip_prefix("--socket=") {
            socket = Some(value.to_string());
        } else if arg == "--model" {
            model = it.next();
        } else if let Some(value) = arg.strip_prefix("--model=") {
            model = Some(value.to_string());
        } else if arg == "--no-kv-cache" {
            no_kv_cache = true;
        }
    }
    socket.map(|socket| Args { socket, model, no_kv_cache })
}

fn run(args: &Args) -> io::Result<()> {
    let socket_path = &args.socket;
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
                if let Err(e) = handle_connection(&engine, stream, args) {
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
    corrector: SpellCorrector,
}

impl Engine {
    fn new() -> Result<Self, fst::Error> {
        Ok(Self {
            completer: WordCompleter::from_wordlist(WORDLIST_EN)?,
            corrector: SpellCorrector::from_wordlist(WORDLIST_EN),
        })
    }

    fn handle(&self, msg: HostMessage) -> Action {
        match msg {
            HostMessage::Ping => Action::Send(EngineMessage::Pong),
            HostMessage::Shutdown => Action::Stop,
            // Tiers are synchronous today — nothing in flight to cancel (the Tier 2
            // model loop and its cancel flag arrive with llama-cpp-2).
            HostMessage::Cancel { .. } => Action::Nothing,
            HostMessage::ContextUpdate { seq, prefix, trigger, .. } => {
                self.suggest(seq, &prefix, trigger)
            }
        }
    }

    /// Pick the tier by trigger: a word boundary asks Tier 1 to recorrect the word the
    /// user just finished; any other trigger asks Tier 0 to complete the current word.
    /// (Tier 2 on `Pause` lands with llama-cpp-2.)
    fn suggest(&self, seq: u64, prefix: &str, trigger: Trigger) -> Action {
        match trigger {
            Trigger::WordBoundary => match self.corrector.correct_last_word(prefix) {
                Some(correction) => Action::Send(EngineMessage::Suggestion {
                    seq,
                    tier: Tier::Recorrect,
                    text: correction.text,
                    replace_range: Some(Range { start: correction.start, end: correction.end }),
                }),
                None => Action::Nothing,
            },
            _ => match self.completer.complete_prefix(prefix) {
                Some(text) => Action::Send(EngineMessage::Suggestion {
                    seq,
                    tier: Tier::Complete,
                    text,
                    replace_range: None,
                }),
                None => Action::Nothing,
            },
        }
    }
}

#[cfg(not(feature = "tier2"))]
fn handle_connection(engine: &Engine, stream: UnixStream, _args: &Args) -> io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = BufWriter::new(stream);
    serve(engine, &mut reader, &mut writer)
}

/// Tier-2 connection handling: Tier 0/1 stay synchronous on this thread; Tier 2 (Pause/
/// Hotkey) is dispatched to a dedicated model thread and answered asynchronously. The
/// socket writer is shared behind a mutex so both threads can emit frames without
/// interleaving. `latest_seq` coalesces/cancels Tier-2 work (newest request wins).
#[cfg(feature = "tier2")]
fn handle_connection(engine: &Engine, stream: UnixStream, args: &Args) -> io::Result<()> {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};

    let mut reader = BufReader::new(stream.try_clone()?);
    let writer = Arc::new(Mutex::new(BufWriter::new(stream)));
    let latest_seq = Arc::new(AtomicU64::new(0));

    // Spawn the model thread only when a model path was supplied.
    let job_tx = args.model.clone().map(|model_path| {
        let (tx, rx) = std::sync::mpsc::channel::<tier2_llm::Job>();
        let writer = Arc::clone(&writer);
        let latest_seq = Arc::clone(&latest_seq);
        let no_kv_cache = args.no_kv_cache;
        std::thread::spawn(move || {
            tier2_llm::run_model_thread(model_path, no_kv_cache, rx, latest_seq, move |msg| {
                if let Ok(mut guard) = writer.lock() {
                    let _ = proto::write_msg(&mut *guard, &msg);
                }
            });
        });
        tx
    });

    while let Some(msg) = proto::read_msg::<_, HostMessage>(&mut reader)? {
        match msg {
            HostMessage::Ping => {
                let mut guard = writer.lock().unwrap();
                proto::write_msg(&mut *guard, &EngineMessage::Pong)?;
            }
            HostMessage::Shutdown => break,
            HostMessage::Cancel { seq } => {
                latest_seq.store(seq, Ordering::SeqCst); // supersede any in-flight Tier 2
            }
            HostMessage::ContextUpdate { seq, prefix, trigger, .. } => match trigger {
                Trigger::Pause | Trigger::Hotkey => {
                    latest_seq.store(seq, Ordering::SeqCst);
                    if let Some(tx) = &job_tx {
                        let _ = tx.send(tier2_llm::Job { seq, prefix });
                    }
                }
                _ => {
                    if let Action::Send(reply) = engine.suggest(seq, &prefix, trigger) {
                        let mut guard = writer.lock().unwrap();
                        proto::write_msg(&mut *guard, &reply)?;
                    }
                }
            },
        }
    }
    Ok(())
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
            corrector: SpellCorrector::from_pairs([
                ("hello".to_string(), 100),
                ("world".to_string(), 90),
            ]),
        }
    }

    fn ctx(seq: u64, prefix: &str) -> HostMessage {
        ctx_trigger(seq, prefix, Trigger::Keystroke)
    }

    fn ctx_trigger(seq: u64, prefix: &str, trigger: Trigger) -> HostMessage {
        HostMessage::ContextUpdate {
            seq,
            prefix: prefix.to_string(),
            suffix: String::new(),
            app_id: "test".to_string(),
            trigger,
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
    fn word_boundary_emits_tier1_recorrection() {
        // "helo" → "hello" on a word boundary, replacing the misspelled span.
        let out = responses(&test_engine(), &[ctx_trigger(5, "say helo ", Trigger::WordBoundary)]);
        assert_eq!(
            out,
            vec![EngineMessage::Suggestion {
                seq: 5,
                tier: Tier::Recorrect,
                text: "hello".to_string(),
                replace_range: Some(Range { start: 4, end: 8 }),
            }]
        );
    }

    #[test]
    fn word_boundary_silent_when_correctly_spelled() {
        assert!(responses(&test_engine(), &[ctx_trigger(1, "hello ", Trigger::WordBoundary)]).is_empty());
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
