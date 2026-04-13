class Reminders::DefinitionNormalizer
  class << self
    def call(definition)
      normalized_definition = normalize_definition(definition)
      return normalized_definition unless normalized_definition.is_a?(Hash)

      normalized_definition['text_mode'] = Reminders::TextModeResolver.call(
        action_type: normalized_definition['action_type'],
        body: normalized_definition['body'],
        instructions: normalized_definition['instructions'],
        text_mode: normalized_definition['text_mode']
      )
      normalized_definition
    end

    private

    def normalize_definition(definition)
      raw_definition =
        if definition.is_a?(ActionController::Parameters)
          definition.to_unsafe_h
        elsif definition.respond_to?(:to_h) && !definition.is_a?(Hash)
          definition.to_h
        else
          definition
        end

      return raw_definition unless raw_definition.is_a?(Hash)

      raw_definition.deep_stringify_keys
    end
  end
end
