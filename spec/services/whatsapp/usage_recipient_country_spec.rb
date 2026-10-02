require 'rails_helper'

RSpec.describe Whatsapp::UsageRecipientCountry do
  describe '.resolve' do
    it 'distinguishes Kazakhstan and Russia within the shared +7 calling code' do
      expect(described_class.resolve('+77011234567')).to eq('KZ')
      expect(described_class.resolve('+79161234567')).to eq('RU')
      expect(described_class.resolve('77011234567')).to eq('KZ')
    end

    it 'uses the number allocation to distinguish Canada and the United States within +1' do
      expect(described_class.resolve('+14165551234')).to eq('CA')
      expect(described_class.resolve('+12125551234')).to eq('US')
    end

    it 'identifies Dominican Republic, Jamaica, and Puerto Rico instead of treating their +1 numbers as US' do
      expect(described_class.resolve('+18095551234')).to eq('DO')
      expect(described_class.resolve('+18765551234')).to eq('JM')
      expect(described_class.resolve('+17875551234')).to eq('PR')
    end

    it 'returns nil for non-E.164, invalid, or unrecognized numbers' do
      expect(described_class.resolve('7701123456')).to be_nil
      expect(described_class.resolve('+999123456789')).to be_nil
      expect(described_class.resolve(nil)).to be_nil
    end
  end
end
