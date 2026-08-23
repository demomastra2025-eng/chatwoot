require 'rails_helper'

RSpec.describe Whatsapp::ProviderTimestamp do
  describe '.normalize' do
    it 'normalizes seconds and milliseconds to the same epoch value' do
      travel_to(Time.zone.at(1_800_000_000)) do
        expect(described_class.normalize('1700000100')).to eq(1_700_000_100)
        expect(described_class.normalize('1700000100000')).to eq(1_700_000_100)
      end
    end

    it 'rejects malformed, implausibly old, and future timestamps' do
      travel_to(Time.zone.at(1_800_000_000)) do
        expect(described_class.normalize('invalid')).to be_nil
        expect(described_class.normalize('1')).to be_nil
        expect(described_class.normalize('999999999999999999')).to be_nil
      end
    end
  end

  describe '.invalid_supplied?' do
    it 'distinguishes missing timestamps from supplied invalid values' do
      expect(described_class.invalid_supplied?(nil)).to be(false)
      expect(described_class.invalid_supplied?('')).to be(false)
      expect(described_class.invalid_supplied?('invalid')).to be(true)
      expect(described_class.invalid_supplied?(false)).to be(true)
    end
  end
end
