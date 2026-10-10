class Captain::Tools::ProviderReceiptProjection
  REMOVED_AGENT_TOOL = 'get_appointment_provider_status'.freeze

  # Keep the internal receipt and its operation evidence, but do not ask the
  # customer agent to call a tool that is absent from its runtime.
  def self.for_agent(payload)
    if payload.is_a?(String)
      return JSON.generate(for_agent(JSON.parse(payload)))
    end
    if payload.is_a?(Hash)
      return payload.each_with_object({}) do |(key, value), result|
        next if key.to_s == 'lookup_tool' && value == REMOVED_AGENT_TOOL

        result[key] = for_agent(value)
      end
    end
    return payload.map { |value| for_agent(value) } if payload.is_a?(Array)

    payload
  rescue JSON::ParserError
    payload
  end
end
