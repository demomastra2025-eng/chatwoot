class Captain::Llm::ContactAttributesService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  def initialize(assistant, conversation)
    super()
    @assistant = assistant
    @conversation = conversation
    @contact = conversation.contact
    @content = "#Contact\n\n#{@contact.to_llm_text} \n\n#Conversation\n\n#{@conversation.to_llm_text}"
  end

  def generate_and_update_attributes
    generate_attributes
    # to implement the update attributes
  end

  private

  attr_reader :content

  def generate_attributes
    response = instrument_llm_call(instrumentation_params) do
      llm_chat = chat
                 .with_schema(Captain::Llm::Schemas::ContactAttributeCollection)
                 .with_instructions(system_prompt)

      ask_chat(llm_chat, @content)
    end
    parse_response(response.content)
  rescue RubyLLM::Error => e
    ChatwootExceptionTracker.new(e, account: @conversation.account).capture_exception
    []
  end

  def instrumentation_params
    {
      span_name: 'llm.captain.contact_attributes',
      model: model,
      temperature: @temperature,
      account_id: @conversation.account_id,
      feature_name: 'contact_attributes',
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: @content }
      ],
      metadata: { assistant_id: @assistant.id, contact_id: @contact.id }
    }
  end

  def system_prompt
    Captain::Llm::SystemPromptsService.attributes_generator
  end

  def parse_response(content)
    return [] unless content.is_a?(Hash)

    Array(content.with_indifferent_access[:attributes]).map do |attribute|
      attribute.respond_to?(:with_indifferent_access) ? attribute.with_indifferent_access : attribute
    end
  rescue StandardError => e
    Rails.logger.error "Error in parsing contact attributes response: #{e.message}"
    []
  end
end
