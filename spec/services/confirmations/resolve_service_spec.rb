require 'rails_helper'

RSpec.describe Confirmations::ResolveService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:request) do
    create(
      :confirmation_request,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox
    )
  end

  it 'confirms a pending request with source, actor, message and confidence audit fields' do
    message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: 'Да, подтверждаю')

    resolved = described_class.new(
      account: account,
      confirmation_request: request,
      decision: 'confirmed',
      source: 'ai',
      actor: user,
      message: message,
      confidence: 0.94,
      metadata: { 'classifier' => 'rules' }
    ).perform

    expect(resolved).to be_confirmed
    expect(resolved.resolved_at).to be_present
    expect(resolved.resolved_by).to eq(user)
    expect(resolved.resolved_message).to eq(message)
    expect(resolved.resolution_source).to eq('ai')
    expect(resolved.resolution_confidence).to eq(0.94)
    expect(resolved.resolution_metadata).to include('classifier' => 'rules')
  end

  it 'marks a request as declined' do
    resolved = described_class.new(account: account, confirmation_request: request, decision: 'declined', source: 'manual', actor: user).perform

    expect(resolved).to be_declined
    expect(resolved.resolution_source).to eq('manual')
  end

  it 'enqueues Medelement command resolution only for a linked provider command' do
    allow(Integrations::Medelement::ProviderCommandConfirmationJob).to receive(:perform_later)
    request.update!(metadata: request.metadata.to_h.merge('medelement_provider_command_id' => 123))

    described_class.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'manual', actor: user).perform

    expect(Integrations::Medelement::ProviderCommandConfirmationJob).to have_received(:perform_later).with(request.id)
  end

  it 'does not enqueue Medelement command resolution for an unrelated confirmation' do
    allow(Integrations::Medelement::ProviderCommandConfirmationJob).to receive(:perform_later)

    described_class.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'manual', actor: user).perform

    expect(Integrations::Medelement::ProviderCommandConfirmationJob).not_to have_received(:perform_later)
  end

  it 'marks a request as requiring reschedule' do
    resolved = described_class.new(account: account, confirmation_request: request, decision: 'reschedule_requested', source: 'text').perform

    expect(resolved).to be_reschedule_requested
  end

  it 'is idempotent when the same final decision is applied again' do
    allow(Integrations::Medelement::ProviderCommandConfirmationJob).to receive(:perform_later)
    request.update!(metadata: request.metadata.to_h.merge('medelement_provider_command_id' => 123))
    first = described_class.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'manual', actor: user).perform
    resolved_at = first.resolved_at

    second = described_class.new(account: account, confirmation_request: request.reload, decision: 'confirmed', source: 'ai', confidence: 0.9).perform

    expect(second).to be_confirmed
    expect(second.resolved_at.to_i).to eq(resolved_at.to_i)
    expect(second.resolution_source).to eq('manual')
    expect(Integrations::Medelement::ProviderCommandConfirmationJob).to have_received(:perform_later).with(request.id).once
  end

  it 're-enqueues linked provider command resolution after an enqueue failure' do
    attempts = 0
    allow(Integrations::Medelement::ProviderCommandConfirmationJob).to receive(:perform_later) do
      attempts += 1
      raise ActiveJob::EnqueueError, 'queue unavailable' if attempts == 1
    end
    request.update!(metadata: request.metadata.to_h.merge('medelement_provider_command_id' => 123))

    expect do
      described_class.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'manual', actor: user).perform
    end.to raise_error(ActiveJob::EnqueueError, 'queue unavailable')

    expect(request.reload).to be_confirmed
    expect do
      described_class.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'manual', actor: user).perform
    end.not_to raise_error
    expect(Integrations::Medelement::ProviderCommandConfirmationJob).to have_received(:perform_later).with(request.id).twice
  end

  it 'rejects conflicting decisions after a request is already resolved' do
    described_class.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'manual').perform

    expect do
      described_class.new(account: account, confirmation_request: request.reload, decision: 'declined', source: 'manual').perform
    end.to raise_error(ArgumentError, /already confirmed/)
  end

  it 'expires pending requests before resolving when expires_at is in the past' do
    request.update!(expires_at: 1.minute.ago)

    expect do
      described_class.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'link').perform
    end.to raise_error(Confirmations::ExpiredRequestError)

    expect(request.reload).to be_expired
    expect(request.resolution_source).to eq('system')
  end

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it 'treats confirmation buttons from multiple messages for the same appointment as one idempotent outcome' do
    cloud_account = create(:account, limits: { non_web_inboxes: 10 })
    channel = create(
      :channel_whatsapp,
      account: cloud_account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    channel.update!(
      message_templates: [
        {
          'name' => 'appointment_confirmation',
          'language' => 'ru',
          'status' => 'APPROVED',
          'components' => [
            { 'type' => 'BODY', 'text' => 'Подтвердите запись' },
            { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' }] }
          ]
        }
      ]
    )
    contact = create(:contact, account: cloud_account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: channel.inbox)
    cloud_conversation = create(
      :conversation,
      account: cloud_account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
    appointment = create(
      :scheduling_appointment,
      account: cloud_account,
      contact: contact,
      conversation: cloud_conversation,
      starts_at: 1.day.from_now,
      ends_at: 1.day.from_now + 30.minutes
    )
    touch_attributes = {
      account: cloud_account,
      conversation: cloud_conversation,
      target_conversation: cloud_conversation,
      target_inbox: channel.inbox,
      target_contact: contact,
      target_contact_inbox: contact_inbox,
      remindable: appointment,
      content_kind: :channel_template,
      body: nil,
      template_params: { name: 'appointment_confirmation', language: 'ru' },
      response_action: 'confirm_appointment',
      response_button_index: 0
    }
    first_touch = create(:reminder, **touch_attributes, scheduled_at: 1.hour.from_now)
    second_touch = create(:reminder, **touch_attributes, scheduled_at: 2.hours.from_now)
    third_touch = create(:reminder, **touch_attributes, scheduled_at: 3.hours.from_now)
    fourth_touch = create(:reminder, **touch_attributes, scheduled_at: 4.hours.from_now)
    first_request = create(
      :confirmation_request,
      account: cloud_account,
      conversation: cloud_conversation,
      contact: contact,
      inbox: channel.inbox,
      subject: appointment,
      reminder: first_touch,
      expires_at: appointment.ends_at
    )
    second_request = create(
      :confirmation_request,
      account: cloud_account,
      conversation: cloud_conversation,
      contact: contact,
      inbox: channel.inbox,
      subject: appointment,
      reminder: second_touch,
      expires_at: appointment.ends_at
    )
    third_request = create(
      :confirmation_request,
      account: cloud_account,
      conversation: cloud_conversation,
      contact: contact,
      inbox: channel.inbox,
      subject: appointment,
      reminder: third_touch,
      expires_at: appointment.ends_at
    )
    fourth_request = create(
      :confirmation_request,
      account: cloud_account,
      conversation: cloud_conversation,
      contact: contact,
      inbox: channel.inbox,
      subject: appointment,
      reminder: fourth_touch,
      expires_at: appointment.ends_at
    )

    described_class.new(account: cloud_account, confirmation_request: first_request, decision: 'confirmed', source: 'button').perform
    expect(first_request.reload).to be_confirmed
    expect(appointment.reload.status).to eq('confirmed')

    appointment.update!(status: 'scheduled')
    expect(appointment.reload.status).to eq('scheduled')

    described_class.new(account: cloud_account, confirmation_request: first_request.reload, decision: 'confirmed', source: 'button').perform

    expect(appointment.reload.status).to eq('scheduled')

    described_class.new(account: cloud_account, confirmation_request: second_request, decision: 'confirmed', source: 'button').perform
    described_class.new(account: cloud_account, confirmation_request: third_request, decision: 'confirmed', source: 'button').perform

    expect(appointment.reload.status).to eq('confirmed')
    expect(first_request.reload.resolution_metadata).to include('response_action_outcome' => 'appointment_confirmed')
    expect(second_request.reload.resolution_metadata).to include('response_action_outcome' => 'appointment_confirmed')
    expect(third_request.reload.resolution_metadata).to include('response_action_outcome' => 'already_confirmed')

    appointment.update!(status: 'cancelled')
    expect do
      described_class.new(account: cloud_account, confirmation_request: fourth_request, decision: 'confirmed', source: 'button').perform
    end.to raise_error(Confirmations::ExpiredRequestError)
    expect(appointment.reload.status).to eq('cancelled')
    expect(fourth_request.reload).to be_expired
    expect(fourth_request.resolution_metadata).to include('reason' => 'subject_not_confirmable')
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
end
