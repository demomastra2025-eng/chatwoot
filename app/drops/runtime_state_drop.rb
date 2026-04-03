class RuntimeStateDrop < Liquid::Drop
  def initialize(state)
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

  def before_method(method)
    wrap(@state[method])
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
