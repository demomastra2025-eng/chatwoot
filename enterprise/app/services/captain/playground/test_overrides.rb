# frozen_string_literal: true

# The model controls of a Playground message (model, temperature, thinking effort). They apply to whichever agent answers, so they are
# checked against the platform's default model of the AI, not against one agent's profile. #resolve gives [overrides, nil], or
# [nil, name of the control that is not allowed].
class Captain::Playground::TestOverrides
  def initialize(attributes, account:)
    @attributes = attributes
    @account = account
  end

  def resolve
    overrides = {}
    model = Llm::Config.model_for(feature: :assistant, account: @account)
    if @attributes[:test_model].present?
      requested = Llm::Models.canonical_model_name(@attributes[:test_model])
      return invalid('test_model') unless selectable?(requested, model)

      model = overrides[:model] = requested
    end
    return invalid('test_temperature') unless apply_temperature(overrides, model)
    return invalid('test_thinking_effort') unless apply_effort(overrides, model)

    [overrides, nil]
  rescue ArgumentError, TypeError
    invalid('test_temperature')
  end

  private

  def invalid(field)
    [nil, field]
  end

  def selectable?(requested, default_model)
    selectable = Llm::Models.curated_model_names_for(:assistant, account: @account) + [default_model].compact_blank
    selectable.include?(requested) && Llm::Models.valid_model_for?(:assistant, requested, account: @account)
  end

  def apply_temperature(overrides, model)
    return true unless @attributes.key?(:test_temperature)

    temperature = Float(@attributes[:test_temperature])
    return false unless temperature.finite? && temperature.between?(0.0, 1.0)
    return false unless Llm::Models.supports_temperature?(model, account: @account)

    overrides[:temperature] = temperature
    true
  end

  def apply_effort(overrides, model)
    return true if @attributes[:test_thinking_effort].blank?

    effort = @attributes[:test_thinking_effort].to_s
    return false unless Llm::RuntimePolicy::THINKING_EFFORTS.include?(effort)
    return false unless Llm::Models.reasoning_efforts_for(model, account: @account).include?(effort)

    overrides[:thinking_effort] = effort
    true
  end
end
