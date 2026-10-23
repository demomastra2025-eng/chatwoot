require 'rails_helper'

RSpec.describe AutomationRules::TouchScheduleOverride do
  let(:frozen_touch) do
    { 'body' => 'Запись перенесена', 'timing_mode' => 'relative', 'relative_anchor' => 'touch.created_at',
      'relative_offset_seconds' => 60, 'scheduled_at' => '', 'manual_schedule_override' => true }
  end

  describe '.relative_with_override?' do
    it 'is true for a relative timing with the flag and no send time, however the flag is spelled' do
      expect(described_class.relative_with_override?(frozen_touch)).to be(true)
      expect(described_class.relative_with_override?(frozen_touch.symbolize_keys)).to be(true)

      [true, 'true', '1', 1, 'on', 'yes', 't'].each do |spelling|
        expect(described_class.relative_with_override?(frozen_touch.merge('manual_schedule_override' => spelling))).to be(true)
      end
    end

    it 'is false when the flag is off, the timing is not relative or the touch carries its own send time' do
      [false, 'false', '0', 0, nil, ''].each do |spelling|
        expect(described_class.relative_with_override?(frozen_touch.merge('manual_schedule_override' => spelling))).to be(false)
      end
      expect(described_class.relative_with_override?(frozen_touch.merge('timing_mode' => 'absolute'))).to be(false)
      expect(described_class.relative_with_override?(frozen_touch.merge('timing_mode' => nil, 'delay_minutes' => 0))).to be(false)
      expect(described_class.relative_with_override?(frozen_touch.merge('scheduled_at' => '2026-10-25T10:00:00Z'))).to be(false)
      expect(described_class.relative_with_override?('not a hash')).to be(false)
    end
  end

  describe '.without_relative_override' do
    it 'drops only the flag of a frozen touch' do
      expect(described_class.without_relative_override(frozen_touch)).to eq(frozen_touch.except('manual_schedule_override'))
    end

    it 'keeps the flag of a touch that sends at its own time' do
      manual = frozen_touch.merge('scheduled_at' => '2026-10-25T10:00:00Z')

      expect(described_class.without_relative_override(manual)).to eq(manual)
    end
  end
end
