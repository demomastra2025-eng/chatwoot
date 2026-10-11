class Api::V1::Accounts::Captain::ScenariosController < Api::V1::Accounts::BaseController
  STANDALONE_AGENT_ATTRIBUTE_MAP = {
    'title' => :name, 'description' => :routing_description, 'instruction' => :description, 'enabled' => :active
  }.freeze

  before_action :current_account
  before_action -> { check_authorization(Captain::Scenario) }
  before_action :set_assistant
  before_action :set_scenario, only: [:show, :update, :destroy]

  def index
    @scenarios = assistant_scenarios.includes(:assistant, :standalone_agent)
  end

  def show; end

  def create
    Current.account.with_lock do
      @scenario = assistant_scenarios.create!(scenario_params.merge(account: Current.account))
      result = Captain::LegacyScenarioConversionService.new.convert!(@scenario.id)
      raise ActiveRecord::RecordInvalid, @scenario if result[:skipped]

      converted_agent = Current.account.captain_assistants.find(result[:assistant_id])
      Captain::Knowledge::AccessService.inherit_access!(from_assistant: @assistant, to_assistant: converted_agent)
    end
  end

  def update
    Current.account.with_lock do
      @scenario.update!(scenario_params)
      standalone_agent&.update!(standalone_agent_attributes)
    end
  end

  def destroy
    Current.account.with_lock do
      if standalone_agent
        standalone_agent.update!(active: false)
        @scenario.update!(enabled: false)
      else
        @scenario.destroy!
      end
    end
    head :no_content
  end

  private

  def set_assistant
    @assistant = account_assistants.find(params[:assistant_id])
  end

  def account_assistants
    @account_assistants ||= Current.account.captain_assistants
  end

  def set_scenario
    @scenario = assistant_scenarios.find(params[:id])
  end

  def assistant_scenarios
    @assistant.scenarios
  end

  def scenario_params
    params.require(:scenario).permit(:title, :description, :instruction, :enabled, tools: [])
  end

  def standalone_agent
    @standalone_agent ||= Current.account.captain_assistants.find_by(legacy_scenario_id: @scenario.id)
  end

  def standalone_agent_attributes
    attributes = scenario_params.to_h.each_with_object({}) do |(key, value), values|
      agent_key = STANDALONE_AGENT_ATTRIBUTE_MAP[key]
      values[agent_key] = value if agent_key
    end
    if scenario_params.key?(:tools) || scenario_params.key?(:instruction)
      attributes[:config] = standalone_agent_tool_config
    end
    attributes
  end

  def standalone_agent_tool_config
    config = standalone_agent.config.to_h.deep_dup
    metadata = config['legacy_scenario_migration'] ||= {}
    access = config['tool_access'] ||= {}
    agent_access = access['agent'] ||= { 'enabled' => true, 'tool_ids' => [] }
    old_ids = Array(metadata['explicit_tool_ids']).map(&:to_s)
    new_ids = Array(scenario_params.key?(:tools) ? scenario_params[:tools] : @scenario.tools).map(&:to_s).uniq
    agent_access['tool_ids'] = (Array(agent_access['tool_ids']) - old_ids) | new_ids
    metadata['explicit_tool_ids'] = new_ids
    config
  end
end
