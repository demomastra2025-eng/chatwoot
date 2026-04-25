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

  it 'marks a request as requiring reschedule' do
    resolved = described_class.new(account: account, confirmation_request: request, decision: 'reschedule_requested', source: 'text').perform

    expect(resolved).to be_reschedule_requested
  end

  it 'is idempotent when the same final decision is applied again' do
    first = described_class.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'manual', actor: user).perform
    resolved_at = first.resolved_at

    second = described_class.new(account: account, confirmation_request: request.reload, decision: 'confirmed', source: 'ai', confidence: 0.9).perform

    expect(second).to be_confirmed
    expect(second.resolved_at.to_i).to eq(resolved_at.to_i)
    expect(second.resolution_source).to eq('manual')
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
end
