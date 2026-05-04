//! Safety layer for prompt injection defense.
//!
//! This module re-exports everything from the `lunarwing_safety` crate,
//! keeping `crate::safety::*` imports working throughout the codebase.

pub use lunarwing_safety::*;
