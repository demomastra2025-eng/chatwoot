# frozen_string_literal: true

class Llm::ApiClient
  class << self
    def configure(&block)
      RubyLLM.configure(&block)
    end

    def context(&block)
      RubyLLM.context(&block)
    end

    def embed(...)
      RubyLLM.embed(...)
    end

    def moderate(...)
      RubyLLM.moderate(...)
    end
  end
end
