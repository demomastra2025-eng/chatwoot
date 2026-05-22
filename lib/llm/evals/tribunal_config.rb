# frozen_string_literal: true

require 'ruby_llm/tribunal'

module Llm
  module Evals
    class TribunalConfig
      DEFAULT_JUDGE_MODEL = 'gpt-4o-mini'
      DEFAULT_JUDGE_THRESHOLD = 0.8
      DEFAULT_EMBEDDING_MODEL = 'text-embedding-3-small'

      class << self
        def apply!
          require_dependency Rails.root.join('enterprise/lib/captain/evals/judges/one_link_brand_voice_judge').to_s

          RubyLLM::Tribunal.configure do |config|
            config.default_model = ENV.fetch('LLM_EVALS_JUDGE_MODEL', DEFAULT_JUDGE_MODEL)
            config.default_threshold = ENV.fetch('LLM_EVALS_JUDGE_THRESHOLD', DEFAULT_JUDGE_THRESHOLD.to_s).to_f
            if config.respond_to?(:embedding_model=)
              config.embedding_model = ENV.fetch('LLM_EVALS_EMBEDDING_MODEL', DEFAULT_EMBEDDING_MODEL)
            end
            config.verbose = ActiveModel::Type::Boolean.new.cast(ENV.fetch('LLM_EVALS_VERBOSE', 'false'))
          end

          register_judge(Captain::Evals::Judges::OneLinkBrandVoiceJudge)
        end

        private

        def register_judge(judge)
          RubyLLM::Tribunal.register_judge(judge) unless RubyLLM::Tribunal.judge_names.include?(judge.judge_name)
        end
      end
    end
  end
end
