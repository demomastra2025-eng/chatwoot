# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Wazo::ProvisioningService do
  subject(:service) { described_class.new(account: account, inbox: inbox, client: client, sip_context: 'onelink-test') }

  let(:account) { instance_double(Account, id: 74) }
  let(:profile_relation) { double }
  let(:inbox) { instance_double(Inbox, id: 242, telephony_sip_profiles: profile_relation) }
  let(:client) { instance_double(Telephony::Wazo::ApiClient) }
  let(:lock_manager) { instance_double(Redis::LockManager, lock: true, renew: true, unlock: true) }
  let(:user) { instance_double(User, name: 'Test Operator') }
  let(:profile_metadata) { {} }
  let(:profile) do
    instance_double(
      Telephony::SipProfile,
      id: 87,
      user: user,
      internal_extension: '101',
      sip_username: 'ol74i242u15',
      sip_password: 'generated-password',
      metadata: profile_metadata,
      update!: true
    )
  end

  before do
    allow(profile_relation).to receive(:where).with(status: 'active', enabled: true).and_return([profile])
    allow(profile_relation).to receive(:to_a).and_return([profile])
    allow(profile).to receive(:update!) { |metadata:| profile_metadata.replace(metadata) }
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
  end

  it 'creates and associates a complete managed user, line, extension, and SIP endpoint graph', :aggregate_failures do
    allow(client).to receive(:sip_endpoints).and_return([])
    allow(client).to receive(:users).and_return([])
    allow(client).to receive(:lines).and_return([])
    expect(client).to receive(:create_user).with(
      { firstname: 'Test Operator', lastname: 'managed 74/242/87', username: 'ol-a74-i242-u-p87' }
    ).and_return('uuid' => 'user-uuid')
    expect(client).to receive(:create_line).with(
      {
        context: 'onelink-test', caller_id_name: 'OneLink managed a=74 i=242 p=87',
        extensions: [{ context: 'onelink-test', exten: '101' }]
      }
    ).and_return('id' => 12, 'extensions' => [{ 'id' => 13, 'context' => 'onelink-test', 'exten' => '101' }])
    allow(client).to receive(:extensions).and_return([])
    expect(client).to receive(:create_sip_endpoint) do |payload|
      expect(payload).to include(name: 'ol-a74-i242-p87', label: 'OneLink managed account=74 inbox=242')
      expect(payload[:auth_section_options]).to include(%w[username ol74i242u15], %w[password generated-password])
      { 'uuid' => 'endpoint-uuid' }
    end
    expect(client).to receive(:associate_user_line).with('user-uuid', 12)
    expect(client).to receive(:associate_line_extension).with(12, 13)
    expect(client).to receive(:associate_line_sip_endpoint).with(12, 'endpoint-uuid')

    result = service.sync!

    expect(result).to include(status: 'remote_committed', remote_commit: true)
    expect(result.to_s).not_to include('generated-password')
    expect(profile).to have_received(:update!).with(
      metadata: hash_including(
        'wazo_endpoint_uuid' => 'endpoint-uuid', 'wazo_user_uuid' => 'user-uuid',
        'wazo_line_id' => 12, 'wazo_extension_id' => 13
      )
    ).at_least(:once)
  end

  it 'rejects a concurrent remote provisioning operation' do
    allow(lock_manager).to receive(:lock).and_return(false)
    allow(client).to receive(:sip_endpoints)

    expect { service.sync! }.to raise_error(Telephony::Error) do |error|
      expect(error.code).to eq('WAZO_PROVISIONING_IN_PROGRESS')
    end
    expect(client).not_to have_received(:sip_endpoints)
  end

  context 'with an existing managed graph' do
    let(:profile_metadata) do
      {
        'wazo_user_uuid' => 'user-uuid', 'wazo_line_id' => 12,
        'wazo_extension_id' => 13, 'wazo_endpoint_uuid' => 'endpoint-uuid'
      }
    end

    it 'updates and re-associates every resource idempotently', :aggregate_failures do
      allow(client).to receive(:sip_endpoints).and_return(
        [{
          'uuid' => 'endpoint-uuid', 'name' => 'ol-a74-i242-p87',
          'label' => 'OneLink managed account=74 inbox=242', 'line' => { 'id' => 12 }
        }]
      )
      allow(client).to receive(:line).with(12).and_return(
        'id' => 12,
        'caller_id_name' => 'OneLink managed a=74 i=242 p=87',
        'endpoint_sip' => { 'uuid' => 'endpoint-uuid' },
        'extensions' => [{ 'id' => 13, 'context' => 'onelink-test', 'exten' => '101' }],
        'users' => [{ 'uuid' => 'user-uuid', 'lastname' => 'managed 74/242/87' }]
      )
      allow(client).to receive(:user).with('user-uuid').and_return(
        'username' => 'ol-a74-i242-u-p87', 'lastname' => 'managed 74/242/87', 'lines' => [{ 'id' => 12 }]
      )
      allow(client).to receive(:extension).with(13).and_return(
        'context' => 'onelink-test', 'exten' => '101', 'lines' => [{ 'id' => 12 }]
      )
      expect(client).to receive(:update_user).with('user-uuid', hash_including(username: 'ol-a74-i242-u-p87'))
      expect(client).to receive(:update_line).with(
        12, { context: 'onelink-test', caller_id_name: 'OneLink managed a=74 i=242 p=87' }
      )
      expect(client).to receive(:update_extension).with(13, { context: 'onelink-test', exten: '101' })
      expect(client).to receive(:update_sip_endpoint).with('endpoint-uuid', hash_including(name: 'ol-a74-i242-p87')).and_return({})
      expect(client).to receive(:associate_user_line).with('user-uuid', 12)
      expect(client).to receive(:associate_line_extension).with(12, 13)
      expect(client).to receive(:associate_line_sip_endpoint).with(12, 'endpoint-uuid')
      expect(client).not_to receive(:create_user)
      expect(client).not_to receive(:create_line)
      expect(client).not_to receive(:create_extension)
      expect(client).not_to receive(:create_sip_endpoint)

      result = service.sync!

      expect(result[:executed_operations]).to include(hash_including(action: 'update_graph'))
    end
  end

  it 'clears rolled-back refs and succeeds on the next sync after a partial association failure' do
    allow(client).to receive(:sip_endpoints).and_return([])
    allow(client).to receive(:users).and_return([])
    allow(client).to receive(:lines).and_return([])
    allow(client).to receive(:extensions).and_return([])
    allow(client).to receive(:create_user).and_return('uuid' => 'user-uuid')
    allow(client).to receive(:create_line).and_return(
      'id' => 12, 'extensions' => [{ 'id' => 13, 'context' => 'onelink-test', 'exten' => '101' }]
    )
    allow(client).to receive(:create_sip_endpoint).and_return('uuid' => 'endpoint-uuid')
    allow(client).to receive(:associate_user_line)
    allow(client).to receive(:associate_line_sip_endpoint)
    allow(client).to receive(:associate_line_extension).and_raise(
      Telephony::Error.new(code: 'WAZO_API_FAILED', message: 'association failed', status: :bad_gateway)
    )
    allow(client).to receive(:dissociate_line_sip_endpoint)
    allow(client).to receive(:dissociate_line_extension)
    allow(client).to receive(:dissociate_user_line)
    expect(client).to receive(:delete_sip_endpoint).with('endpoint-uuid')
    expect(client).to receive(:delete_extension).with(13)
    expect(client).to receive(:delete_line).with(12)
    expect(client).to receive(:delete_user).with('user-uuid')

    expect { service.sync! }.to raise_error(Telephony::Error, 'association failed')
    expect(profile_metadata.slice(*described_class::REMOTE_REF_KEYS)).to be_empty

    allow(client).to receive(:associate_line_extension).and_return(true)
    expect(service.sync!).to include(status: 'remote_committed')
  end

  it 'continues rollback when one cleanup step fails' do
    allow(client).to receive(:sip_endpoints).and_return([])
    allow(client).to receive(:users).and_return([])
    allow(client).to receive(:lines).and_return([])
    allow(client).to receive(:extensions).and_return([])
    allow(client).to receive(:create_user).and_return('uuid' => 'user-uuid')
    allow(client).to receive(:create_line).and_return(
      'id' => 12, 'extensions' => [{ 'id' => 13, 'context' => 'onelink-test', 'exten' => '101' }]
    )
    allow(client).to receive(:create_sip_endpoint).and_return('uuid' => 'endpoint-uuid')
    allow(client).to receive(:associate_user_line)
    allow(client).to receive(:associate_line_extension).and_raise(StandardError, 'association failed')
    allow(client).to receive(:dissociate_line_sip_endpoint).and_raise(StandardError, 'cleanup failed')
    allow(client).to receive(:dissociate_line_extension)
    allow(client).to receive(:dissociate_user_line)
    allow(client).to receive(:delete_sip_endpoint).and_raise(StandardError, 'cleanup failed')
    expect(client).to receive(:delete_extension).with(13)
    expect(client).to receive(:delete_line).with(12)
    expect(client).to receive(:delete_user).with('user-uuid')

    expect { service.sync! }.to raise_error(StandardError, 'association failed')
  end

  it 'retains stale discovered graphs without persisted ownership references', :aggregate_failures do
    allow(profile_relation).to receive(:where).and_return([])
    allow(client).to receive(:sip_endpoints).and_return(
      [
        {
          'uuid' => 'stale-uuid', 'name' => 'ol-a74-i242-p99',
          'label' => 'OneLink managed account=74 inbox=242', 'line' => { 'id' => 22 }
        },
        { 'uuid' => 'foreign-uuid', 'name' => 'ol-a74-i999-p1', 'label' => 'OneLink managed account=74 inbox=999' }
      ]
    )
    expect(client).not_to receive(:line)
    expect(client).not_to receive(:delete_sip_endpoint)

    result = service.sync!

    expect(result[:executed_operations]).to include(
      hash_including(action: 'retain_stale_graph', endpoint_name: 'ol-a74-i242-p99')
    )
    expect(result[:reconciliation]).to include(status: 'drifted', stale_endpoint_names: ['ol-a74-i242-p99'])
    expect(result[:remote_snapshot]).to eq(endpoint_names: ['ol-a74-i242-p99'])
  end

  it 'deletes a graph only when persisted refs and exact remote ownership all match' do
    allow(profile_relation).to receive(:where).and_return([])
    profile_metadata.merge!(
      'wazo_endpoint_uuid' => 'endpoint-uuid', 'wazo_line_id' => 12,
      'wazo_extension_id' => 13, 'wazo_user_uuid' => 'user-uuid'
    )
    allow(client).to receive(:sip_endpoint).with('endpoint-uuid').and_return(
      'uuid' => 'endpoint-uuid', 'name' => 'ol-a74-i242-p87',
      'label' => 'OneLink managed account=74 inbox=242', 'line' => { 'id' => 12 }
    )
    allow(client).to receive(:line).with(12).and_return(
      'id' => 12, 'caller_id_name' => 'OneLink managed a=74 i=242 p=87',
      'endpoint_sip' => { 'uuid' => 'endpoint-uuid' },
      'extensions' => [{ 'id' => 13, 'context' => 'onelink-test', 'exten' => '101' }],
      'users' => [{ 'uuid' => 'user-uuid', 'lastname' => 'managed 74/242/87' }]
    )
    allow(client).to receive(:user).with('user-uuid').and_return(
      'username' => 'ol-a74-i242-u-p87', 'lastname' => 'managed 74/242/87',
      'lines' => [{ 'id' => 12 }]
    )
    allow(client).to receive(:extension).with(13).and_return(
      'context' => 'onelink-test', 'exten' => '101', 'lines' => [{ 'id' => 12 }]
    )
    allow(client).to receive(:dissociate_line_sip_endpoint)
    allow(client).to receive(:dissociate_line_extension)
    allow(client).to receive(:dissociate_user_line)
    allow(client).to receive(:delete_sip_endpoint)
    allow(client).to receive(:delete_extension)
    allow(client).to receive(:delete_line)
    allow(client).to receive(:delete_user)

    result = service.delete_all!

    expect(result[:executed_operations]).to include(hash_including(action: 'delete_graph'))
    expect(client).to have_received(:delete_extension).with(13)
  end

  it 'blocks cleanup when a managed endpoint is attached to a shared line' do
    profile_metadata.merge!(
      'wazo_endpoint_uuid' => 'endpoint-uuid', 'wazo_line_id' => 12,
      'wazo_extension_id' => 13, 'wazo_user_uuid' => 'user-uuid'
    )
    allow(client).to receive(:sip_endpoint).with('endpoint-uuid').and_return(
      'uuid' => 'endpoint-uuid', 'name' => 'ol-a74-i242-p87',
      'label' => 'OneLink managed account=74 inbox=242', 'line' => { 'id' => 12 }
    )
    allow(client).to receive(:line).with(12).and_return(
      'id' => 12,
      'caller_id_name' => 'OneLink managed a=74 i=242 p=87',
      'endpoint_sip' => { 'uuid' => 'endpoint-uuid' },
      'extensions' => [{ 'id' => 13, 'context' => 'onelink-test', 'exten' => '101' }],
      'users' => [
        { 'uuid' => 'user-uuid', 'lastname' => 'managed 74/242/87' },
        { 'uuid' => 'manual-user', 'lastname' => 'Manual user' }
      ]
    )
    allow(client).to receive(:user).and_return(
      'username' => 'ol-a74-i242-u-p87', 'lastname' => 'managed 74/242/87', 'lines' => [{ 'id' => 12 }]
    )
    allow(client).to receive(:extension).with(13).and_return(
      'context' => 'onelink-test', 'exten' => '101', 'lines' => [{ 'id' => 12 }]
    )
    allow(client).to receive(:delete_sip_endpoint)

    expect { service.delete_all! }.to raise_error(Telephony::Error, /ownership could not be proven/)
    expect(client).not_to have_received(:delete_sip_endpoint)
  end
end
