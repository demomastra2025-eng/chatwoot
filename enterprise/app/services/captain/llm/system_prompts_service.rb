class Captain::Llm::SystemPromptsService
  class << self
    def faq_generator(language = 'english')
      render_prompt('faq_generator', language: language)
    end

    def conversation_faq_generator(language = 'english')
      render_prompt('conversation_faq_generator', language: language)
    end

    def notes_generator(language = 'english')
      render_prompt('notes_generator', language: language)
    end

    def attributes_generator
      render_prompt('attributes_generator')
    end

    def assistant_response_generator(assistant_name, assistant_instruction, config = {}, contact: nil)
      render_prompt(
        'assistant_response_generator',
        assistant_name: assistant_name.presence || 'Captain',
        assistant_description: assistant_instruction.presence || 'Support the configured business scope only.',
        global_system_instruction: Llm::Config.global_agent_system_prompt,
        feature_citation: ActiveModel::Type::Boolean.new.cast(config['feature_citation']),
        contact_context: build_contact_context(contact)
      )
    end

    def paginated_faq_generator(start_page, end_page, language = 'english')
      render_prompt(
        'paginated_faq_generator',
        start_page: start_page,
        page_count: (end_page - start_page + 1),
        language: language
      )
    end

    def website_analysis
      render_prompt('website_analysis')
    end

    private

    def render_prompt(name, variables = {})
      Captain::PromptRegistry.render!(name, category: :llm, variables: variables)
    end

    def build_contact_context(contact)
      return '' if contact.nil?

      lines = contact_basic_lines(contact) + contact_custom_attribute_lines(contact)
      return '' if lines.empty?

      "[Contact Information]\n#{lines.join("\n")}\n\n"
    end

    def contact_basic_lines(contact)
      [
        (["- Name: #{sanitize_attr(contact[:name])}"] if contact[:name].present?),
        (["- Email: #{sanitize_attr(contact[:email])}"] if contact[:email].present?),
        (["- Phone: #{sanitize_attr(contact[:phone_number])}"] if contact[:phone_number].present?),
        (["- Identifier: #{sanitize_attr(contact[:identifier])}"] if contact[:identifier].present?)
      ].flatten.compact
    end

    def contact_custom_attribute_lines(contact)
      custom = contact[:custom_attributes]
      return [] unless custom.is_a?(Hash)

      custom.filter_map { |key, value| "- #{sanitize_attr(key)}: #{sanitize_attr(value)}" unless value.nil? }
    end

    # Cap at 200 chars to prevent oversized attribute values from eating context window
    def sanitize_attr(value)
      value.to_s.gsub(/[\r\n]+/, ' ').strip.truncate(200)
    end
  end
end
