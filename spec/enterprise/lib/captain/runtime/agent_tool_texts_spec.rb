# frozen_string_literal: true

require 'rails_helper'

# The short English tool texts of the patient-facing agent runtime (config/captain/agent_tool_texts.yml) must describe real tools
# and real parameters: a typo would leave the model with the old long text for that parameter, or no text at all.
RSpec.describe Captain::Runtime::AgentToolTexts do
  let(:assistant) { create(:captain_assistant) }
  let(:agent_scope) { Captain::ToolAccess::SCOPE_AGENT }
  # Registry tools of the agent scope that keep their own text on purpose.
  let(:tools_without_override) { %w[get_appointment_provider_status] }
  # The words that the glossary of the tool texts replaced: one word per concept (patient, staff, specialist, clinic system).
  let(:retired_words) { /\b(customers?|clients?|callers?|operators?|MedElement|receptions?)\b/i }

  def agent_tool(tool_id)
    Captain::ToolCatalog.build_tool({ id: tool_id }, assistant: assistant, scope_name: agent_scope)
  end

  def schema_properties(tool)
    tool.params_schema.deep_stringify_keys.fetch('properties', {})
  end

  def schema_required(tool)
    Array(tool.params_schema.deep_stringify_keys['required']).map(&:to_s)
  end

  it 'loads one entry per tool with an English description' do
    expect(described_class.tool_ids).not_to be_empty
    described_class.tool_ids.each do |tool_id|
      entry = described_class.for_tool(tool_id)
      expect(entry.description).to be_present, "#{tool_id} has no description"
      expect(entry.description).not_to match(/\p{Cyrillic}/), "#{tool_id} description must be English"
      expect(entry.params.values).to all(be_present)
    end
  end

  it 'describes only registry tools of the agent scope and only parameters they really have', :aggregate_failures do
    registry_ids = Captain::ToolRegistry.tools_for_scope(agent_scope).pluck(:id)

    described_class.tool_ids.each do |tool_id|
      expect(registry_ids).to include(tool_id), "#{tool_id} is not an agent tool of the registry"
      tool = agent_tool(tool_id)
      expect(tool).to be_present, "#{tool_id} cannot be built"
      next if tool.blank?

      properties = schema_properties(tool)
      entry = described_class.for_tool(tool_id)
      expect(entry.params.keys - properties.keys).to be_empty, "#{tool_id}: unknown params #{entry.params.keys - properties.keys}"
      expect(entry.hidden_params - properties.keys).to be_empty, "#{tool_id}: unknown hidden params"
      expect(schema_required(tool) & entry.hidden_params).to be_empty, "#{tool_id}: a hidden param must be optional"
      expect(entry.params.keys & entry.hidden_params).to be_empty, "#{tool_id}: a hidden param needs no text"
    end
  end

  it 'covers every top-level parameter of every agent tool with a text or hides it', :aggregate_failures do
    registry_ids = Captain::ToolRegistry.tools_for_scope(agent_scope).pluck(:id) - tools_without_override

    registry_ids.each do |tool_id|
      entry = described_class.for_tool(tool_id)
      expect(entry).to be_present, "#{tool_id} has no short English text"
      next if entry.blank?

      tool = agent_tool(tool_id)
      next if tool.blank?

      missing = schema_properties(tool).keys - entry.params.keys - entry.hidden_params
      expect(missing).to be_empty, "#{tool_id}: parameters without a text: #{missing}"
    end
  end

  it 'keeps every parameter text English' do
    described_class.tool_ids.each do |tool_id|
      described_class.for_tool(tool_id).params.each do |name, text|
        expect(text).not_to match(/\p{Cyrillic}/), "#{tool_id}.#{name} must be English"
      end
    end
  end

  it 'uses the glossary words: no customer, client, caller, operator, MedElement or reception in what the model reads' do
    described_class.tool_ids.each do |tool_id|
      entry = described_class.for_tool(tool_id)
      ([['description', entry.description]] + entry.params.to_a).each do |name, text|
        expect(text).not_to match(retired_words), "#{tool_id}.#{name} uses a retired word: #{text}"
      end
    end
  end

  it 'hides the include_inactive options of the catalog tools, search_by of the specialist search and the deal links of create_appointment' do
    expect(described_class.for_tool('search_scheduling_services').hidden_params).to eq(%w[include_inactive])
    expect(described_class.for_tool('list_scheduling_resources').hidden_params).to eq(%w[include_inactive])
    expect(described_class.for_tool('search_scheduling_resources').hidden_params).to eq(%w[include_inactive search_by])
    expect(described_class.for_tool('create_appointment').hidden_params).to contain_exactly('crm_deal_id', 'crm_pipeline_id')
  end

  # Suggestion eval 26.10: a card was prepared at a time the search did not list. A reply suggestion refuses a start no search of the run
  # returned (Captain::ReplySuggestion::SlotSearchGuard), so the texts send an exact time to the search first.
  it 'tells the agent to search an exact time first and to call create_appointment and update_appointment only with a start a search returned' do
    sentence = 'If the patient named an exact time, first call search_available_slots with resource_ids of the specialist and from = to = ' \
               'that time, and call this tool only with a start that a search of this run returned'

    expect(described_class.for_tool('create_appointment').description).to include(sentence, 'offer 2-3 free times from a search of that day')
    expect(described_class.for_tool('update_appointment').description)
      .to include(sentence, 'keep the existing appointment unchanged and offer 2-3 free times from a search of that day')
    expect(described_class.for_tool('create_appointment').description).not_to include('call this tool directly')
    expect(described_class.for_tool('update_appointment').description).not_to match(/free first|check .* is free/i)
  end

  it 'says that the times of the free-slot search are a sample: a time that is not listed may be free, searched exactly before it is called taken' do
    description = described_class.for_tool('search_available_slots').description

    expect(description).to include('a time that is not listed may still be free (more > 0)', 'search that exact time (from = to)',
                                   'call it taken only when that search returns no start')
  end

  it 'makes the start of a booking or a move the time the patient named or chose, and sends a day or a part of a day to the free slots' do
    offered = 'named or chose from the free slots you offered'
    spread = 'call search_available_slots, offer 2-3 free slots spread over it in one message'

    %w[create_appointment update_appointment].each do |tool_id|
      entry = described_class.for_tool(tool_id)

      expect(entry.description).to include(offered).and include(spread)
      expect(entry.params['starts_at']).to include(offered)
      expect(entry.description).not_to match(/otherwise take|take the .* time from|pick the/i)
    end
    expect(described_class.for_tool('create_appointment').description).to include('book after the patient chooses')
    expect(described_class.for_tool('update_appointment').description).to include('move the appointment after the patient chooses')
    expect(described_class.for_tool('search_available_slots').description).to include('to offer the patient free slots')
  end

  it 'names the patient of create_appointment positively: the person the appointment is for when it is not the person in the conversation' do
    entry = described_class.for_tool('create_appointment')

    expect(entry.params['patient']).to eq(
      'The patient the appointment is for when it is not the person in this conversation (a child, a relative): ' \
      'first and last name, birth date YYYY-MM-DD; middle name, IIN, gender, phone if known.'
    )
    expect(entry.description).to include('For a child or another person pass patient')
  end

  it 'explains the range of the free-slot search: one time is from = that time, limit takes the earliest days, spread slots are offered' do
    entry = described_class.for_tool('search_available_slots')

    expect(entry.params['from']).to include('To check one time pass from = that time.')
    expect(entry.params['limit']).to include('earliest days first').and include('For a later hour start the range at that hour.')
    expect(entry.description).to include('Offer 2-3 slots spread over the period')
  end

  it 'describes the compact answer of the free-slot search: specialist-days, how many were left out, and how to book a listed start' do
    payload = Captain::Tools::Agent::SlotsPayload
    slots = described_class.for_tool('search_available_slots')

    expect(slots.description).to include('{resource_id, name, date, times, more}', 'more counts the other free starts of that day',
                                         'more_days says how many further specialist-days were left out',
                                         "up to #{payload::TIMES_PER_DAY} spread over the day")
    expect(slots.description).to include('To book a start pass date + "T" + time', 'or an exact ISO start from a tool result',
                                         'there is no starts_at field to copy')
    expect(slots.params['limit']).to include('Max specialist-days listed', "default #{payload::DEFAULT_DAYS}, max #{payload::MAX_DAYS}",
                                             'more_days says how many were left out', "up to #{payload::TIMES_PER_DAY} times")
    expect(slots.params['limit']).not_to include('Max slots')
  end

  it 'makes the start of a booking or a move date + T + time of a listed slot, or an exact ISO start, and never a field to copy' do
    %w[create_appointment update_appointment].each do |tool_id|
      starts_at = described_class.for_tool(tool_id).params['starts_at']

      expect(starts_at).to include('as YYYY-MM-DDTHH:MM clinic time', 'its date + "T" + time (2026-04-20T11:00)',
                                   'an exact ISO start from a tool result such as nearest_starts',
                                   'The slot list has no starts_at field to copy.')
      expect(starts_at).not_to include('copied unchanged')
    end
  end

  it 'sends a start off the specialist grid back to its nearest starts, offered once the slot search shows them free' do
    code = Captain::Tools::Agent::AppointmentResult::OFF_GRID_CODE

    %w[create_appointment update_appointment].each do |tool_id|
      description = described_class.for_tool(tool_id).description

      expect(description).to include("the tool fails with #{code} and nearest_starts", 'search_available_slots (from = that start) shows it is free')
    end
    expect(described_class.for_tool('update_appointment').description)
      .to include('keep the existing appointment unchanged and offer the patient one of them')
    expect(described_class.for_tool('create_appointment').description).to include('and book that start')
  end

  it 'sends the free-slot search to the chosen specialist and never claims that a service link is required' do
    slots = described_class.for_tool('search_available_slots').description

    expect(slots).to include('Pass resource_ids of the chosen specialist', 'asks for resource_ids when none is recorded')
    expect(slots).not_to include('all specialists who offer the service')
    expect(described_class.for_tool('get_scheduling_resource_availability').params['service_id']).not_to include('offers')
  end

  it 'starts a booking from the specialist: find the specialist, then the slots; a service only for a price or to pass a service_id' do
    resources = described_class.for_tool('search_scheduling_resources')
    services = described_class.for_tool('search_scheduling_services')
    slots = described_class.for_tool('search_available_slots')

    expect(resources.description).to include('Start here for any booking or slot question', 'then use the ID with search_available_slots',
                                             'A service link is never needed to find or book a specialist')
    expect(resources.params['service_id']).to include('Optional', 'leave it out')
    expect(services.description).to include('Call it for a price question, or to get a service_id to pass on',
                                            'To book, find the specialist first with search_scheduling_resources')
    expect(services.description).not_to include('before searching slots or booking a named service')
    expect(slots.description).to include('find the specialist first with search_scheduling_resources',
                                         'service_id is optional and only sets the visit length')
    expect(slots.params['service_id']).to include('Optional')
  end

  it 'never lets a missing service link block a booking' do
    expect(described_class.for_tool('create_appointment').params['service_id']).to include('a missing service link never blocks booking')
  end

  # PROD run g1-20261026 (Sezim): no service of the clinic is linked to the clinic system, and a booking card that names one is refused.
  it 'tells the agent to leave the service out of a booking or a move when the service is not linked to the clinic system' do
    expect(described_class.for_tool('create_appointment').params['service_id'])
      .to include('not linked to the clinic system is refused: book without service_id then, staff choose the service')
    expect(described_class.for_tool('update_appointment').params['service_id'])
      .to include('not linked to the clinic system is refused: leave service_id out then')
  end

  it 'tells the agent that handoff is for a person or for what only staff can do or answer, after one message for the details staff need' do
    description = described_class.for_tool('handoff').description

    expect(description).to eq(
      'Hand the conversation to staff. Call it when the patient asks for a person, or when only staff can do the request or answer ' \
      'the question: first ask for the details the clinic instructions or FAQ say staff need for it (all in one message); ' \
      'if they name none, hand over at once.'
    )
    expect(description).not_to match(/no answer|notice|informs/i)
  end

  it 'does not send the model to a custom-field catalog tool that is bound only when the account has such fields' do
    catalogs = %w[list_appointment_custom_fields list_deal_custom_fields list_task_custom_fields]

    described_class.tool_ids.each do |tool_id|
      next if catalogs.include?(tool_id)

      entry = described_class.for_tool(tool_id)
      texts = [entry.description, *entry.params.values].join("\n")
      expect(texts).not_to match(Regexp.union(catalogs)), "#{tool_id} names a companion tool that may not be bound"
    end
  end

  it 'asks for the conversation ID of the Patient block and hides the thread parameters that the patient scope always denies' do
    send_message = described_class.for_tool('send_message_to_conversation')

    expect(send_message.params['conversation_id']).to eq('Conversation ID from the Patient block.')
    expect(described_class.for_tool('assign_conversation').params['conversation_id']).to eq('Conversation ID from the Patient block.')
    expect(send_message.hidden_params).to contain_exactly(
      'communication_thread_id', 'channel_key', 'target_inbox_id', 'target_contact_inbox_id', 'attachment_ids'
    )
  end

  it 'does not mention cabinets in the create_appointment texts: the calendar picks the cabinet itself' do
    entry = described_class.for_tool('create_appointment')

    expect([entry.description, *entry.params.values].join(' ')).not_to match(/cabinet/i)
  end

  it 'has no entry for a tool that is not part of the file' do
    expect(described_class.for_tool('no_such_tool')).to be_nil
  end
end
