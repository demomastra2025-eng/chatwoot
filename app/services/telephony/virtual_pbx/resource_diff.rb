# frozen_string_literal: true

class Telephony::VirtualPbx::ResourceDiff
  def self.compare(expected:, actual:, fields:)
    new(expected: expected, actual: actual, fields: fields).to_a
  end

  def initialize(expected:, actual:, fields:)
    @expected = (expected || {}).with_indifferent_access
    @actual = (actual || {}).with_indifferent_access
    @fields = fields
  end

  def to_a
    fields.filter_map do |field|
      expected_value = expected[field]
      actual_value = actual[field] || actual[field.to_s.camelize(:lower)]
      next if expected_value.blank? || expected_value.to_s == actual_value.to_s

      {
        field: field.to_s,
        expected: expected_value,
        actual: actual_value,
        code: "#{field}_mismatch"
      }
    end
  end

  private

  attr_reader :expected, :actual, :fields
end
