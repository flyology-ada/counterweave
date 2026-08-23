//! Replayable, structurally independent random choice forks.

use std::collections::BTreeMap;
use std::fmt;

use rand::{RngCore, SeedableRng};
use rand_chacha::ChaCha8Rng;
use serde::{Deserialize, Serialize};
use thiserror::Error;

const TAPE_FORMAT: &str = "counterweave.choices/1";

/// One component of a named, indexed fork path.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
pub struct ForkSegment {
    /// Domain label for the child stream.
    pub label: String,
    /// Stable index when several children share the same label.
    pub index: u64,
}

/// Stable identity of one independent choice stream.
#[derive(Clone, Debug, Default, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ForkPath(Vec<ForkSegment>);

impl ForkPath {
    /// Return the root path.
    #[must_use]
    pub const fn root() -> Self {
        Self(Vec::new())
    }

    /// Return a child path without modifying this path.
    #[must_use]
    pub fn child(&self, label: impl Into<String>, index: u64) -> Self {
        let mut segments = self.0.clone();
        segments.push(ForkSegment {
            label: label.into(),
            index,
        });
        Self(segments)
    }

    /// Return the path components.
    #[must_use]
    pub fn segments(&self) -> &[ForkSegment] {
        &self.0
    }
}

impl fmt::Display for ForkPath {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            return formatter.write_str("root");
        }
        for (position, segment) in self.0.iter().enumerate() {
            if position > 0 {
                formatter.write_str("/")?;
            }
            write!(formatter, "{}[{}]", segment.label, segment.index)?;
        }
        Ok(())
    }
}

/// Choices consumed by one fork.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ForkRecord {
    /// Stable fork identity.
    pub path: ForkPath,
    /// Raw choices in consumption order.
    pub values: Vec<u64>,
}

/// Complete replay material for one generation or execution attempt.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ChoiceTape {
    /// Artifact format identifier.
    pub format: String,
    /// Root seed from which recording forks were derived.
    pub root_seed: u64,
    /// Recorded choice streams, ordered by fork path.
    pub forks: Vec<ForkRecord>,
}

impl ChoiceTape {
    /// Return a new replay session over this tape.
    ///
    /// # Errors
    ///
    /// Returns an error when the artifact format is unsupported or a fork path
    /// occurs more than once.
    pub fn replay(&self) -> Result<ChoiceSession, ChoiceError> {
        if self.format != TAPE_FORMAT {
            return Err(ChoiceError::UnsupportedFormat(self.format.clone()));
        }

        let mut states = BTreeMap::new();
        for record in &self.forks {
            if states
                .insert(
                    record.path.clone(),
                    ForkState::Replay {
                        values: record.values.clone(),
                        position: 0,
                    },
                )
                .is_some()
            {
                return Err(ChoiceError::DuplicateFork(record.path.clone()));
            }
        }

        Ok(ChoiceSession {
            root_seed: self.root_seed,
            mode: SessionMode::Replay,
            states,
        })
    }
}

/// A recording or replaying collection of named choice forks.
pub struct ChoiceSession {
    root_seed: u64,
    mode: SessionMode,
    states: BTreeMap<ForkPath, ForkState>,
}

#[derive(Clone, Copy)]
enum SessionMode {
    Recording,
    Replay,
}

enum ForkState {
    Recording {
        rng: Box<ChaCha8Rng>,
        values: Vec<u64>,
    },
    Replay {
        values: Vec<u64>,
        position: usize,
    },
}

impl ChoiceSession {
    /// Start recording choices under `root_seed`.
    #[must_use]
    pub fn recording(root_seed: u64) -> Self {
        Self {
            root_seed,
            mode: SessionMode::Recording,
            states: BTreeMap::new(),
        }
    }

    /// Borrow a named fork.
    ///
    /// Recording forks are independent: their stream is derived solely from
    /// the root seed and path, so consuming one fork does not shift another.
    ///
    /// # Errors
    ///
    /// Replay fails if the requested fork was not present in the tape.
    pub fn fork(&mut self, path: &ForkPath) -> Result<ChoiceFork<'_>, ChoiceError> {
        if matches!(self.mode, SessionMode::Recording) && !self.states.contains_key(path) {
            let seed = derive_seed(self.root_seed, path);
            self.states.insert(
                path.clone(),
                ForkState::Recording {
                    rng: Box::new(ChaCha8Rng::seed_from_u64(seed)),
                    values: Vec::new(),
                },
            );
        }

        let state = self
            .states
            .get_mut(path)
            .ok_or_else(|| ChoiceError::MissingFork(path.clone()))?;
        Ok(ChoiceFork {
            path: path.clone(),
            state,
        })
    }

    /// Finish the session and return its complete tape.
    ///
    /// # Errors
    ///
    /// Replay sessions fail when any recorded choice was left unused.
    pub fn finish(self) -> Result<ChoiceTape, ChoiceError> {
        let mut forks = Vec::with_capacity(self.states.len());
        for (path, state) in self.states {
            match state {
                ForkState::Recording { values, .. } => forks.push(ForkRecord { path, values }),
                ForkState::Replay { values, position } => {
                    if position != values.len() {
                        return Err(ChoiceError::UnusedChoices {
                            path,
                            remaining: values.len() - position,
                        });
                    }
                    forks.push(ForkRecord { path, values });
                }
            }
        }
        Ok(ChoiceTape {
            format: TAPE_FORMAT.to_owned(),
            root_seed: self.root_seed,
            forks,
        })
    }
}

/// Mutable access to one independent choice stream.
pub struct ChoiceFork<'a> {
    path: ForkPath,
    state: &'a mut ForkState,
}

impl ChoiceFork<'_> {
    /// Draw one raw 64-bit choice.
    ///
    /// # Errors
    ///
    /// Replay fails when the recorded fork is exhausted.
    pub fn draw(&mut self) -> Result<u64, ChoiceError> {
        match self.state {
            ForkState::Recording { rng, values } => {
                let value = rng.next_u64();
                values.push(value);
                Ok(value)
            }
            ForkState::Replay { values, position } => {
                let value = values
                    .get(*position)
                    .copied()
                    .ok_or_else(|| ChoiceError::Exhausted(self.path.clone()))?;
                *position += 1;
                Ok(value)
            }
        }
    }

    /// Draw uniformly from the inclusive range `0..=maximum`.
    ///
    /// # Errors
    ///
    /// Returns the same replay errors as [`Self::draw`].
    pub fn draw_bounded(&mut self, maximum: u64) -> Result<u64, ChoiceError> {
        if maximum == u64::MAX {
            return self.draw();
        }
        let range = maximum + 1;
        let rejection_limit = u64::MAX - (u64::MAX % range);
        loop {
            let value = self.draw()?;
            if value < rejection_limit {
                return Ok(value % range);
            }
        }
    }

    /// Draw one Boolean choice.
    ///
    /// # Errors
    ///
    /// Returns the same replay errors as [`Self::draw`].
    pub fn draw_bool(&mut self) -> Result<bool, ChoiceError> {
        Ok(self.draw()? & 1 == 1)
    }
}

/// Choice recording or replay failure.
#[derive(Debug, Error)]
pub enum ChoiceError {
    /// The requested fork was absent from a replay tape.
    #[error("choice fork `{0}` is missing from replay tape")]
    MissingFork(ForkPath),
    /// A replay requested more choices than a fork recorded.
    #[error("choice fork `{0}` is exhausted")]
    Exhausted(ForkPath),
    /// Replay did not consume the complete fork.
    #[error("choice fork `{path}` has {remaining} unused choices")]
    UnusedChoices {
        /// Fork with unused data.
        path: ForkPath,
        /// Number of remaining values.
        remaining: usize,
    },
    /// A serialized tape repeated one path.
    #[error("choice tape contains duplicate fork `{0}`")]
    DuplicateFork(ForkPath),
    /// The serialized format is not supported.
    #[error("unsupported choice tape format `{0}`")]
    UnsupportedFormat(String),
}

fn derive_seed(root_seed: u64, path: &ForkPath) -> u64 {
    // Stable FNV-1a domain separation followed by SplitMix64 diffusion. This
    // deliberately does not depend on Rust's unspecified DefaultHasher.
    let mut hash = 0xcbf2_9ce4_8422_2325_u64 ^ root_seed;
    for segment in path.segments() {
        for byte in segment.label.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        for byte in segment.index.to_le_bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    splitmix64(hash)
}

const fn splitmix64(mut value: u64) -> u64 {
    value = value.wrapping_add(0x9e37_79b9_7f4a_7c15);
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    value ^ (value >> 31)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn actor(index: u64) -> ForkPath {
        ForkPath::root().child("case", 7).child("actor", index)
    }

    #[test]
    fn the_same_seed_and_path_reproduce_choices() {
        let path = actor(1);
        let mut first = ChoiceSession::recording(42);
        let first_values = {
            let mut fork = first.fork(&path).unwrap();
            vec![fork.draw().unwrap(), fork.draw().unwrap()]
        };

        let mut second = ChoiceSession::recording(42);
        let second_values = {
            let mut fork = second.fork(&path).unwrap();
            vec![fork.draw().unwrap(), fork.draw().unwrap()]
        };
        assert_eq!(first_values, second_values);
    }

    #[test]
    fn sibling_consumption_does_not_shift_a_fork() {
        let mut with_sibling = ChoiceSession::recording(99);
        let _ = with_sibling.fork(&actor(1)).unwrap().draw().unwrap();
        let actor_two_after_sibling = with_sibling.fork(&actor(2)).unwrap().draw().unwrap();

        let mut alone = ChoiceSession::recording(99);
        let actor_two_alone = alone.fork(&actor(2)).unwrap().draw().unwrap();
        assert_eq!(actor_two_after_sibling, actor_two_alone);
    }

    #[test]
    fn a_tape_replays_exact_consumption() {
        let path = actor(3);
        let mut recording = ChoiceSession::recording(8_675_309);
        let expected = {
            let mut fork = recording.fork(&path).unwrap();
            vec![
                fork.draw_bounded(12).unwrap(),
                fork.draw_bounded(12).unwrap(),
            ]
        };
        let tape = recording.finish().unwrap();

        let mut replay = tape.replay().unwrap();
        let actual = {
            let mut fork = replay.fork(&path).unwrap();
            vec![
                fork.draw_bounded(12).unwrap(),
                fork.draw_bounded(12).unwrap(),
            ]
        };
        replay.finish().unwrap();
        assert_eq!(expected, actual);
    }

    #[test]
    fn replay_fails_closed_on_unused_choices() {
        let path = actor(4);
        let mut recording = ChoiceSession::recording(1);
        {
            let mut fork = recording.fork(&path).unwrap();
            let _ = fork.draw().unwrap();
            let _ = fork.draw().unwrap();
        }
        let tape = recording.finish().unwrap();

        let mut replay = tape.replay().unwrap();
        let _ = replay.fork(&path).unwrap().draw().unwrap();
        assert!(matches!(
            replay.finish(),
            Err(ChoiceError::UnusedChoices { remaining: 1, .. })
        ));
    }

    #[test]
    fn replay_fails_closed_on_missing_and_exhausted_forks() {
        let recorded_path = actor(5);
        let missing_path = actor(6);
        let mut recording = ChoiceSession::recording(2);
        let _ = recording.fork(&recorded_path).unwrap().draw().unwrap();
        let tape = recording.finish().unwrap();

        let mut replay = tape.replay().unwrap();
        assert!(matches!(
            replay.fork(&missing_path),
            Err(ChoiceError::MissingFork(path)) if path == missing_path
        ));
        let mut fork = replay.fork(&recorded_path).unwrap();
        let _ = fork.draw().unwrap();
        assert!(matches!(fork.draw(), Err(ChoiceError::Exhausted(path)) if path == recorded_path));
    }

    #[test]
    fn replay_rejects_duplicate_forks_and_unknown_formats() {
        let path = actor(7);
        let record = ForkRecord {
            path: path.clone(),
            values: vec![1],
        };
        let duplicate = ChoiceTape {
            format: TAPE_FORMAT.to_owned(),
            root_seed: 3,
            forks: vec![record.clone(), record],
        };
        assert!(matches!(
            duplicate.replay(),
            Err(ChoiceError::DuplicateFork(duplicate_path)) if duplicate_path == path
        ));

        let unknown = ChoiceTape {
            format: "counterweave.choices/999".to_owned(),
            root_seed: 3,
            forks: Vec::new(),
        };
        assert!(matches!(
            unknown.replay(),
            Err(ChoiceError::UnsupportedFormat(format)) if format == "counterweave.choices/999"
        ));
    }
}
