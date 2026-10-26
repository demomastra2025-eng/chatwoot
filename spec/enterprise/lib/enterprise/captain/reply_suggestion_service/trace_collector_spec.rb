# frozen_string_literal: true

require 'rails_helper'

# The trace of a reply suggestion shows the parts of a council while they run; once the council answered, every part shows the
# status it ended with (Council#reset_reply_state), never "running".
RSpec.describe Enterprise::Captain::ReplySuggestionService::TraceCollector do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:collector) { described_class.new(assistant: assistant, conversation: conversation, user: user) }

  def part_context(id)
    OpenStruct.new(context: { part_run: true, active_part_id: id, state: { assistant_id: assistant.id },
                              part_info: { id: id, fragment: "Запрос #{id}" } })
  end

  it 'shows a part as running while it runs and with the status it ended with once the council answered' do
    %w[p1 p2].each { |id| collector.callbacks[:on_agent_thinking].call(assistant.agent_name, "Запрос #{id}", part_context(id)) }

    expect(collector.suggestion_meta({}.with_indifferent_access)['council']['parts'].pluck('status')).to eq(%w[running running])

    payload = { 'council_parts' => [{ 'id' => 'p1', 'status' => 'needs_information' },
                                    { 'id' => 'p2', 'status' => 'unavailable', 'stop_reason' => 'max_turns' }] }.with_indifferent_access
    parts = collector.suggestion_meta(payload)['council']['parts']

    expect(parts).to match([include('id' => 'p1', 'status' => 'needs_information'),
                            include('id' => 'p2', 'status' => 'unavailable', 'stop_reason' => 'max_turns')])
  end
end
