FactoryBot.define do
  factory :llm_usage_event do
    account
    association :llm_event
    occurred_at { Time.current }
    event_name { 'llm.chat.complete' }
    add_attribute(:feature) { 'assistant' }
    provider { 'openrouter' }
    actual_provider { 'OpenAI' }
    requested_model { 'openai/gpt-4o' }
    actual_model { 'openai/gpt-4o' }
    routing_profile { 'balanced' }
    status { 'success' }
    prompt_tokens { 100 }
    completion_tokens { 40 }
    reasoning_tokens { 7 }
    cached_tokens { 11 }
    total_tokens { 147 }
    estimated_cost { 0.0012 }
    duration_ms { 900 }
    generation_id { 'gen-123' }
    trace_id { 'trace-123' }
    session_id { 'session-123' }
    request_id { 'request-123' }
    metadata { {} }
  end
end
