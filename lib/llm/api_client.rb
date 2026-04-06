# frozen_string_literal: true

class Llm::ApiClient
  class << self
    def configure(&)
      RubyLLM.configure(&)
    end

    def context(&)
      RubyLLM.context(&)
    end

    def embed(...)
      RubyLLM.embed(...)
    end

    def moderate(...)
      RubyLLM.moderate(...)
    end

    def transcribe(...)
      RubyLLM.transcribe(...)
    end
  end
end
