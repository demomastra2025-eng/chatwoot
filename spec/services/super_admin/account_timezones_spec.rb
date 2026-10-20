# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::AccountTimezones do
  describe '.options' do
    it 'starts with Astana, labelled with the offset of the zone' do
      expect(described_class.options.first).to eq(['Астана, Алматы (UTC+5)', 'Asia/Almaty'])
    end

    it 'offers only zones the application accepts for an account' do
      described_class.identifiers.each do |zone|
        expect(ActiveSupport::TimeZone[zone]).to be_present, "#{zone} is not a zone of ActiveSupport"
        expect(TZInfo::Timezone.all_identifiers).to include(zone)
        account = Account.new(name: 'Зона', reporting_timezone: zone, workspace_timezone: zone)
        expect(account).to be_valid
      end
    end

    it 'labels every zone in Russian' do
      expect(described_class.options.map(&:first)).to all(match(/\A[А-Яа-я, ]+ \(UTC[+-]\d{1,2}(:\d{2})?\)\z/))
    end
  end

  describe '.label_for and .known?' do
    it 'names a stored zone and shows a zone outside the list as it is' do
      expect(described_class.label_for('Europe/Moscow')).to eq('Москва (UTC+3)')
      expect(described_class.label_for('America/Lima')).to eq('America/Lima')
      expect(described_class.label_for(nil)).to eq('')
    end

    it 'knows the zones of the list only' do
      expect(described_class).to be_known('Asia/Almaty')
      expect(described_class).not_to be_known('Mars/Olympus')
      expect(described_class::DEFAULT).to eq('Asia/Almaty')
    end
  end
end
