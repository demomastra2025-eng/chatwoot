# frozen_string_literal: true

# The installed provider catalog is the parameter contract. A capability such as
# `reasoning` alone does not prove which effort values a provider accepts.
class Llm::ModelParameters
  class << self
    def for(model, account: nil)
      new(model, account: account)
    end
  end

  def initialize(model, account: nil)
    @model = Llm::Models.canonical_model_name(model)
    @config = Llm::Models.model_config(@model, account: account).to_h.deep_stringify_keys
  end

  def temperature?
    return supported_parameters.include?('temperature') if @config.key?('supported_parameters')

    metadata = RubyLLM.models.find(@model)&.metadata.to_h
    metadata.with_indifferent_access[:temperature] == true
  rescue StandardError
    false
  end

  def reasoning_efforts
    reasoning = @config['reasoning']
    return [] unless reasoning.is_a?(Hash) && reasoning.key?('supported_efforts')
    return [] unless supported_parameters.intersect?(%w[reasoning reasoning_effort]) ||
                     Array(@config['capabilities']).include?('reasoning')

    # OpenRouter's per-model metadata contract explicitly defines null as all
    # gateway efforts; absent keys do not expose an effort selector. Only apply
    # that convention to an installed OpenRouter catalog entry, not other APIs.
    # https://openrouter.ai/docs/guides/best-practices/reasoning-tokens#discovering-per-model-reasoning-options
    return [] if reasoning['supported_efforts'].nil? && @config['provider'] != 'openrouter'

    values = reasoning['supported_efforts'].nil? ? Llm::RuntimePolicy::THINKING_EFFORTS : Array(reasoning['supported_efforts'])
    efforts = values.map(&:to_s) & Llm::RuntimePolicy::THINKING_EFFORTS
    reasoning['mandatory'] == true ? efforts - ['none'] : efforts
  end

  def metadata
    { supports_temperature: temperature?, reasoning_efforts: reasoning_efforts,
      parameter_source: @config['source'].presence || 'installed_provider_metadata' }
  end

  def temperature(value)
    return unless temperature? && value.present?

    number = Float(value)
    number if number.finite? && number.between?(0.0, 1.0)
  rescue ArgumentError, TypeError
    nil
  end

  def thinking(effort)
    return unless reasoning_efforts.include?(effort.to_s)

    { effort: effort.to_s }
  end

  # Used for saved profiles as well as session overrides. Clearing a model also
  # clears parameters whose support is unknown for the effective provider model.
  def normalize_config(config)
    result = config.to_h.deep_stringify_keys
    result.delete('temperature') unless temperature(result['temperature'])
    result.delete('thinking_effort') unless thinking(result['thinking_effort'])
    result
  end

  def compile(temperature: nil, thinking: nil, params: {})
    raw = params.to_h.except(:temperature, 'temperature', :reasoning, 'reasoning',
                            :reasoning_effort, 'reasoning_effort', :include_reasoning, 'include_reasoning')
    options = { params: raw.select { |key, _| supported_parameters.include?(key.to_s) } }
    options[:temperature] = self.temperature(temperature)
    options[:params][Llm::OpenRouterServerToolsPatch::OMIT_TEMPERATURE_PARAM] = true if options[:temperature].nil?
    options[:thinking] = self.thinking(thinking.to_h[:effort] || thinking.to_h['effort'])
    options.compact
  end

  private

  def supported_parameters
    Array(@config['supported_parameters']).map(&:to_s)
  end
end
