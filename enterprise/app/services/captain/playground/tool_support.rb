class Captain::Playground::ToolSupport
  # These services require live network/content-provider execution. A synthetic
  # result would not implement their production behavior, so the workspace
  # reports a blocked capability before either real or scenario dispatch.
  EXTERNAL_TOOLS = %w[web_search web_scrape_url search_linear_issues translate_message].freeze
  CUSTOM_FIELD_TOOLS = %w[list_deal_custom_fields list_task_custom_fields list_appointment_custom_fields list_contact_custom_fields].freeze

  def self.for_tool(id)
    return 'blocked_external_service' if EXTERNAL_TOOLS.include?(id.to_s)
    return 'synthetic' if Captain::Playground::ToolExecutor::HANDLERS.key?(id.to_s) || CUSTOM_FIELD_TOOLS.include?(id.to_s)

    'blocked_no_adapter'
  end

  def self.failure(id)
    Captain::ToolResult.failure(error: "#{id} requires an external service and is unavailable in the isolated Playground",
      retryable: false, data: { code: for_tool(id), simulated: true, delivered: false })
  end
end
