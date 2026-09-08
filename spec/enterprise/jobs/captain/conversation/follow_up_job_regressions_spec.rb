require 'rails_helper'

RSpec.describe Captain::Conversation::FollowUpJob do
  let(:account) { create(:account, locale: 'ru') }
  let(:inbox) { create(:channel_telegram, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }
  let(:assistant) do
    create(:captain_assistant, account: account, config: {
             'follow_up_settings' => {
               'enabled' => true,
               'quiet_hours' => { 'enabled' => false },
               'steps' => [{ 'delay_seconds' => 3600, 'message' => 'Still interested?' }]
             }
           })
  end
  let!(:anchor) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: assistant,
                     message_type: :outgoing, source_id: 'initial-provider-id', content: 'Initial answer')
  end

  before do
    assistant.inboxes << inbox
    allow(Captain::ConversationCompletionEvaluator).to receive(:new).and_return(
      instance_double(Captain::ConversationCompletionEvaluator, perform: { complete: false, evaluated: true })
    )
  end

  def execute_follow_up
    Captain::Conversation::FollowUpJob.perform_now(conversation.id, assistant.id, anchor.id, 0)
  end

  it 'does not wait for an external provider callback on a local web widget' do
    widget = create(:inbox, account: account)
    assistant.inboxes << widget
    thread = create(:conversation, account: account, inbox: widget, status: :open)
    origin = create(:message, account: account, inbox: widget, conversation: thread,
                              sender: assistant, message_type: :outgoing, content: 'Widget answer', source_id: nil)
    expect(Captain::FollowUpDeliveryConfirmation.acknowledged?(origin)).to be(true)
    expect(described_class.perform_now(thread.id, assistant.id, origin.id, 0)).to eq(:completed)
    expect(thread.messages.count).to eq(2)
  end

  it 'waits without generating when a legacy anchor has no provider acknowledgement' do
    anchor.update!(source_id: nil)
    expect(Captain::ConversationCompletionEvaluator).not_to receive(:new)
    expect(execute_follow_up).to eq(:in_progress)
    expect(conversation.messages.count).to eq(1)
  end

  it 'restores template parameters when retrying after materialization failed' do
    params = { 'name' => 'approved_follow_up', 'language' => 'ru', 'processed_params' => {} }
    result = Captain::FollowUpDeliveryResolver::Result.new(
      allowed: true, mode: 'channel_template', content: 'Approved follow-up', template_params: params
    )
    allow(Captain::FollowUpDeliveryResolver).to receive(:new).and_return(instance_double(Captain::FollowUpDeliveryResolver, call: result))
    calls = 0
    allow(described_class).to receive(:new).and_wrap_original do |constructor, *arguments|
      job = constructor.call(*arguments)
      allow(job).to receive(:create_follow_up_message!).and_wrap_original do |original, *args|
        calls += 1
        raise 'temporary storage failure' if calls == 1

        original.call(*args)
      end
      job
    end
    expect { execute_follow_up }.to raise_error('temporary storage failure')
    expect(execute_follow_up).to eq(:completed)
    expect(conversation.messages.outgoing.order(:id).last.additional_attributes['template_params']).to eq(params)
    expect(Captain::FollowUpAttempt.last).to be_completed
  end

  it 'defers when generation crosses quiet hours and reuses the cached content next morning' do
    assistant.update!(config: assistant.config.deep_merge('follow_up_settings' => {
                                                            'quiet_hours' => { 'enabled' => true, 'timezone' => 'Asia/Almaty' }
                                                          }))
    travel_to(Time.iso8601('2026-09-05T22:59:00+05:00')) do
      generations = 0
      allow(described_class).to receive(:new).and_wrap_original do |constructor, *arguments|
        job = constructor.call(*arguments)
        allow(job).to receive(:follow_up_content) do
          generations += 1
          travel_to(Time.iso8601('2026-09-05T23:01:00+05:00'))
          'A generated follow-up'
        end
        job
      end
      result = execute_follow_up
      expect(result).to include(status: :deferred, scheduled_at: Time.iso8601('2026-09-06T08:00:00+05:00'))
      expect(conversation.messages.count).to eq(1)
      expect(Captain::FollowUpAttempt.last.generated_content).to eq('A generated follow-up')
      expect(Captain::FollowUpAttempt.last).to be_failed
      travel_to(Time.iso8601('2026-09-06T08:01:00+05:00'))
      expect(execute_follow_up).to eq(:completed)
      expect(generations).to eq(1)
      expect(conversation.messages.outgoing.order(:id).last.content).to eq('A generated follow-up')
    end
  end

  it 'marks the initial answer and schedules step zero only after acknowledgement, once' do
    anchor.update!(source_id: nil)
    builder = Captain::Conversation::ResponseBuilderJob.new
    builder.instance_variable_set(:@assistant, assistant)
    builder.instance_variable_set(:@conversation, conversation)
    expect { builder.send(:schedule_first_follow_up, anchor) }.not_to change(Reminder, :count)
    expect(anchor.reload.additional_attributes.dig('captain_follow_up_origin', 'step_index')).to eq(-1)
    anchor.update!(source_id: 'acknowledged')
    expect do
      2.times { Captain::FollowUpDeliveryConfirmation.new(message: anchor).perform }
    end.to change(Reminder, :count).by(1)
    reminder = Reminder.last
    expect(reminder.metadata.dig('captain_follow_up', 'step_index')).to eq(0)
    anchor.update!(status: :failed)
    Captain::FollowUpDeliveryConfirmation.new(message: anchor).perform
    expect(reminder.reload).to be_cancelled
    anchor.update!(status: :sent)
    expect { Captain::FollowUpDeliveryConfirmation.new(message: anchor).perform }.not_to change(Reminder, :count)
  end

  def processing_reminder
    create(:reminder, account: account, conversation: conversation, target_conversation: conversation,
                      status: :processing, action_type: :captain_follow_up,
                      metadata: { 'captain_follow_up' => { 'assistant_id' => assistant.id,
                                                           'anchor_message_id' => anchor.id, 'step_index' => 0 } })
  end

  it 'does not resurrect a reminder cancelled while quiet hours were evaluated' do
    touch = processing_reminder
    result = Captain::FollowUpQuietHoursPolicy::Result.new(quiet: true, next_allowed_at: 1.day.from_now, timezone: 'UTC')
    policy = instance_double(Captain::FollowUpQuietHoursPolicy)
    allow(Captain::FollowUpQuietHoursPolicy).to receive(:new).and_return(policy)
    allow(policy).to receive(:call) do
      Reminder.find(touch.id).cancel!('incoming reply')
      result
    end
    expect(described_class).not_to receive(:perform_now)
    Reminders::ExecuteService.new(reminder: touch).perform
    expect(touch.reload).to be_cancelled
  end

  it 'does not erase a newer processing claim during quiet-hours rescheduling' do
    touch = processing_reminder
    newer_claim = nil
    result = Captain::FollowUpQuietHoursPolicy::Result.new(quiet: true, next_allowed_at: 1.day.from_now, timezone: 'UTC')
    policy = instance_double(Captain::FollowUpQuietHoursPolicy)
    allow(Captain::FollowUpQuietHoursPolicy).to receive(:new).and_return(policy)
    allow(policy).to receive(:call) do
      fresh = Reminder.find(touch.id)
      newer_claim = fresh.mark_processing!
      result
    end
    Reminders::ExecuteService.new(reminder: touch).perform
    expect(touch.reload).to be_processing
    expect(touch.processing_claim_token).to eq(newer_claim)
  end

  it 'reschedules a final-boundary deferral rather than completing the reminder' do
    touch = processing_reminder
    allow(described_class).to receive(:perform_now).and_return(
      status: :deferred, scheduled_at: 1.day.from_now, timezone: 'Asia/Almaty'
    )
    Reminders::ExecuteService.new(reminder: touch).perform
    expect(touch.reload).to be_pending
    expect(touch.metadata['quiet_hours_timezone']).to eq('Asia/Almaty')
  end

  [true, false, 1, [], ['23:00']].each do |value|
    it "returns a validation error for quiet_hours=#{value.inspect}" do
      assistant.config = assistant.config.deep_merge('follow_up_settings' => { 'quiet_hours' => value })
      expect(Captain::FollowUpSettingsValidator.new(assistant: assistant).errors).to include('quiet_hours must be an object')
    end
  end

  it 'rejects malformed settings, delay and variant shapes without raising' do
    [false, [], 1].each do |value|
      assistant.config = { 'follow_up_settings' => value }
      expect(Captain::FollowUpSettingsValidator.new(assistant: assistant).errors).to include('follow_up_settings must be an object')
    end
    assistant.config = { 'follow_up_settings' => {
      'quiet_hours' => { 'enabled' => 'true' },
      'steps' => [{ 'delay_seconds' => true, 'template_variants_by_inbox' => [] }]
    } }
    expect(Captain::FollowUpSettingsValidator.new(assistant: assistant).errors).to include(
      'quiet_hours enabled must be a boolean',
      'follow_up step 1 delay_seconds must be positive',
      'follow_up step 1 template_variants_by_inbox must be an object'
    )
  end

  it 'validates global legacy variants against connected WhatsApp catalogs' do
    whatsapp = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
    assistant.inboxes << whatsapp
    settings = assistant.config.deep_dup
    settings['follow_up_settings']['steps'][0]['template_variants'] = {
      'ru' => { 'name' => 'not_approved', 'language' => 'ru', 'processed_params' => {} }
    }
    assistant.config = settings
    expect(Captain::FollowUpSettingsValidator.new(assistant: assistant).errors.join(' ')).to include('Approved channel template was not found')
  end

  it 'uses a global language variant when only another language has a per-inbox override' do
    params = { 'name' => 'english', 'language' => 'en_US' }
    step = {
      'template_variants_by_inbox' => { inbox.id.to_s => { 'ru' => { 'name' => 'russian', 'language' => 'ru' } } },
      'template_variants' => { 'en' => params }
    }
    resolver = Captain::FollowUpDeliveryResolver.new(conversation: conversation, assistant: assistant, step: step)
    allow(resolver).to receive(:language).and_return('en')
    expect(resolver.send(:configured_template_params)).to eq(params)
  end

  it 'inherits the workspace timezone when the inbox follows workspace working hours' do
    account.update!(workspace_timezone: 'Europe/Warsaw')
    inbox.update!(timezone: 'UTC', inherit_working_hours_from_account: true)
    result = Captain::FollowUpQuietHoursPolicy.new(assistant: assistant, conversation: conversation).call
    expect(result.timezone).to eq('Europe/Warsaw')
    inbox.update!(inherit_working_hours_from_account: false)
    expect(Captain::FollowUpQuietHoursPolicy.new(assistant: assistant, conversation: conversation).call.timezone).to eq('UTC')
  end

  it 'falls back to metadata if language detection fails' do
    conversation.update!(additional_attributes: { 'conversation_language' => 'kk' })
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                     content: 'A meaningful incoming message for detection')
    allow(CLD3::NNetLanguageIdentifier).to receive(:new).and_raise(StandardError)
    expect(Captain::FollowUpLanguageResolver.new(conversation: conversation, assistant: assistant).call).to eq('kk')
  end

  it 'detects the latest meaningful incoming language ahead of stale conversation metadata' do
    conversation.update!(additional_attributes: { 'conversation_language' => 'ru' })
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                     content: 'Could you please tell me more about your services and explain how much they cost?')
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'OK 👍')
    expect(Captain::FollowUpLanguageResolver.new(conversation: conversation, assistant: assistant).call).to eq('en')
  end
end
