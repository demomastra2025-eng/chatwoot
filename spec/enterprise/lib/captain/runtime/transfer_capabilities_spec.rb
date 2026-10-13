# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::TransferCapabilities do
  describe '.line' do
    it 'joins the appointment verbs the colleague has and names what it can look up, in glossary words' do
      ids = %w[create_appointment update_appointment cancel_appointment search_scheduling_services search_available_slots]

      expect(described_class.line(ids)).to eq('Can: book, reschedule and cancel appointments; look up service prices and free slots.')
    end

    it 'says only the verbs of the appointment tools the colleague has' do
      expect(described_class.line(%w[create_appointment])).to eq('Can: book appointments.')
      expect(described_class.line(%w[update_appointment cancel_appointment])).to eq('Can: reschedule and cancel appointments.')
    end

    it 'lists the deals and tasks the colleague can change, then what it can look up' do
      ids = %w[create_deal update_deal transition_deal_stage create_task change_task_status search_deals list_scheduling_resources]

      expect(described_class.line(ids)).to eq('Can: create and update deals; create and update tasks; look up specialists and deals.')
    end

    it 'reads a lookup of the patient\'s own records as a lookup of that record' do
      expect(described_class.line(%w[list_my_appointments get_deal])).to eq('Can: look up appointments and deals.')
    end

    it 'leaves out the tools that every agent has: handoff, the FAQ, the notes and labels of the conversation' do
      ids = %w[handoff faq_lookup resolve_conversation cancel_response add_private_note add_contact_note send_notification update_priority
               add_label_to_conversation remove_label_from_conversation get_my_contact update_my_contact]

      expect(described_class.line(ids)).to eq('')
    end

    it 'skips a tool id that has no phrase: a tool of an external server, an unknown name' do
      expect(described_class.line(%w[mcp__crm__create_lead handoff_x calculate merge_contacts create_company])).to eq('')
      expect(described_class.line(%w[calculate create_appointment])).to eq('Can: book appointments.')
    end

    it 'never writes a tool id into the line' do
      line = described_class.line(%w[create_appointment update_appointment cancel_appointment search_scheduling_resources
                                     search_scheduling_services search_available_slots list_my_appointments create_deal search_deals])

      expect(line).not_to match(/\w_\w/)
      expect(line).not_to include('scheduling', 'available')
    end

    it 'is blank for no tools, and takes every id once' do
      expect(described_class.line([])).to eq('')
      expect(described_class.line(nil)).to eq('')
      expect(described_class.line(%w[create_deal create_deal])).to eq('Can: create and update deals.')
    end

    it 'is English whatever the locale of the request is' do
      I18n.with_locale(:ru) do
        expect(described_class.line(%w[create_deal update_deal search_deals])).to eq('Can: create and update deals; look up deals.')
      end
    end
  end
end
