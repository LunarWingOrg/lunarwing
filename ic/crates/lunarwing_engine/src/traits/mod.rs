//! External dependency traits.
//!
//! The engine defines these traits; the host (main lunarwing crate)
//! implements them via bridge adapters over existing infrastructure.

pub mod effect;
pub mod llm;
pub mod store;
