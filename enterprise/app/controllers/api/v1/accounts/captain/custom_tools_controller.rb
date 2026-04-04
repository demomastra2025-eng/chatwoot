class Api::V1::Accounts::Captain::CustomToolsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::CustomTool) }
  before_action :set_custom_tool, only: [:show, :update, :destroy]

  def index
    @custom_tools = account_custom_tools.order(created_at: :desc)
  end

  def show; end

  def create
    @custom_tool = account_custom_tools.create!(custom_tool_params)
  end

  def test
    custom_tool = build_preview_custom_tool
    return render_could_not_create_error(custom_tool.errors.full_messages.join(', ')) unless custom_tool.valid?

    executor = Captain::Tools::HttpRequestExecutor.new(
      assistant: preview_assistant,
      custom_tool: custom_tool,
      state: preview_state
    )

    result = if preview_only?
               { preview: executor.preview(test_agent_params) }
             else
               executor.execute_with_details(test_agent_params, raise_on_http_error: false)
             end

    render json: result
  rescue Captain::Tools::HttpRequestExecutor::MissingRequiredParametersError,
         Captain::Tools::HttpRequestExecutor::ToolConfigurationError => e
    render_could_not_create_error(e.message)
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def update
    @custom_tool.update!(custom_tool_params)
  end

  def destroy
    @custom_tool.destroy
    head :no_content
  end

  private

  def set_custom_tool
    @custom_tool = account_custom_tools.find(params[:id])
  end

  def account_custom_tools
    @account_custom_tools ||= Current.account.captain_custom_tools
  end

  def custom_tool_params
    params.require(:custom_tool).permit(
      :title,
      :group_name,
      :description,
      :endpoint_url,
      :http_method,
      :request_template,
      :response_template,
      :auth_type,
      :enabled,
      auth_config: {},
      param_schema: [:name, :type, :description, :required, :source, :context_path, :fixed_value]
    )
  end

  def build_preview_custom_tool
    tool = account_custom_tools.new(custom_tool_params)
    tool.slug = "preview_#{SecureRandom.hex(6)}"
    tool
  end

  def preview_assistant
    @preview_assistant ||= Captain::Assistant.new(
      account: Current.account,
      name: 'Preview Assistant',
      description: 'Preview assistant used for custom tool testing',
      config: {
        'product_name' => Current.account.name
      }
    )
  end

  def preview_state
    {
      account_id: Current.account.id,
      assistant_id: preview_assistant.id,
      prompt_context: build_prompt_context(test_context_values)
    }.compact
  end

  def preview_only?
    ActiveModel::Type::Boolean.new.cast(params[:preview_only])
  end

  def test_payload_params
    @test_payload_params ||= begin
      payload = params[:test_payload]
      raw_payload = if payload.respond_to?(:permit!)
                      payload.permit!.to_h
                    elsif payload.respond_to?(:to_h)
                      payload.to_h
                    else
                      {}
                    end

      raw_payload.with_indifferent_access
    end
  end

  def test_agent_params
    test_payload_params.fetch(:agent_params, {}).to_h
  end

  def test_context_values
    test_payload_params.fetch(:context_values, {}).to_h
  end

  def build_prompt_context(context_values)
    context_values.each_with_object({}) do |(field_id, value), prompt_context|
      assign_prompt_context_value(prompt_context, field_id, value)
    end
  end

  def assign_prompt_context_value(prompt_context, field_id, value)
    scope, *path = field_id.to_s.split('.')
    return if scope.blank? || path.empty?

    leaf_key = path.pop
    target = path.reduce(prompt_context[scope] ||= {}) do |memo, key|
      memo[key] ||= {}
      memo[key]
    end

    target[leaf_key] = value
  end
end
