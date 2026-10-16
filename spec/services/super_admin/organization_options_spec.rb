# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::OrganizationOptions do
  describe '.for_select' do
    it 'is empty without organizations' do
      expect(described_class.for_select).to eq([])
    end

    it 'lists the organizations by name, whatever the case, and names the БИН or else the id' do
      with_bin = create(:organization, name: 'bravo', bin: '980140000124')
      without = create(:organization, name: 'Charlie')
      first = create(:organization, name: 'Alpha')

      expect(described_class.for_select).to eq(
        [["Alpha · ##{first.id}", first.id], ['bravo · БИН 980140000124', with_bin.id], ["Charlie · ##{without.id}", without.id]]
      )
    end

    it 'tells organizations of the same name apart and keeps them in the order of creation' do
      older = create(:organization, name: 'Алатау')
      newer = create(:organization, name: 'Алатау')

      expect(described_class.for_select.map(&:last)).to eq([older.id, newer.id])
      expect(described_class.for_select.map(&:first).uniq.size).to eq(2)
    end

    it 'reads the organizations with one query' do
      create_list(:organization, 3, :with_requisites)
      count = 0
      counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { described_class.for_select }

      expect(count).to eq(1)
    end
  end
end
