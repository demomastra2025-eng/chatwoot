require 'rails_helper'

RSpec.describe Outbound::PlaygroundMutationPolicy do
  let(:account) { create(:account).tap { |item| item.enable_features!('scheduling') } }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }
  let(:patient) do
    create(:contact, account: account, name: 'Messaging alias', custom_attributes: {
             'medelement_patient_card' => true, 'medelement_iin' => '900101400013',
             'medelement_first_name' => 'Айгуль', 'medelement_last_name' => 'Садыкова', 'medelement_birth_date' => '1990-01-01'
           })
  end
  let(:starts) { '2026-10-12T10:00:00+05:00' }
  let(:ends) { '2026-10-12T10:30:00+05:00' }

  before { allow_any_instance_of(Captain::Assistant).to receive(:allowed_agent_tool_ids).and_return(%w[create_appointment]) }
  after { Current.reset }

  def snapshot
    identity = Integrations::Medelement::AppointmentPatientIdentity
    fields = identity::FIELDS.index_with { nil }.merge('client_first_name' => 'айгуль', 'client_last_name' => 'садыкова',
                                                      'client_identifier' => '900101400013', 'client_birth_date' => '1990-01-01')
    { 'account_id' => account.id, 'operation' => 'create_reception', 'appointment_id' => 55, 'contact_id' => patient.id,
      'patient_contact_id' => patient.id, 'actor' => { 'type' => 'User', 'id' => user.id },
      'appointment_patient_identity' => { 'owned' => true, 'explicit_identifier' => true, 'fields' => fields },
      'company_cabinet_code' => 'cabinet-1', 'reception' => {
        'resource_id' => 9, 'service_id' => 10, 'destination_starts_at' => starts, 'destination_ends_at' => ends
      } }
  end

  def with_approved_policy
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: true)
      args = { 'resource_id' => 9, 'service_id' => 10, 'starts_at' => starts, 'ends_at' => ends, 'duration_min' => 30,
               'custom_attributes' => { 'medelement_cabinet_code' => 'cabinet-1' } }
      target = { 'patient' => { 'id' => patient.id, 'type' => 'Contact', 'clinical_identity' => {
        'iin' => '900101400013', 'first_name' => 'Айгуль', 'last_name' => 'Садыкова', 'middle_name' => nil, 'birth_date' => '1990-01-01'
      } } }
      action = { 'id' => SecureRandom.uuid, 'digest' => SecureRandom.hex(32), 'tool' => 'create_appointment',
                 'status' => 'executing', 'arguments' => args, 'target' => target }
      workspace.data['action_previews'] = [action]
      workspace.save!
      policy = Outbound::PlaygroundDeliveryPolicy.issue(workspace.context_reference.merge(
        delivery_enabled: false, run_id: SecureRandom.uuid, action_id: action['id'], action_digest: action['digest'],
        generation: workspace.permissions['generation'], tool: action['tool'], arguments: args, target: target
      ))
      yield workspace, policy
    end
  end

  it 'binds an approved provider command to the exact actor/account/patient/service/cabinet/interval and fingerprint' do
    with_approved_policy do |_workspace, policy|
      bound = described_class.for_command(policy, snapshot)
      command = Struct.new(:request_snapshot).new(snapshot)
      expect(described_class.allowed_command?(command, bound)).to be(true)
      changes = [
        { 'account_id' => account.id + 1 }, { 'actor' => { 'type' => 'User', 'id' => user.id + 1 } },
        { 'patient_contact_id' => patient.id + 1 }, { 'reception' => { 'service_id' => 11 } },
        { 'company_cabinet_code' => 'cabinet-2' }, { 'reception' => { 'destination_ends_at' => '2026-10-12T10:35:00+05:00' } },
        { 'appointment_patient_identity' => { 'fields' => { 'client_identifier' => '150101500011' } } }
      ]
      changes.each do |change|
        altered = snapshot.deep_merge(change)
        expect { described_class.for_command(policy, altered) }.to raise_error(Outbound::PlaygroundDeliveryPolicy::Blocked)
        expect(described_class.allowed_command?(Struct.new(:request_snapshot).new(altered), bound)).to be(false)
      end
    end
  end

  it 'revokes even a server-issued command binding when read is turned off' do
    with_approved_policy do |workspace, policy|
      bound = described_class.for_command(policy, snapshot)
      workspace.store.set_permissions(session_id: workspace.id, read: false, write: true)
      expect(described_class.authorized_action?(policy)).to be(false)
      expect(described_class.allowed_command?(Struct.new(:request_snapshot).new(snapshot), bound)).to be(false)
    end
  end

  it 'revokes a queued exact binding when the member loses current patient-card permission' do
    with_approved_policy do |_workspace, policy|
      bound = described_class.for_command(policy, snapshot)
      command = Struct.new(:request_snapshot).new(snapshot)
      expect(described_class.allowed_command?(command, bound)).to be(true)
      restricted_role = create(:custom_role, account: account, permissions: ['conversation_manage'])
      account.account_users.find_by!(user_id: user.id).update!(role: :agent, custom_role: restricted_role)

      expect(account.account_users.exists?(user_id: user.id)).to be(true)
      expect(described_class.allowed_command?(command, bound)).to be(false)
    end
  end

  it 'denies all new sends from legacy or forged policies while leaving ordinary commands outside this boundary' do
    legacy = Outbound::PlaygroundDeliveryPolicy.issue(mode: 'live', run_id: SecureRandom.uuid, delivery_enabled: true)
    command = Struct.new(:request_snapshot).new(snapshot)
    expect(described_class.allowed_command?(command, legacy)).to be(false)
    expect(described_class.allowed_command?(command, { 'token' => 'forged' })).to be_falsey
    expect(described_class.allowed_command?(command, nil)).to be(true)
  end

  it 'rejects a signed payload without the server-issued run identifier' do
    with_approved_policy do |_workspace, policy|
      payload = Outbound::PlaygroundDeliveryPolicy.verified(policy)
      invalid = Outbound::PlaygroundDeliveryPolicy.issue(payload.to_h.except('run_id'))
      expect(Outbound::PlaygroundDeliveryPolicy.verified(invalid)).to be_nil
      expect(described_class.authorized_action?(invalid)).to be_falsey
      expect(described_class.allowed_command?(Struct.new(:request_snapshot).new(snapshot), invalid)).to be_falsey
    end
  end
end
