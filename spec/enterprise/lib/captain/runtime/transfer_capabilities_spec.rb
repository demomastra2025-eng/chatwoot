# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::TransferCapabilities do
  describe '.line' do
    it 'joins the verbs of one object and names what the colleague can look up' do
      ids = %w[create_appointment update_appointment cancel_appointment search_scheduling_services search_available_slots]

      expect(described_class.line(ids)).to eq(
        'Tools: create, update and cancel appointment; look up scheduling services and available slots.'
      )
    end

    it 'lists each object with the verbs the colleague has for it' do
      ids = %w[create_deal update_deal transition_deal_stage create_task change_task_status]

      expect(described_class.line(ids)).to eq('Tools: create and update deal; transition deal stage; create task; change task status.')
    end

    it 'says "create and update" for two verbs and a bare verb for one' do
      expect(described_class.line(%w[create_company update_company])).to eq('Tools: create and update company.')
      expect(described_class.line(%w[merge_contacts])).to eq('Tools: merge contacts.')
    end

    it 'reads a lookup of the patient\'s own records without the "my"' do
      expect(described_class.line(%w[list_my_appointments search_deals])).to eq('Tools: look up appointments and deals.')
    end

    it 'leaves out the tools that every agent has: handoff, the FAQ, the notes and labels of the conversation' do
      ids = %w[handoff faq_lookup resolve_conversation cancel_response add_private_note add_contact_note send_notification update_priority
               add_label_to_conversation remove_label_from_conversation get_my_contact update_my_contact]

      expect(described_class.line(ids)).to eq('')
    end

    it 'skips a tool of an external server and a name that is not a verb with an object' do
      expect(described_class.line(%w[mcp__crm__create_lead handoff_x calculate])).to eq('')
    end

    it 'is blank for no tools, and takes every id once' do
      expect(described_class.line([])).to eq('')
      expect(described_class.line(nil)).to eq('')
      expect(described_class.line(%w[create_deal create_deal])).to eq('Tools: create deal.')
    end

    it 'keeps the line short: four objects with actions and four lookups at most' do
      actions = %w[create_appointment create_deal create_task create_company create_contact]
      lookups = %w[search_a search_b search_c search_d search_e]

      line = described_class.line(actions + lookups)

      expect(line).to eq('Tools: create appointment; create deal; create task; create company; look up a, b, c and d.')
    end

    it 'is English whatever the locale of the request is' do
      I18n.with_locale(:ru) do
        expect(described_class.line(%w[create_deal update_deal search_deals])).to eq('Tools: create and update deal; look up deals.')
      end
    end
  end
end
