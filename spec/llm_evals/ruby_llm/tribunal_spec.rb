# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RubyLLM::Tribunal, type: :llm_eval do
  it 'loads Tribunal helpers for deterministic AI quality assertions' do
    expect(self).to respond_to(:assert_contains)
    expect(self).to respond_to(:assert_json)
    expect(self).to respond_to(:refute_hallucination)
  end

  it 'runs deterministic assertions without external LLM calls' do
    expect { assert_contains('Клиент может вернуть товар в течение 14 дней.', '14 дней') }.not_to raise_error
    expect { assert_json('{"tool_used":true,"source":"crm"}') }.not_to raise_error
  end
end
