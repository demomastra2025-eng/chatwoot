class RuntimeStateDrop < Liquid::Drop
  def initialize(state)
    super()
    @state = state.is_a?(Hash) ? state.with_indifferent_access : {}
  end

  def custom_attribute
    custom_attributes
  end

  def custom_attributes
    wrap(@state[:custom_attributes] || {})
  end

  def additional_attributes
    wrap(@state[:additional_attributes] || {})
  end

  def liquid_method_missing(method)
    wrap(@state[method])
  end

  def to_s
    return super unless @state[:version] == 1 && %w[deals appointments].include?(@state[:kind]) && @state[:groups].is_a?(Array)

    JSON.generate(@state)
  end

  private

  def wrap(value)
    case value
    when Hash
      self.class.new(value)
    when Array
      value.map { |item| wrap(item) }
    else
      value
    end
  end
end
