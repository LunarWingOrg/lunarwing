//! Total turn-budget timeout for LLM providers.
//!
//! Wraps any [`LlmProvider`] so a single logical call — *including* all internal
//! retries, backoff, and failover — can never exceed `budget`.
//!
//! Without this cap, a hung backend lets [`crate::llm::retry::RetryProvider`]
//! stack `max_retries + 1` attempts of `request_timeout_secs` each (e.g.
//! 4 × 120s ≈ 487s) far past the agent's `handle_message` turn budget (300s).
//! The agent then *hard-kills* the turn and clears its pending queue, silently
//! dropping the user's queued follow-up. By failing *gracefully* with a
//! retryable [`LlmError`] before the turn budget is hit, the turn instead
//! completes normally (with an error response) and its pending messages are
//! drained rather than discarded.
//!
//! Placed near the *outside* of the provider chain (after retry/failover) so the
//! budget bounds the whole operation, not a single attempt.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use rust_decimal::Decimal;

use crate::llm::error::LlmError;
use crate::llm::provider::{
    CompletionRequest, CompletionResponse, LlmProvider, ModelMetadata, ToolCompletionRequest,
    ToolCompletionResponse,
};

/// Bounds each `complete` / `complete_with_tools` call (with all of its internal
/// retries) by a total wall-clock `budget`. On elapse it returns a retryable
/// `LlmError::RequestFailed` instead of letting the call run away.
pub struct TimeoutProvider {
    inner: Arc<dyn LlmProvider>,
    budget: Duration,
}

impl TimeoutProvider {
    pub fn new(inner: Arc<dyn LlmProvider>, budget: Duration) -> Self {
        Self { inner, budget }
    }

    fn elapsed_error(&self) -> LlmError {
        LlmError::RequestFailed {
            provider: self.inner.model_name().to_string(),
            reason: format!(
                "LLM call exceeded the {}s turn budget (backend hung or retries stacked); \
                 failed gracefully so the turn can recover",
                self.budget.as_secs()
            ),
        }
    }
}

#[async_trait]
impl LlmProvider for TimeoutProvider {
    fn model_name(&self) -> &str {
        self.inner.model_name()
    }

    fn cost_per_token(&self) -> (Decimal, Decimal) {
        self.inner.cost_per_token()
    }

    fn cache_write_multiplier(&self) -> Decimal {
        self.inner.cache_write_multiplier()
    }

    fn cache_read_discount(&self) -> Decimal {
        self.inner.cache_read_discount()
    }

    async fn complete(&self, request: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        match tokio::time::timeout(self.budget, self.inner.complete(request)).await {
            Ok(result) => result,
            Err(_elapsed) => {
                tracing::warn!(
                    provider = self.inner.model_name(),
                    budget_secs = self.budget.as_secs(),
                    "LLM complete() exceeded turn budget — failing gracefully"
                );
                Err(self.elapsed_error())
            }
        }
    }

    async fn complete_with_tools(
        &self,
        request: ToolCompletionRequest,
    ) -> Result<ToolCompletionResponse, LlmError> {
        match tokio::time::timeout(self.budget, self.inner.complete_with_tools(request)).await {
            Ok(result) => result,
            Err(_elapsed) => {
                tracing::warn!(
                    provider = self.inner.model_name(),
                    budget_secs = self.budget.as_secs(),
                    "LLM complete_with_tools() exceeded turn budget — failing gracefully"
                );
                Err(self.elapsed_error())
            }
        }
    }

    async fn list_models(&self) -> Result<Vec<String>, LlmError> {
        self.inner.list_models().await
    }

    async fn model_metadata(&self) -> Result<ModelMetadata, LlmError> {
        self.inner.model_metadata().await
    }

    fn effective_model_name(&self, requested_model: Option<&str>) -> String {
        self.inner.effective_model_name(requested_model)
    }

    fn active_model_name(&self) -> String {
        self.inner.active_model_name()
    }

    fn set_model(&self, model: &str) -> Result<(), LlmError> {
        self.inner.set_model(model)
    }

    fn calculate_cost(&self, input_tokens: u32, output_tokens: u32) -> Decimal {
        self.inner.calculate_cost(input_tokens, output_tokens)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::llm::retry::is_retryable;
    use crate::testing::StubLlm;
    use crate::testing::fault_injection::{FaultAction, FaultInjector};

    fn make_request() -> CompletionRequest {
        CompletionRequest::new(vec![crate::llm::ChatMessage::user("hello")])
    }

    fn make_tool_request() -> ToolCompletionRequest {
        ToolCompletionRequest::new(vec![crate::llm::ChatMessage::user("hello")], vec![])
    }

    /// A provider that hangs longer than the budget must be aborted with a
    /// graceful, retryable error rather than running to completion.
    #[tokio::test]
    async fn complete_times_out_when_provider_hangs() {
        let slow = Arc::new(StubLlm::new("ok").with_fault_injector(Arc::new(
            FaultInjector::sequence([FaultAction::Delay(Duration::from_secs(30))]),
        )));
        let tp = TimeoutProvider::new(slow, Duration::from_millis(50));

        let started = std::time::Instant::now();
        let err = tp.complete(make_request()).await.unwrap_err();

        // It must have aborted near the budget, not waited the full 30s.
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "timeout did not abort the hung call"
        );
        match err {
            LlmError::RequestFailed { ref reason, .. } => {
                assert!(
                    reason.contains("turn budget"),
                    "unexpected reason: {reason}"
                );
            }
            other => panic!("expected RequestFailed, got: {other:?}"),
        }
        // The error must be retryable so upstream handling treats it as transient.
        assert!(is_retryable(&err));
    }

    #[tokio::test]
    async fn complete_with_tools_times_out_when_provider_hangs() {
        let slow = Arc::new(StubLlm::new("ok").with_fault_injector(Arc::new(
            FaultInjector::sequence([FaultAction::Delay(Duration::from_secs(30))]),
        )));
        let tp = TimeoutProvider::new(slow, Duration::from_millis(50));

        let err = tp
            .complete_with_tools(make_tool_request())
            .await
            .unwrap_err();
        assert!(matches!(err, LlmError::RequestFailed { .. }));
    }

    /// A fast provider must pass straight through, well within the budget.
    #[tokio::test]
    async fn fast_call_passes_through() {
        let fast = Arc::new(StubLlm::new("hi"));
        let tp = TimeoutProvider::new(fast, Duration::from_secs(5));

        assert!(tp.complete(make_request()).await.is_ok());
        assert!(tp.complete_with_tools(make_tool_request()).await.is_ok());
    }

    /// Delegated metadata methods must pass through to the inner provider.
    #[tokio::test]
    async fn delegates_model_name() {
        let inner = Arc::new(StubLlm::new("ok").with_model_name("inner-model"));
        let tp = TimeoutProvider::new(inner, Duration::from_secs(1));
        assert_eq!(tp.model_name(), "inner-model");
    }
}
