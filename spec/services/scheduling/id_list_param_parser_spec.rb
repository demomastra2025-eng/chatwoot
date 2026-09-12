require 'rails_helper'

RSpec.describe Scheduling::IdListParamParser do
  it 'normalizes single, CSV and array inputs to the same integer IDs' do
    expect(described_class.parse('42', field_name: 'resource_ids')).to eq([42])
    expect(described_class.parse('42,43', field_name: 'resource_ids')).to eq([42, 43])
    expect(described_class.parse([42, '43'], field_name: 'resource_ids')).to eq([42, 43])
  end

  it 'rejects unsupported scalar and nested types' do
    [42, true, false, { id: 42 }, [[42]]].each do |value|
      expect do
        described_class.parse(value, field_name: 'resource_ids')
      end.to raise_error(ArgumentError, /resource_ids must contain positive integer IDs/)
    end
  end

  it 'rejects non-positive and malformed IDs' do
    ['0', '-1', '42,nope', [42, 'nope']].each do |value|
      expect do
        described_class.parse(value, field_name: 'resource_ids')
      end.to raise_error(ArgumentError, /resource_ids must contain positive integer IDs/)
    end
  end
end
