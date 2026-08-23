require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceHistoryService do
  let(:channel) do
    create(
      :channel_whatsapp,
      phone_number: '+15550002030',
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => { 'state' => 'requested' }
      }
    )
  end
  let(:value) do
    {
      metadata: {
        phone_number_id: 'phone-1',
        display_phone_number: '15550002030'
      },
      history: [{
        metadata: { phase: 2, progress: 100, chunk_order: 1 },
        threads: [{
          id: '77011112233',
          messages: [
            {
              id: 'wamid.history-text-1',
              from: '77011112233',
              timestamp: '1700000000',
              type: 'text',
              text: { body: 'До подключения OneLink' }
            },
            {
              id: 'wamid.history-placeholder-1',
              from: '77011112233',
              timestamp: '1700000001',
              type: 'media_placeholder'
            }
          ]
        }]
      }]
    }
  end

  after do
    Redis::Alfred.scan_each(match: 'MESSAGE_SOURCE_KEY::*') { |key| Redis::Alfred.delete(key) }
  end

  it 'imports historical messages and placeholders idempotently and records completion' do
    expect do
      described_class.new(channel: channel, value: value).perform
    end.to change(Message, :count).by(2)

    message = channel.inbox.messages.find_by!(source_id: 'wamid.history-text-1')
    expect(message.content).to eq('До подключения OneLink')
    expect(message.content_attributes).to include(
      'whatsapp_history_import' => true,
      'external_created_at' => Time.zone.at(1_700_000_000).iso8601
    )
    expect(message.created_at.to_i).to eq(1_700_000_000)
    placeholder = channel.inbox.messages.find_by!(source_id: 'wamid.history-placeholder-1')
    expect(placeholder.content_attributes).to include(
      'imported_history' => true,
      'whatsapp_history_original_type' => 'media_placeholder'
    )
    expect(channel.reload.provider_config.dig('coexistence_sync', 'state')).to eq('requested')

    expect do
      described_class.new(channel: channel, value: value).perform
    end.not_to change(Message, :count)
  end

  it 'yields between atomic history messages when live traffic starts waiting' do
    first_message_only = value.deep_dup
    first_message_only[:history][0][:threads][0][:messages] = [value[:history][0][:threads][0][:messages].first]
    allow(Whatsapp::WabaLivePriority).to receive(:ensure_clear!)
    described_class.new(channel: channel, value: first_message_only).perform

    allow(Whatsapp::WabaLivePriority).to receive(:ensure_clear!)
      .and_raise(Whatsapp::WabaLivePriority::LiveTrafficPendingError)

    expect do
      described_class.new(channel: channel, value: value).perform
    end.to raise_error(Whatsapp::WabaLivePriority::LiveTrafficPendingError)
    expect(channel.inbox.messages.find_by(source_id: 'wamid.history-placeholder-1')).to be_nil
  end

  it 'replays a persisted history-thread failure on a later history callback' do
    failed_value = {
      metadata: value[:metadata],
      history: [{
        threads: [{
          id: '77011112233',
          messages: [{
            id: 'wamid.retry-history-thread',
            from: '77011112233',
            timestamp: '1700000003',
            type: 'text',
            text: { body: 'Повторяемое сообщение' }
          }]
        }]
      }]
    }
    failed_import = instance_double(Whatsapp::IncomingMessageWhatsappCloudService)
    allow(failed_import).to receive(:perform).and_raise('transient history import failure')
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(failed_import)

    expect do
      described_class.new(channel: channel, value: failed_value).perform
    end.to raise_error(Whatsapp::CoexistenceHistoryService::MediaHydrationError)

    failure = channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages').first
    expect(failure).to include(
      'id' => 'wamid.retry-history-thread',
      'kind' => 'history_thread',
      'thread_id' => '77011112233',
      'message' => include('id' => 'wamid.retry-history-thread'),
      'metadata' => value[:metadata].deep_stringify_keys
    )

    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_call_original
    later_chunk = { metadata: value[:metadata], history: [{ threads: [] }] }

    expect do
      described_class.new(channel: channel, value: later_chunk).perform
    end.to change(Message, :count).by(1)

    expect(channel.inbox.messages.find_by!(source_id: 'wamid.retry-history-thread').content).to eq('Повторяемое сообщение')
    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages')).to be_blank
  end

  it 'locally replays only the requested persisted failure ids' do
    failures = %w[one two].map do |suffix|
      {
        'id' => "wamid.local-replay-#{suffix}",
        'kind' => 'history_thread',
        'thread_id' => '77011112233',
        'message' => {
          'id' => "wamid.local-replay-#{suffix}",
          'from' => '77011112233',
          'timestamp' => '1700000003',
          'type' => 'text',
          'text' => { 'body' => "Local replay #{suffix}" }
        },
        'metadata' => value[:metadata].deep_stringify_keys,
        'replayable' => true
      }
    end
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = config['coexistence_sync'].merge(
      'state' => 'history_failed',
      'history_failed_messages' => failures
    )
    channel.update!(provider_config: config)

    result = described_class.new(channel: channel, value: { metadata: value[:metadata] })
                            .replay_failures(failure_ids: ['wamid.local-replay-one'])

    expect(result).to eq(requested_ids: ['wamid.local-replay-one'], failed_ids: [])
    expect(channel.inbox.messages.find_by!(source_id: 'wamid.local-replay-one').content).to eq('Local replay one')
    expect(channel.inbox.messages.find_by(source_id: 'wamid.local-replay-two')).to be_nil
    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
      .to contain_exactly(include('id' => 'wamid.local-replay-two'))
  end

  it 'moves a persisted mutation failure to durable pending when its target is still missing' do
    failure = {
      'id' => 'wamid.persisted-edit-before-original',
      'kind' => 'history_thread',
      'thread_id' => '77011112233',
      'message' => {
        'id' => 'wamid.persisted-edit-before-original',
        'from' => '77011112233',
        'timestamp' => '1700000004',
        'type' => 'edit',
        'edit' => {
          'original_message_id' => 'wamid.persisted-late-original',
          'message' => { 'type' => 'text', 'text' => { 'body' => 'Исправленный текст' } }
        }
      },
      'metadata' => value[:metadata].deep_stringify_keys,
      'replayable' => true,
      'deferred' => true
    }
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = config['coexistence_sync'].merge(
      'state' => 'history_failed',
      'history_failed_messages' => [failure]
    )
    channel.update!(provider_config: config)

    result = described_class.new(channel: channel, value: { metadata: value[:metadata] })
                            .replay_failures(failure_ids: [failure['id']])

    expect(result).to eq(requested_ids: [failure['id']], failed_ids: [])
    expect(Whatsapp::PendingMessageMutation.find_by!(event_id: failure['id'])).to have_attributes(
      inbox_id: channel.inbox.id,
      target_source_id: 'wamid.persisted-late-original',
      mutation_type: 'edit'
    )
    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages')).to be_blank
  end

  it 'does not persist an unreconcilable history-thread failure without a provider message id' do
    malformed_value = {
      metadata: value[:metadata],
      history: [{ threads: [{ id: '77011112233', messages: [{ from: '77011112233', type: 'text' }] }] }]
    }

    expect { described_class.new(channel: channel, value: malformed_value).perform }.not_to raise_error
    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages')).to be_blank
  end

  it 'recursively removes credentials from persisted replay payloads' do
    secret = 'history-provider-secret'
    channel.update!(provider_config: channel.provider_config.merge('api_key' => secret))
    failed_value = {
      metadata: value[:metadata].merge(api_key: 'metadata-secret'),
      history: [{ threads: [{
        id: '77011112233',
        messages: [{
          id: 'wamid.sanitized-failure',
          from: '77011112233',
          type: 'text',
          access_token: 'payload-secret',
          text: { body: "provider failed with #{secret}" }
        }]
      }] }]
    }
    failed_import = instance_double(Whatsapp::IncomingMessageWhatsappCloudService)
    allow(failed_import).to receive(:perform).and_raise("Bearer #{secret}")
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(failed_import)

    expect do
      described_class.new(channel: channel, value: failed_value).perform
    end.to raise_error(Whatsapp::CoexistenceHistoryService::MediaHydrationError)

    failure = channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages').first
    serialized = failure.to_json
    expect(serialized).not_to include(secret, 'metadata-secret', 'payload-secret', 'access_token', 'api_key')
    expect(serialized).to include('[FILTERED]')
  end

  it 'keeps completed progress when an older history chunk arrives later' do
    described_class.new(channel: channel, value: value).perform
    older_chunk = {
      metadata: value[:metadata],
      history: [{ metadata: { phase: 0, progress: 50, chunk_order: 0 }, threads: [] }]
    }

    described_class.new(channel: channel, value: older_chunk).perform

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include('state' => 'requested', 'history_progress' => 100, 'history_phase' => 2)
  end

  it 'replaces an imported media placeholder when the real media follow-up arrives' do
    described_class.new(channel: channel, value: value).perform
    stub_request(:get, channel.media_url('history-media-1')).to_return(
      status: 200,
      body: { url: 'https://chatwoot-assets.local/history-media.png', id: 'history-media-1' }.to_json,
      headers: { 'content-type' => 'application/json' }
    )
    stub_request(:get, 'https://chatwoot-assets.local/history-media.png').to_return(
      status: 200,
      body: File.read('spec/assets/sample.png'),
      headers: { 'content-type' => 'image/png' }
    )
    follow_up = {
      metadata: value[:metadata],
      messages: [{
        id: 'wamid.history-placeholder-1',
        from: '77011112233',
        timestamp: '1700000001',
        type: 'image',
        image: { id: 'history-media-1', caption: 'Фото из истории', mime_type: 'image/png' }
      }]
    }

    expect do
      described_class.new(channel: channel, value: follow_up).perform
    end.not_to change(Message, :count)

    message = channel.inbox.messages.find_by!(source_id: 'wamid.history-placeholder-1')
    expect(message.content).to eq('Фото из истории')
    expect(message.attachments.size).to eq(1)
    expect(message.content_attributes).to include(
      'whatsapp_message_type' => 'image',
      'whatsapp_history_media_follow_up' => true
    )

    expect do
      described_class.new(channel: channel, value: follow_up).perform
    end.not_to change(Attachment, :count)
  end

  it 'hydrates an outgoing media placeholder from a message echo idempotently' do
    outgoing_history = {
      metadata: value[:metadata],
      history: [{ threads: [{
        id: '77011112233',
        messages: [{
          id: 'wamid.outgoing-placeholder-1',
          to: '77011112233',
          timestamp: '1700000001',
          type: 'media_placeholder',
          history_context: { from_me: true }
        }]
      }] }]
    }
    described_class.new(channel: channel, value: outgoing_history).perform
    stub_request(:get, channel.media_url('history-outgoing-media-1')).to_return(
      status: 200,
      body: { url: 'https://chatwoot-assets.local/history-outgoing-media.png', id: 'history-outgoing-media-1' }.to_json,
      headers: { 'content-type' => 'application/json' }
    )
    stub_request(:get, 'https://chatwoot-assets.local/history-outgoing-media.png').to_return(
      status: 200,
      body: File.read('spec/assets/sample.png'),
      headers: { 'content-type' => 'image/png' }
    )
    follow_up = {
      metadata: value[:metadata],
      message_echoes: [{
        id: 'wamid.outgoing-placeholder-1',
        to: '77011112233',
        timestamp: '1700000001',
        type: 'image',
        image: { id: 'history-outgoing-media-1', caption: 'Исходящее фото', mime_type: 'image/png' }
      }]
    }

    expect do
      described_class.new(channel: channel, value: follow_up).perform
    end.not_to change(Message, :count)

    message = channel.inbox.messages.find_by!(source_id: 'wamid.outgoing-placeholder-1')
    expect(message).to be_outgoing
    expect(message.content).to eq('Исходящее фото')
    expect(message.attachments.size).to eq(1)

    expect do
      described_class.new(channel: channel, value: follow_up).perform
    end.not_to change(Attachment, :count)
  end

  it 'defers media that arrives before its placeholder without blocking later history batches' do
    follow_up = {
      metadata: value[:metadata],
      messages: [{
        id: 'wamid.missing-placeholder',
        from: '77011112233',
        timestamp: '1700000001',
        type: 'image',
        image: { id: 'history-media-missing', mime_type: 'image/png' }
      }]
    }

    expect { described_class.new(channel: channel, value: follow_up).perform }.not_to raise_error

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync['state']).to eq('history_failed')
    expect(sync['history_failed_messages']).to include(include('id' => 'wamid.missing-placeholder', 'deferred' => true))
  end

  it 'records a retryable failure when an existing placeholder remains without an attachment' do
    described_class.new(channel: channel, value: value).perform
    history_follow_up = {
      metadata: value[:metadata],
      history: [{ threads: [{
        id: '77011112233',
        messages: [{
          id: 'wamid.history-placeholder-1',
          from: '77011112233',
          timestamp: '1700000001',
          type: 'image',
          image: { id: 'history-media-no-attachment', mime_type: 'image/png' }
        }]
      }] }]
    }
    no_op_import = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: nil)
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(no_op_import)

    expect do
      described_class.new(channel: channel, value: history_follow_up).perform
    end.to raise_error(Whatsapp::CoexistenceHistoryService::MediaHydrationError)

    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
      .to include(include('id' => 'wamid.history-placeholder-1', 'kind' => 'history_thread'))
  end

  it 'clears a deferred media failure after the placeholder becomes available' do
    follow_up = {
      metadata: value[:metadata],
      messages: [{
        id: 'wamid.delayed-placeholder',
        from: '77011112233',
        timestamp: '1700000001',
        type: 'image',
        image: { id: 'history-media-delayed', mime_type: 'image/png' }
      }]
    }

    expect { described_class.new(channel: channel, value: follow_up).perform }.not_to raise_error
    persisted_failure = channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages', 0)
    expect(persisted_failure.dig('message', 'id')).to eq('wamid.delayed-placeholder')
    expect(persisted_failure['deferred']).to be(true)

    placeholder_chunk = {
      metadata: value[:metadata],
      history: [{
        threads: [{
          id: '77011112233',
          messages: [{
            id: 'wamid.delayed-placeholder',
            from: '77011112233',
            timestamp: '1700000001',
            type: 'media_placeholder'
          }]
        }]
      }]
    }
    stub_request(:get, channel.media_url('history-media-delayed')).to_return(
      status: 200,
      body: { url: 'https://chatwoot-assets.local/history-media-delayed.png', id: 'history-media-delayed' }.to_json,
      headers: { 'content-type' => 'application/json' }
    )
    stub_request(:get, 'https://chatwoot-assets.local/history-media-delayed.png').to_return(
      status: 200,
      body: File.read('spec/assets/sample.png'),
      headers: { 'content-type' => 'image/png' }
    )

    described_class.new(channel: channel, value: placeholder_chunk).perform

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync['state']).to eq('syncing')
    expect(sync).not_to include('history_failed_at', 'history_failed_messages')
  end

  it 'clears only the media failure resolved by the current retry' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = config['coexistence_sync'].to_h.merge(
      'state' => 'history_failed',
      'history_failed_at' => Time.current.iso8601,
      'history_failed_messages' => [
        { 'id' => 'wamid.resolved', 'error' => 'placeholder missing' },
        { 'id' => 'wamid.still-missing', 'error' => 'placeholder missing' }
      ]
    )
    channel.update!(provider_config: config)
    follow_up = { messages: [{ id: 'wamid.resolved' }] }.with_indifferent_access

    Whatsapp::CoexistenceHistoryMediaService.new(channel: channel, value: follow_up).finalize([])

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync['state']).to eq('history_failed')
    expect(sync['history_failed_messages']).to eq([{ 'id' => 'wamid.still-missing', 'error' => 'placeholder missing' }])
  end

  it 'atomically removes resolved failures while recording failures from the same retry' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = config['coexistence_sync'].to_h.merge(
      'state' => 'history_failed',
      'history_failed_messages' => [
        { 'id' => 'wamid.resolved', 'error' => 'placeholder missing' },
        { 'id' => 'wamid.previous', 'error' => 'placeholder missing' }
      ]
    )
    channel.update!(provider_config: config)
    retry_value = { messages: [{ id: 'wamid.resolved' }, { id: 'wamid.current-failure' }] }.with_indifferent_access
    current_failures = [{ id: 'wamid.current-failure', error: 'placeholder missing' }]

    Whatsapp::CoexistenceHistoryMediaService.new(channel: channel, value: retry_value).finalize(current_failures)

    persisted_ids = channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages').pluck('id')
    expect(persisted_ids).to contain_exactly('wamid.previous', 'wamid.current-failure')
  end

  it 'preserves a declined history state when a media retry succeeds' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = config['coexistence_sync'].to_h.merge(
      'state' => 'history_declined',
      'history_errors' => [{ 'code' => 2_593_109, 'title' => 'History sharing was declined' }],
      'history_failed_messages' => [{ 'id' => 'wamid.resolved', 'error' => 'placeholder missing' }]
    )
    channel.update!(provider_config: config)
    retry_value = { messages: [{ id: 'wamid.resolved' }] }.with_indifferent_access

    Whatsapp::CoexistenceHistoryMediaService.new(channel: channel, value: retry_value).finalize([])

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync['state']).to eq('history_declined')
    expect(sync).not_to have_key('history_failed_messages')
  end

  it 'merges multiple media failures without collapsing symbol-keyed ids' do
    failures = [
      { id: 'wamid.first-failure', error: 'placeholder missing' },
      { id: 'wamid.second-failure', error: 'placeholder missing' }
    ]
    service = Whatsapp::CoexistenceHistoryMediaService.new(channel: channel, value: { messages: [] }.with_indifferent_access)

    service.finalize(failures)

    persisted_ids = channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages').pluck('id')
    expect(persisted_ids).to contain_exactly('wamid.first-failure', 'wamid.second-failure')
  end

  it 'durably preserves every media failure when one callback exceeds the former ledger cap' do
    failures = Array.new(25) do |index|
      { id: "wamid.failure-#{index}", error: 'placeholder missing' }
    end
    service = Whatsapp::CoexistenceHistoryMediaService.new(channel: channel, value: { messages: [] }.with_indifferent_access)

    service.finalize(failures)

    persisted_ids = channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages').pluck('id')
    expect(persisted_ids).to match_array(failures.pluck(:id))
  end

  it 'persists the failure ledger even when normal provider validations are unavailable' do
    service = Whatsapp::CoexistenceHistoryMediaService.new(channel: channel, value: { messages: [] }.with_indifferent_access)
    allow(channel).to receive(:valid?).and_return(false)

    expect do
      service.finalize([{ id: 'wamid.validation-independent', error: 'placeholder missing' }])
    end.not_to raise_error

    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
      .to contain_exactly(include('id' => 'wamid.validation-independent'))
  end

  it 'drops malformed failure records without a provider message id before persistence' do
    failures = [
      { id: nil, error: 'missing id' },
      { id: ' ', error: 'blank id' },
      { id: 'wamid.valid-failure', error: 'placeholder missing' }
    ]
    service = Whatsapp::CoexistenceHistoryMediaService.new(channel: channel, value: { messages: [] }.with_indifferent_access)

    service.finalize(failures)

    persisted = channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages')
    expect(persisted).to contain_exactly(include('id' => 'wamid.valid-failure'))
  end

  it 'does not let later progress hide an unresolved media failure' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = config['coexistence_sync'].to_h.merge(
      'state' => 'history_failed',
      'history_failed_messages' => [{ 'id' => 'wamid.still-missing', 'error' => 'placeholder missing' }]
    )
    channel.update!(provider_config: config)
    progress_only = { history: [{ metadata: { phase: 1, progress: 100, chunk_order: 9 }, threads: [] }] }

    described_class.new(channel: channel, value: progress_only).perform

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include('state' => 'history_failed', 'history_progress' => 100)
  end

  it 'imports a recovered dead payload without replaying the existing failure ledger' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = config['coexistence_sync'].to_h.merge(
      'state' => 'history_failed',
      'history_failed_messages' => [{
        'id' => 'wamid.existing-failure',
        'kind' => 'history_thread',
        'thread_id' => '77011112233',
        'message' => {
          'id' => 'wamid.existing-failure',
          'from' => '77011112233',
          'timestamp' => '1700000000',
          'type' => 'text',
          'text' => { 'body' => 'Persisted failure' }
        },
        'metadata' => value[:metadata]
      }]
    )
    channel.update!(provider_config: config)
    progress_only = { history: [{ metadata: { phase: 1, progress: 50 }, threads: [] }] }
    expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)

    described_class.new(channel: channel, value: progress_only).perform(replay_persisted_failures: false)

    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
      .to contain_exactly(include('id' => 'wamid.existing-failure'))
  end

  it 'does not let late progress, media, or provider errors overwrite manual recovery' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = config['coexistence_sync'].to_h.merge(
      'state' => 'manual_recovery_required',
      'history_request_state' => 'manual_recovery_required'
    )
    channel.update!(provider_config: config)
    progress_only = { history: [{ metadata: { phase: 1, progress: 100 }, threads: [] }] }

    described_class.new(channel: channel, value: progress_only).perform
    Whatsapp::CoexistenceHistoryMediaService.new(
      channel: channel,
      value: { messages: [{ id: 'wamid.late-media' }] }.with_indifferent_access
    ).finalize([{ id: 'wamid.late-media', error: 'late failure' }])
    Whatsapp::CoexistenceHistoryErrorService.new(channel: channel).record(
      errors: [{ code: 1, title: 'Late provider error', message: 'late failure' }]
    )

    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'manual_recovery_required',
      'history_request_state' => 'manual_recovery_required'
    )
  end

  it 'does not let late provider errors switch history terminal states' do
    {
      'history_failed' => 2_593_109,
      'history_declined' => 1
    }.each do |terminal_state, late_error_code|
      config = channel.reload.provider_config.deep_dup
      config['coexistence_sync'] = config['coexistence_sync'].to_h.merge('state' => terminal_state)
      channel.update!(provider_config: config)

      Whatsapp::CoexistenceHistoryErrorService.new(channel: channel).record(
        errors: [{ code: late_error_code, title: 'Late provider error', message: 'late failure' }]
      )

      expect(channel.reload.provider_config.dig('coexistence_sync', 'state')).to eq(terminal_state)
    end
  end

  it 'imports an outgoing history message without a to field using the thread id as recipient' do
    outgoing_value = {
      metadata: value[:metadata],
      history: [{
        metadata: { phase: 0, progress: 10, chunk_order: 1 },
        threads: [{
          id: '77011112233',
          messages: [{
            id: 'wamid.history-outgoing-1',
            from: '15550002030',
            timestamp: '1700000002',
            type: 'text',
            text: { body: 'Ответ из Business App' },
            history_context: { status: 'DELIVERED', from_me: true }
          }]
        }]
      }]
    }

    described_class.new(channel: channel, value: outgoing_value).perform

    message = channel.inbox.messages.find_by!(source_id: 'wamid.history-outgoing-1')
    expect(message).to be_outgoing
    expect(message).to be_delivered
    expect(message.content_attributes['whatsapp_history_status']).to eq('DELIVERED')
  end

  it 'imports every contact from a multi-contact history message' do
    contacts_value = {
      metadata: value[:metadata],
      history: [{ threads: [{
        id: '77011112233',
        messages: [{
          id: 'wamid.history-contacts-1',
          from: '77011112233',
          timestamp: '1700000005',
          type: 'contacts',
          contacts: [
            { name: { formatted_name: 'First Contact' }, phones: [{ phone: '+15555550103' }] },
            { name: { formatted_name: 'Second Contact' }, phones: [{ phone: '+15555550104' }] }
          ]
        }]
      }] }]
    }

    expect do
      described_class.new(channel: channel, value: contacts_value).perform
    end.to change(Message, :count).by(2)

    source_ids = %w[wamid.history-contacts-1:contact:0 wamid.history-contacts-1:contact:1]
    imported_messages = channel.inbox.messages.where(source_id: source_ids)
    expect(imported_messages.count).to eq(2)
    expect(imported_messages.map(&:content_attributes)).to all(include('whatsapp_history_import' => true))
  end

  it 'ignores provider error entries that do not represent importable messages' do
    provider_error_value = {
      metadata: value[:metadata],
      history: [{ threads: [{
        id: '77011112233',
        messages: [{
          id: 'wamid.history-provider-error-1',
          from: '77011112233',
          timestamp: '1700000003',
          type: 'errors',
          errors: [{ code: 131_051, title: 'Message type unknown' }]
        }]
      }] }]
    }

    expect do
      described_class.new(channel: channel, value: provider_error_value).perform
    end.not_to change(Message, :count)
  end

  it 'applies history mutation events without expecting a standalone message' do
    described_class.new(channel: channel, value: value).perform
    edit_value = {
      metadata: value[:metadata],
      history: [{ threads: [{
        id: '77011112233',
        messages: [{
          id: 'wamid.history-edit-1',
          from: '77011112233',
          timestamp: '1700000004',
          type: 'edit',
          edit: {
            original_message_id: 'wamid.history-text-1',
            message: { type: 'text', text: { body: 'Исправленный текст' } }
          }
        }]
      }] }]
    }

    expect do
      described_class.new(channel: channel, value: edit_value).perform
    end.not_to change(Message, :count)
    expect(channel.inbox.messages.find_by!(source_id: 'wamid.history-text-1').content).to eq('Исправленный текст')
  end

  it 'defers a mutation until its original message arrives without retrying every history callback' do
    edit_value = {
      metadata: value[:metadata],
      history: [{ threads: [{
        id: '77011112233',
        messages: [{
          id: 'wamid.history-edit-before-original',
          from: '77011112233',
          timestamp: '1700000004',
          type: 'edit',
          edit: {
            original_message_id: 'wamid.history-late-original',
            message: { type: 'text', text: { body: 'Исправленный текст' } }
          }
        }]
      }] }]
    }

    expect { described_class.new(channel: channel, value: edit_value).perform }.not_to raise_error
    pending_mutation = Whatsapp::PendingMessageMutation.find_by!(event_id: 'wamid.history-edit-before-original')
    expect(pending_mutation).to have_attributes(
      target_source_id: 'wamid.history-late-original',
      mutation_type: 'edit'
    )

    empty_chunk = { metadata: value[:metadata], history: [{ threads: [] }] }
    expect do
      described_class.new(channel: channel, value: empty_chunk).perform
    end.not_to change(Whatsapp::PendingMessageMutation, :count)

    original_value = {
      metadata: value[:metadata],
      history: [{ threads: [{
        id: '77011112233',
        messages: [{
          id: 'wamid.history-late-original',
          from: '77011112233',
          timestamp: '1700000003',
          type: 'text',
          text: { body: 'Исходный текст' }
        }]
      }] }]
    }
    described_class.new(channel: channel, value: original_value).perform

    expect(channel.inbox.messages.find_by!(source_id: 'wamid.history-late-original').content).to eq('Исправленный текст')
    expect(Whatsapp::PendingMessageMutation.where(event_id: 'wamid.history-edit-before-original')).to be_empty
    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages')).to be_blank
  end

  it 'records the official history-sharing declined error without importing data' do
    declined = {
      metadata: value[:metadata],
      history: [{
        errors: [{
          code: 2_593_109,
          title: 'History sharing was declined',
          message: 'The business declined history sharing',
          error_data: { details_url: 'https://provider.example/private-details' }
        }],
        metadata: { phase: 1, progress: 100 }
      }]
    }

    expect do
      described_class.new(channel: channel, value: declined).perform
    end.not_to change(Message, :count)
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include('state' => 'history_declined', 'history_progress' => 100, 'history_phase' => 1)
    expect(sync.dig('history_errors', 0)).to include(
      'code' => 2_593_109,
      'title' => 'History sharing was declined',
      'message' => 'The business declined history sharing'
    )
    expect(sync.dig('history_errors', 0)).not_to have_key('error_data')
  end
end
