require 'rails_helper'

RSpec.describe SuperAdmin::SecretMask do
  describe '.hint' do
    it 'shows dots and the last 4 characters of a long secret' do
      expect(described_class.hint('abcdefghijklmnop')).to eq('••••mnop')
    end

    it 'shows only dots for a secret that is too short to give a tail away' do
      expect(described_class.hint('abcdefgh')).to eq('••••')
      expect(described_class.hint('x')).to eq('••••')
    end

    it 'shows nothing for an empty value' do
      expect(described_class.hint(nil)).to be_nil
      expect(described_class.hint('')).to be_nil
    end

    it 'never contains more than the last 4 characters of the value' do
      secret = 'tok_ABCDEFGHIJKLMNOP1234'

      expect(described_class.hint(secret)).not_to include('ABCDEFGHIJKLMNOP')
      expect(described_class.hint(secret)).to end_with('1234')
    end
  end
end
