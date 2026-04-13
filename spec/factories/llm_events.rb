FactoryBot.define do
  factory :llm_event do
    account
    event_name { 'llm.chat.complete' }
    feature { 'assistant' }
    runtime_mode { 'captain_runtime' }
    provider { 'openai' }
    model { 'gpt-4.1-mini' }
    prompt_tokens { 120 }
    completion_tokens { 40 }
    total_tokens { 160 }
    duration_ms { 420 }
    credit_multiplier { 1 }
    estimated_cost { 0.00012 }
    payload { {} }
  end
end
