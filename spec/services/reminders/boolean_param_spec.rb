require 'rails_helper'

RSpec.describe Reminders::BooleanParam do
  describe '.call' do
    it 'accepts native booleans and canonical string/integer values' do
      expect(described_class.call(true, default: false, field_name: 'flag')).to be(true)
      expect(described_class.call(false, default: true, field_name: 'flag')).to be(false)
      expect(described_class.call('true', default: false, field_name: 'flag')).to be(true)
      expect(described_class.call(' TRUE ', default: false, field_name: 'flag')).to be(true)
      expect(described_class.call('1', default: false, field_name: 'flag')).to be(true)
      expect(described_class.call(1, default: false, field_name: 'flag')).to be(true)
      expect(described_class.call('false', default: true, field_name: 'flag')).to be(false)
      expect(described_class.call(' FALSE ', default: true, field_name: 'flag')).to be(false)
      expect(described_class.call('0', default: true, field_name: 'flag')).to be(false)
      expect(described_class.call(0, default: true, field_name: 'flag')).to be(false)
    end

    it 'uses the default only when the value is absent' do
      expect(described_class.call(nil, default: false, field_name: 'flag')).to be(false)
      expect(described_class.call(nil, default: true, field_name: 'flag')).to be(true)
    end

    it 'rejects ambiguous values instead of casting them truthy' do
      expect { described_class.call('yes', default: false, field_name: 'flag') }.to raise_error(ArgumentError, 'flag must be true or false')
      expect { described_class.call('abc', default: false, field_name: 'flag') }.to raise_error(ArgumentError, 'flag must be true or false')
      expect { described_class.call({}, default: false, field_name: 'flag') }.to raise_error(ArgumentError, 'flag must be true or false')
    end
  end

  describe '.truthy?' do
    it 'is fail-safe for invalid metadata values' do
      expect(described_class.truthy?(true)).to be(true)
      expect(described_class.truthy?('true')).to be(true)
      expect(described_class.truthy?('yes')).to be(false)
      expect(described_class.truthy?(nil)).to be(false)
    end
  end
end
