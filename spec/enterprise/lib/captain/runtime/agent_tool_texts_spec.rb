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

  it 'tells the agent to call create_appointment and update_appointment directly for an exact time: the tool checks it' do
    sentence = 'If the patient named an exact time, call this tool directly: it checks the time and says if it is taken.'

    expect(described_class.for_tool('create_appointment').description).to include(sentence)
    expect(described_class.for_tool('update_appointment').description).to include(sentence)
    expect(described_class.for_tool('update_appointment').description).not_to match(/free first|check .* is free/i)
  end

  it 'names the patient of create_appointment positively: the person the appointment is for when it is not the person in the conversation' do
    entry = described_class.for_tool('create_appointment')

    expect(entry.params['patient']).to eq(
      'The patient the appointment is for when it is not the person in this conversation (a child, a relative): ' \
      'first and last name, birth date YYYY-MM-DD; middle name, IIN, gender, phone if known.'
    )
    expect(entry.description).to include('For a child or another person pass patient')
  end

  it 'explains the range of the free-slot search: one time is from = that time, limit takes the earliest starts, spread slots are offered' do
    entry = described_class.for_tool('search_available_slots')

    expect(entry.params['from']).to include('To check one time pass from = that time.')
    expect(entry.params['limit']).to include('earliest starts first').and include('For a later hour start the range at that hour.')
    expect(entry.description).to include('Offer 2-3 slots spread over the period')
  end

  it 'tells the agent that handoff sends nothing to the patient and is for a person or for what only staff can do' do
    description = described_class.for_tool('handoff').description

    expect(description).to include('handoff sends nothing to the patient').and include('the patient asks for staff')
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
