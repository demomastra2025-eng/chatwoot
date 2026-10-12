require 'rails_helper'

RSpec.describe Captain::Assistant do
  let(:account) { create(:account) }
  let(:first) { create(:captain_assistant, account: account, config: { 'feature_faq' => true, 'handoff_enabled' => false }) }
  let(:second) { create(:captain_assistant, account: account, config: { 'feature_faq' => false, 'handoff_enabled' => false }) }

  before do
    Captain::AccountSettings.new(account).update!(
      'understanding' => { 'voice_messages' => false, 'images' => false },
      'handoff' => { 'auto_completion_enabled' => false, 'auto_reply_on_last_incoming' => true },
      'faq' => { 'generate_from_resolved' => true },
      'conversation' => { 'message_collapse_window_seconds' => 9 },
      'safety' => { 'moderation_enabled' => true }
    )
  end

  it 'gives both external agents mandatory tools and common conversation settings' do
    [first, second].each do |assistant|
      expect(assistant.selected_agent_tool_ids).to include('faq_lookup', 'handoff')
      expect(assistant.allowed_agent_tool_ids).to include('faq_lookup', 'handoff')
      expect(assistant.selected_agent_tool_ids).not_to include('resolve_conversation')
      expect(assistant.use_audio_transcriptions?).to be(false)
      expect(assistant.auto_reply_on_last_incoming_enabled?).to be(true)
      expect(assistant.message_collapse_window_seconds_value).to eq(9)
    end
  end

  it 'applies the history preset, FAQ switch, memory disablement, and safety to both agents' do
    [first, second].each do |assistant|
      expect(assistant.history_message_limit_value).to eq(40)
      expect(assistant.feature_faq).to be(true)
      expect(assistant.feature_memory).to be(false)
      expect(Captain::AssistantSafetyPreferences.for(assistant: assistant, feature: :assistant))
        .to include('assistant_moderation' => true, 'assistant_prompt_injection_guardrail' => 'block')
    end
  end
end
