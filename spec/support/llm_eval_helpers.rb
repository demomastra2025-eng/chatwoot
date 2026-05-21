# frozen_string_literal: true

require 'ruby_llm/tribunal'

RSpec.configure do |config|
  config.include RubyLLM::Tribunal::EvalHelpers, type: :llm_eval
end
