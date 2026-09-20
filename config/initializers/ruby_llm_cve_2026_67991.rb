# frozen_string_literal: true

# Backport of crmne/ruby_llm@9d75b033d7d00c4e1baa9b0afb4828faa8bd6602.
# RubyLLM 2.0 contains the upstream fix, but requires a separate persisted-data
# and API migration. Keep the 1.x runtime safe until that migration is complete.
module OneLinkRubyLlmUnderscoreBackport
  UNDERSCORE_BOUNDARY = /(?<=[a-z\d])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])/

  module_function

  def underscore(name)
    name.gsub(UNDERSCORE_BOUNDARY, '_').downcase
  end
end

module OneLinkRubyLlmToolNameBackport
  def name
    klass_name = self.class.name
    normalized = klass_name.to_s.dup.force_encoding('UTF-8').unicode_normalize(:nfkd)

    OneLinkRubyLlmUnderscoreBackport
      .underscore(normalized.encode('ASCII', replace: '').gsub(/[^a-zA-Z0-9_-]/, '-'))
      .delete_suffix('_tool')
  end
end

module OneLinkRubyLlmAgentPromptPathBackport
  private

  def prompt_agent_path
    class_name = name || 'agent'

    OneLinkRubyLlmUnderscoreBackport
      .underscore(class_name.gsub('::', '/'))
      .tr('-', '_')
  end
end

RubyLLM::Tool.prepend(OneLinkRubyLlmToolNameBackport)
RubyLLM::Agent.singleton_class.prepend(OneLinkRubyLlmAgentPromptPathBackport)
