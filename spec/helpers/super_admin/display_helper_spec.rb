require 'rails_helper'

RSpec.describe SuperAdmin::DisplayHelper do
  describe 'Astana time' do
    it 'is UTC+5 in summer and in winter (one zone, no daylight saving)' do
      summer = described_class.in_astana(Time.utc(2026, 7, 1, 12, 0))
      winter = described_class.in_astana(Time.utc(2026, 1, 1, 12, 0))

      expect(summer.utc_offset).to eq(5.hours)
      expect(winter.utc_offset).to eq(5.hours)
      expect(summer.hour).to eq(17)
    end

    it 'uses the same offset as the plans, which stamp their own times' do
      expect(Accounts::Plans::ASTANA_OFFSET).to eq('+05:00')
      expect(described_class.in_astana(Time.utc(2026, 10, 15, 12, 0)).strftime('%z')).to eq('+0500')
    end

    it 'agrees with the Kazakhstan time zone of the tzdata the application runs on' do
      # Almaty/Astana moved from +06:00 to +05:00 on 2024-03-01. Stale tzdata would silently shift every
      # time zone name used elsewhere (the reporting time zone of a clinic), so this fails loudly.
      zone = ActiveSupport::TimeZone['Astana']

      expect(zone.at(Time.utc(2026, 10, 15, 12, 0)).utc_offset).to eq(5.hours)
    end

    it 'formats a moment as dd.mm.yyyy hh:mm' do
      expect(described_class.format_time(Time.utc(2026, 10, 15, 12, 5, 9))).to eq('15.10.2026 17:05')
      expect(described_class.format_time(Time.utc(2026, 10, 15, 12, 5, 9), '%d.%m.%Y %H:%M:%S')).to eq('15.10.2026 17:05:09')
    end

    it 'moves a late evening UTC time over midnight' do
      expect(described_class.format_time(Time.utc(2026, 10, 15, 20, 30))).to eq('16.10.2026 01:30')
    end

    it 'reads ISO strings and time zone aware times, and ignores blank or unreadable values' do
      expect(described_class.format_time('2026-10-15T12:00:00Z')).to eq('15.10.2026 17:00')
      expect(described_class.format_time('2026-10-15T12:00:00+06:00')).to eq('15.10.2026 11:00')
      expect(described_class.format_time(Time.zone.parse('2026-10-15 12:00'))).to eq('15.10.2026 17:00')
      expect(described_class.format_time(nil)).to be_nil
      expect(described_class.format_time('')).to be_nil
      expect(described_class.format_time('garbage')).to be_nil
    end
  end

  describe '.parse_input' do
    it 'reads a datetime-local value as Astana wall-clock time' do
      expect(described_class.parse_input('2026-10-15T17:00')).to eq(Time.utc(2026, 10, 15, 12, 0))
      expect(described_class.parse_input('2026-10-15T17:00:30')).to eq(Time.utc(2026, 10, 15, 12, 0, 30))
    end

    it 'leaves everything else to the normal parsing' do
      expect(described_class.parse_input('2023-03-20 22:32:41')).to eq('2023-03-20 22:32:41')
      expect(described_class.parse_input('2026-10-15T17:00:00Z')).to eq('2026-10-15T17:00:00Z')
      expect(described_class.parse_input(nil)).to be_nil
      expect(described_class.parse_input('')).to eq('')
    end
  end

  describe 'sizes' do
    it 'uses Russian units' do
      expect(described_class.format_bytes(0)).to eq('0 Б')
      expect(described_class.format_bytes(100)).to eq('100 Б')
      expect(described_class.format_bytes(1024)).to eq('1 КБ')
      expect(described_class.format_bytes(512.megabytes)).to eq('512 МБ')
      expect(described_class.format_bytes(36.gigabytes)).to eq('36 ГБ')
    end

    it 'puts a comma before the decimals' do
      expect(described_class.format_bytes(1.5.gigabytes)).to eq('1,5 ГБ')
      expect(described_class.format_bytes(2.5.terabytes)).to eq('2,5 ТБ')
    end

    it 'has no size for nothing' do
      expect(described_class.format_bytes(nil)).to be_nil
    end
  end

  describe 'numbers' do
    it 'puts a space between thousands' do
      expect(described_class.format_number(12_450)).to eq('12 450')
      expect(described_class.format_number(7)).to eq('7')
      expect(described_class.format_number(nil)).to be_nil
    end
  end

  describe 'view helpers' do
    it 'wrap the same functions' do
      moment = Time.utc(2026, 10, 15, 12, 5)

      expect(helper.super_admin_time(moment)).to eq('15.10.2026 17:05')
      expect(helper.super_admin_date(moment)).to eq('15.10.2026')
      expect(helper.super_admin_input_time(moment)).to eq('2026-10-15T17:05:00')
      expect(helper.super_admin_bytes(36.gigabytes)).to eq('36 ГБ')
      expect(helper.super_admin_number(1000)).to eq('1 000')
    end
  end
end
