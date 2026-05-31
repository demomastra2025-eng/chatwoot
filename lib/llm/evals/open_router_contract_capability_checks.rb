# frozen_string_literal: true

module Llm::Evals::OpenRouterContractCapabilityChecks
  private

  def openrouter_embedding_contract
    parsed = parse_contract_embedding_response(
      { data: [{ embedding: Array.new(Captain::KnowledgeSettings::VECTOR_DIMENSIONS, 0.1), index: 0 }],
        usage: { prompt_tokens: 3 } }
    )
    mismatch_error = embedding_mismatch_error
    failures = embedding_failures(parsed, mismatch_error)

    {
      vector_dimensions: parsed.vectors.first.size,
      input_tokens: parsed.input_tokens,
      mismatch_error: mismatch_error,
      expected: { vector_dimensions: Captain::KnowledgeSettings::VECTOR_DIMENSIONS, rejects_mismatch: true },
      failures: failures
    }
  end

  def openrouter_multimodal_contract
    image_requirements = Llm::Models.required_capability_sets_for('image_recognition')
    audio_requirements = Llm::Models.required_capability_sets_for('audio_transcription')
    moderation_requirements = Llm::Models.required_capability_sets_for('moderation')

    {
      image_requirements: image_requirements,
      audio_requirements: audio_requirements,
      moderation_requirements: moderation_requirements,
      expected: { image_input: true, audio_input: true, moderation_structured_output: true },
      failures: multimodal_failures(image_requirements, audio_requirements, moderation_requirements)
    }
  end

  def parse_contract_embedding_response(body)
    response = Struct.new(:code, :message, :body).new('200', 'OK', body.to_json)
    Llm::OpenRouterEmbeddingClient.send(
      :parse_response,
      response,
      model: 'openai/text-embedding-3-small',
      dimensions: Captain::KnowledgeSettings::VECTOR_DIMENSIONS
    )
  end

  def embedding_mismatch_error
    parse_contract_embedding_response({ data: [{ embedding: [0.1, 0.2], index: 0 }] })
    nil
  rescue RubyLLM::Error => e
    e.message
  end

  def embedding_failures(parsed, mismatch_error)
    failures = []
    expected_message = "expected #{Captain::KnowledgeSettings::VECTOR_DIMENSIONS}"
    failures << 'embedding vector dimension mismatch was not rejected' unless mismatch_error&.include?(expected_message)
    failures << 'embedding parser did not preserve input token usage' unless parsed.input_tokens == 3
    failures
  end

  def multimodal_failures(image_requirements, audio_requirements, moderation_requirements)
    failures = []
    failures << 'image recognition must require image_input capability' unless capability_required?(image_requirements, 'image_input')
    failures << 'audio transcription must require audio_input capability' unless capability_required?(audio_requirements, 'audio_input')
    failures << 'moderation must require structured_output capability' unless capability_required?(moderation_requirements, 'structured_output')
    failures
  end

  def capability_required?(requirement_sets, capability)
    Array(requirement_sets).any? { |requirement| Array(requirement[:capabilities]).include?(capability) }
  end
end
