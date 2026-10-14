# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::OutcomeFacts do
  let(:account) { create(:account, locale: 'ru') }
  let(:assistant) { create(:captain_assistant, account: account, description: 'Close only after payment is received.') }
  let(:conversation) { create(:conversation, account: account) }

  def message(content, **attributes)
    create(:message, { account: account, inbox: conversation.inbox, conversation: conversation,
                       content: content, message_type: :incoming, private: false }.merge(attributes))
  end

  def transition(status, metadata: {})
    ConversationStatusTransition.create!(account: account, conversation: conversation, actor: assistant,
                                         from_status: 'pending', to_status: status, source: 'captain', metadata: metadata)
  end

  it 'collects run replies and notes without treating an automatic handoff notice as an agent reply' do
    message('Please help')
    event = transition('open', metadata: { 'outcome_reason_explanation' => 'Staff needs to confirm payment' })
    message('Staff needs to confirm payment', message_type: :outgoing, private: true, sender: assistant)
    message('Please wait for staff', message_type: :outgoing, sender: create(:user))

    facts = described_class.new(event, event.metadata.fetch('outcome_classification')).input

    expect(facts).to include(public_reply_sent: false, staff_notes: ['Staff needs to confirm payment'],
                             handoff_reason: 'Staff needs to confirm payment')
    expect(facts).not_to have_key(:clinic_instruction)
  end

  it 'includes the resolved closing instruction and successful action kinds only for completion' do
    message('Please book')
    message('Your booking is confirmed', message_type: :outgoing, sender: assistant)
    conversation.update!(additional_attributes: conversation.additional_attributes.merge(
      'captain_agent_session' => { 'done' => [{ 'label' => 'Booked', 'text' => 'Patient name and appointment' }] }
    ))
    event = transition('resolved')
    assistant.update!(description: 'Changed after closing.')
    facts = described_class.new(event, event.metadata.fetch('outcome_classification')).input

    expect(facts).to include(public_reply_sent: true, done_actions: ['Booked'],
                             clinic_instruction: 'Close only after payment is received.')
    expect(facts.to_json).not_to include('Patient name and appointment')
  end

  it 'caps notes, fact lists and the clinic instruction' do
    assistant.update!(description: 'Rule ' * 4000)
    message('Please help')
    25.times { |index| message("Note #{index} " + ('x' * 1200), message_type: :outgoing, private: true, sender: assistant) }
    event = transition('resolved', metadata: { 'outcome_run_facts' => {
                         'faq_lookups' => Array.new(30, 'not_found'), 'tool_failures' => Array.new(30, 'slot_taken'),
                         'safety_blocks' => Array.new(30, 'moderation')
                       } })
    facts = described_class.new(event, event.metadata.fetch('outcome_classification')).input

    expect(facts[:staff_notes].size).to eq(20)
    expect(facts[:staff_notes].all? { |note| note.length <= 1000 }).to be true
    expect(facts.values_at(:faq_lookups, :tool_failures, :safety_blocks).map(&:size)).to eq([20, 20, 20])
    expect(facts[:clinic_instruction].length).to eq(12_000)
  end

  it 'records only fixed FAQ, failure and safety kinds from tool results' do
    context = {}
    described_class.record_tool(context, 'faq_lookup', { result: 'not_found' })
    described_class.record_tool(context, 'faq_lookup', { result: 'found' })
    described_class.record_tool(context, 'faq_lookup', {
                                  result: 'not_found', retrieval_trace: { fallback_reason: 'lookup_timeout' }
                                })
    slot_taken = Captain::ToolResult.failure(error: 'Private provider details', retryable: false,
                                             audit: { reason: 'time_taken', error_class: 'business' })
    unavailable = Captain::ToolResult.failure(error: 'Private provider details', retryable: false,
                                              audit: { reason: 'provider_unavailable', error_class: 'technical' })
    described_class.record_tool(context, 'create_appointment', slot_taken)
    described_class.record_tool(context, 'search_available_slots', unavailable)
    facts = described_class.from_run(context, 'moderation_blocked' => true, 'safety_block' => 'prompt_injection')

    expect(facts).to include('faq_lookups' => %w[not_found found],
                             'tool_failures' => %w[slot_taken calendar_unavailable],
                             'safety_blocks' => ['prompt_injection'])
    expect(facts.to_json).not_to include('Private provider details')
  end
end
