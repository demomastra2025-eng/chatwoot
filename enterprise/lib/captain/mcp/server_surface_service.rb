class Captain::Mcp::ServerSurfaceService
  def initialize(mcp_server)
    @mcp_server = mcp_server
  end

  def snapshot(refresh: true)
    Captain::Mcp::ClientBuilder.with_client(@mcp_server) do |client|
      {
        capabilities: capabilities_payload(client),
        tools: tools_payload(client, refresh: refresh),
        resources: resources_payload(client, refresh: refresh),
        resource_templates: resource_templates_payload(client, refresh: refresh),
        prompts: prompts_payload(client, refresh: refresh),
        tasks: tasks_payload(client)
      }
    end
  end

  def read_resource(uri:)
    with_client do |client|
      resource = client.resources(refresh: true).find { |item| item.uri == uri.to_s }
      raise ActiveRecord::RecordNotFound, 'Resource not found' if resource.blank?

      resource.content
      resource_payload(resource, include_content: true)
    end
  end

  def fetch_resource_template(name:, arguments: {})
    with_client do |client|
      template = client.resource_template(name.to_s, refresh: true)
      raise ActiveRecord::RecordNotFound, 'Resource template not found' if template.blank?

      resource_payload(template.fetch_resource(arguments: arguments.to_h), include_content: true)
    end
  end

  def fetch_prompt(name:, arguments: {})
    with_client do |client|
      prompt = client.prompt(name.to_s, refresh: true)
      raise ActiveRecord::RecordNotFound, 'Prompt not found' if prompt.blank?

      {
        name: prompt.name,
        messages: prompt.fetch(arguments.to_h).map { |message| message_payload(message) }
      }
    end
  end

  def task_get(task_id:)
    with_client { |client| task_payload(client.task_get(task_id.to_s)) }
  end

  def task_result(task_id:)
    with_client { |client| normalize_value(client.task_result(task_id.to_s)) }
  end

  def task_cancel(task_id:)
    with_client { |client| task_payload(client.task_cancel(task_id.to_s)) }
  end

  private

  def with_client(&block)
    Captain::Mcp::ClientBuilder.with_client(@mcp_server, &block)
  end

  def capabilities_payload(client)
    capabilities = client.capabilities
    raw = capabilities.respond_to?(:capabilities) ? capabilities.capabilities : {}

    {
      raw: normalize_value(raw),
      tools: capabilities.tools_list?,
      resources: capabilities.resources_list?,
      resource_subscribe: capabilities.resource_subscribe?,
      resource_templates: capabilities.resources_list?,
      prompts: capabilities.prompt_list?,
      completion: capabilities.completion?,
      tasks: capabilities.tasks?,
      task_cancel: capabilities.tasks_cancel?
    }
  end

  def tools_payload(client, refresh:)
    client.tools(refresh: refresh).map do |tool|
      {
        id: "mcp__#{@mcp_server.slug}__#{tool.name}",
        name: tool.name,
        title: tool.annotations&.title.presence || tool.name.to_s.humanize,
        description: tool.description.to_s,
        input_schema: normalize_value(tool.params_schema),
        output_schema: normalize_value(tool.output_schema),
        annotations: normalize_value(tool.annotations&.to_h)
      }
    end
  end

  def resources_payload(client, refresh:)
    client.resources(refresh: refresh).map { |resource| resource_payload(resource) }
  end

  def resource_templates_payload(client, refresh:)
    client.resource_templates(refresh: refresh).map do |template|
      {
        uri_template: template.uri,
        name: template.name,
        description: template.description.to_s,
        mime_type: template.mime_type
      }
    end
  end

  def prompts_payload(client, refresh:)
    client.prompts(refresh: refresh).map do |prompt|
      {
        name: prompt.name,
        description: prompt.description.to_s,
        arguments: normalize_value(prompt.arguments.map(&:to_h))
      }
    end
  end

  def tasks_payload(client)
    client.tasks_list.map { |task| task_payload(task) }
  rescue RubyLLM::MCP::Errors::UnsupportedFeature, RubyLLM::MCP::Errors::BaseError
    []
  end

  def resource_payload(resource, include_content: false)
    payload = {
      uri: resource.uri,
      name: resource.name,
      description: resource.description.to_s,
      mime_type: resource.mime_type,
      content_loaded: resource.content_loaded?
    }
    payload[:content] = normalize_value(resource.content) if include_content
    payload
  end

  def task_payload(task)
    normalize_value(task.to_h)
  end

  def message_payload(message)
    content = message.content.respond_to?(:to_h) ? message.content.to_h : message.content

    {
      role: message.role,
      content: normalize_value(content)
    }
  end

  def normalize_value(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, item), memo| memo[key] = normalize_value(item) }
    when Array
      value.map { |item| normalize_value(item) }
    else
      value
    end
  end
end
