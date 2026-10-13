# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PromptNumbers do
  describe '.shown?' do
    it 'shows an appointment number only for a bound tool that takes the appointment id' do
      %w[get_appointment update_appointment cancel_appointment].each do |tool|
        expect(described_class.shown?(:appointment, [tool])).to be(true)
      end
      expect(described_class.shown?(:appointment, %w[list_my_appointments create_appointment search_appointments])).to be(false)
    end

    it 'shows a deal number only for a bound tool that takes the deal id as a main parameter' do
      %w[get_deal update_deal transition_deal_stage list_deal_stages get_deal_timeline].each do |tool|
        expect(described_class.shown?(:deal, [tool])).to be(true)
      end
    end

    it 'does not count an optional link parameter to a deal' do
      expect(described_class.shown?(:deal, %w[create_task create_appointment search_deals])).to be(false)
    end

    it 'shows the patient number for get_contact only' do
      expect(described_class.shown?(:contact, %w[get_contact])).to be(true)
      expect(described_class.shown?(:contact, %w[get_my_contact update_contact search_appointments])).to be(false)
    end

    it 'shows the conversation number for the tools that have no default conversation: assign and send a message' do
      expect(described_class.shown?(:conversation, %w[assign_conversation])).to be(true)
      expect(described_class.shown?(:conversation, %w[send_message_to_conversation])).to be(true)
      expect(described_class.shown?(:conversation, %w[send_notification add_private_note remove_label_from_conversation])).to be(false)
    end

    it 'shows nothing when no tool is bound or the bound tools are unknown' do
      expect(described_class.shown?(:appointment, [])).to be(false)
      expect(described_class.shown?(:appointment, nil)).to be(false)
    end

    it 'accepts symbol tool ids' do
      expect(described_class.shown?(:appointment, [:get_appointment])).to be(true)
    end
  end
end
