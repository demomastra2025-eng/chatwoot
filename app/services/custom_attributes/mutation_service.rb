class CustomAttributes::MutationService
  def self.merge(current_attributes, incoming_attributes)
    new(current_attributes).merge(incoming_attributes)
  end

  def self.destroy(current_attributes, keys)
    new(current_attributes).destroy(keys)
  end

  def initialize(current_attributes)
    @current_attributes = normalize_attributes(current_attributes)
  end

  def merge(incoming_attributes)
    return @current_attributes if incoming_attributes.blank?

    @current_attributes.merge(normalize_attributes(incoming_attributes))
  end

  def destroy(keys)
    @current_attributes.except(*normalize_keys(keys))
  end

  private

  def normalize_attributes(attributes)
    (attributes || {}).to_h.deep_stringify_keys
  end

  def normalize_keys(keys)
    Array(keys).flatten.compact.map(&:to_s)
  end
end
