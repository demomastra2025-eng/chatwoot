# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::TemplateMessageDisplayContent do
  let(:account) { create(:account, limits: { 'non_web_inboxes' => 10 }) }
  let(:template) do
    {
      'name' => 'legacy_notice', 'language' => 'en', 'status' => 'APPROVED',
      'components' => [
        { 'type' => 'HEADER', 'format' => 'TEXT', 'text' => 'Notice {{1}}' },
        { 'type' => 'BODY', 'text' => 'Hello {{1}}, reference {{2}}.' },
        { 'type' => 'FOOTER', 'text' => 'Thank you' }
      ]
    }
  end
  let(:channel) do
    create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false, message_templates: [template])
  end
  let(:params) do
    {
      'name' => 'legacy_notice', 'language' => 'en',
      'processed_params' => { 'header' => ['A'], 'body' => { '1' => 'Example', '2' => '42' } }
    }
  end
  let(:message) do
    build(:message, inbox: channel.inbox, content: '', message_type: :outgoing,
                    additional_attributes: { 'template_params' => params, 'delivery_policy' => { 'template' => template.deep_dup },
                                             'template_buttons' => [{ 'text' => 'Confirm' }] },
                    skip_send_reply: true, skip_runtime_events: true)
  end
  let(:expected_text) { "Notice A\n\nHello Example, reference 42.\n\nThank you" }

  def render_content
    described_class.new(message).render
  end

  it 'renders saved template text with the saved parameters without changing the message or buttons' do
    original = message.attributes.deep_dup
    expect(render_content).to eq(expected_text)
    expect(message.content_for_display).to eq(expected_text)
    expect(message.attributes).to eq(original)
  end

  it 'prefers the original delivery-policy snapshot over a subsequently changed template cache' do
    snapshot = template.deep_dup
    snapshot['components'][1]['text'] = 'Original {{1}}'
    message.additional_attributes['delivery_policy'] = { 'template' => snapshot }

    expect(render_content).to include('Original Example')
    expect(render_content).not_to include('reference 42')
  end

  it 'can render a saved snapshot after the template was removed from the local cache' do
    message.additional_attributes['delivery_policy'] = { 'template' => template }
    channel.message_templates = []
    expect(render_content).to eq(expected_text)
  end

  it 'accepts the name and language recorded in the delivery snapshot when absent from old parameters' do
    message.additional_attributes['template_params'] = params.except('name', 'language')
    message.additional_attributes['delivery_policy'] = { 'template' => template }
    expect(render_content).to eq(expected_text)
  end

  it 'does not replace an explicit language_code with the snapshot language' do
    message.additional_attributes['template_params'] = params.except('language').merge('language_code' => 'fr')
    message.additional_attributes['delivery_policy'] = { 'template' => template }
    expect(render_content).to be_nil
  end

  it 'honors language_code even when legacy language is an empty string' do
    message.additional_attributes['template_params'] = params.merge('language' => '', 'language_code' => 'fr')
    message.additional_attributes['delivery_policy'] = { 'template' => template }
    expect(render_content).to be_nil
  end

  it 'does not replace a mismatched snapshot with a currently cached template' do
    message.additional_attributes['delivery_policy'] = { 'template' => template.merge('name' => 'another_notice') }
    expect(render_content).to be_nil
  end

  it 'normalizes the saved language subtag using the existing renderer' do
    message.additional_attributes['template_params']['language'] = 'en_US'
    expect(render_content).to eq(expected_text)
  end

  it 'leaves unresolved parameters visible instead of inventing historical values' do
    message.additional_attributes['template_params']['processed_params'] = {}
    expect(render_content).to include('Hello {{1}}, reference {{2}}.')
  end

  it 'does not guess a template language when no language was saved' do
    message.additional_attributes['template_params'].delete('language')
    message.additional_attributes['delivery_policy']['template'].delete('language')
    expect(render_content).to be_nil
  end

  it 'does not substitute a different available language' do
    message.additional_attributes['template_params']['language'] = 'fr'
    expect(render_content).to be_nil
  end

  it 'does not fall back by name when a saved language is malformed' do
    message.additional_attributes['template_params']['language'] = 'not-a-language'
    expect(render_content).to be_nil
  end

  it 'leaves an unknown template blank' do
    message.additional_attributes['template_params']['name'] = 'missing'
    expect(render_content).to be_nil
  end

  [nil, 'opaque', [], 7].each do |invalid|
    it "ignores malformed template parameters #{invalid.inspect}" do
      message.additional_attributes['template_params'] = invalid
      expect(render_content).to be_nil
    end
  end

  it 'ignores malformed delivery metadata and template components without raising' do
    message.additional_attributes['delivery_policy'] = ['opaque']
    channel.message_templates = [nil, 'opaque', template.merge('components' => ['opaque'])]
    expect(render_content).to be_nil
  end

  it 'does not guess historical text from the current cache when the saved snapshot is missing' do
    message.additional_attributes.delete('delivery_policy')
    expect(render_content).to be_nil
  end

  it 'does not load inbox associations for blank non-template messages' do
    message.additional_attributes.delete('template_params')
    expect(message).not_to receive(:inbox)
    expect(message.content_for_display).to eq('')
  end

  it 'ignores a malformed saved component list' do
    message.additional_attributes['delivery_policy']['template']['components'] = ['opaque']
    expect(render_content).to be_nil
  end

  { content: 'Stored original', message_type: :incoming, private: true, content_type: :voice_call }.each do |key, value|
    it "preserves messages with #{key}=#{value.inspect}" do
      message.public_send("#{key}=", value)
      expect(render_content).to be_nil
      expect(message.content_for_display).to eq(message.content)
    end
  end

  it 'does not reconstruct deleted text' do
    message.deleted = true
    expect(render_content).to be_nil
  end

  it 'does not reconstruct templates on another channel type' do
    message.inbox = create(:inbox, account: account)
    expect(render_content).to be_nil
  end

  it 'does not use a channel belonging to another account' do
    message.account = create(:account)
    expect(render_content).to be_nil
  end

  it 'only reads local data and leaves persisted content and attributes untouched across repeated serialization' do
    message.save!
    stored = message.reload.attributes.deep_dup
    expect(channel).not_to receive(:provider_service)
    expect(channel).not_to receive(:sync_templates)
    expect(channel).not_to receive(:message_templates)
    writes = []
    subscriber = lambda do |*event|
      sql = event.last[:sql]
      writes << sql if sql.match?(/\A\s*(?:INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE)\b/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      expect do
        2.times { expect(message.content_for_display).to eq(expected_text) }
      end.not_to(change { WebMock::RequestRegistry.instance.requested_signatures.hash.dup })
    end
    expect(writes).to be_empty
    expect(message.reload.attributes).to eq(stored)
  end

  it 'uses the same display text in real-time message payloads without altering webhook delivery content' do
    message.save!
    expect(message.push_event_data[:content]).to eq(expected_text)
    expect(message.webhook_push_event_data[:content]).to eq('')
    expect(message.content).to eq('')
  end

  it 'uses the same display text in message and conversation search JSON' do
    message.save!
    payload = JSON.parse(ApplicationController.render(partial: 'api/v1/models/message', formats: [:json], locals: { message: message }))
    search_json = ApplicationController.render(
      partial: 'api/v1/models/conversation', formats: [:json], locals: { conversation: message.conversation }
    )
    search = JSON.parse(search_json)
    expect(payload['content']).to eq(expected_text)
    expect(payload['additional_attributes']['template_buttons']).to eq([{ 'text' => 'Confirm' }])
    expect(search['messages'].find { |item| item['id'] == message.id }['content']).to eq(expected_text)
    expect(message.reload.content).to eq('')
  end
end
