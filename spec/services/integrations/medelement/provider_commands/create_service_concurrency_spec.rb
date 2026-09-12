require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::ProviderCommands::CreateService do
  self.use_transactional_tests = false

  it 'returns one durable command when two database connections create the same intent', :aggregate_failures do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true, destroy!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    records = create_records
    entered = Queue.new
    release = Queue.new
    results = Queue.new
    errors = Queue.new
    services = Array.new(2) { build_service(records) }

    services.each do |service|
      allow(service).to receive(:create_new_command!).and_wrap_original do |method, *args|
        entered << true
        release.pop
        method.call(*args)
      end
    end

    threads = services.map do |service|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          command_id = ApplicationRecord.transaction { service.perform.id }
          results << command_id
        rescue StandardError => e
          errors << e
        end
      end
    end

    2.times { Timeout.timeout(5) { entered.pop } }
    2.times { release << true }
    threads.each { |thread| Timeout.timeout(10) { thread.join } }

    command_ids = Array.new(2) { Timeout.timeout(2) { results.pop } }
    expect(errors).to be_empty
    expect(command_ids.uniq.one?).to be(true)
    expect(
      Integrations::Medelement::ProviderCommand.where(
        account_id: records.fetch(:account_id),
        idempotency_key: 'concurrent-create'
      ).count
    ).to eq(1)
    expect(
      ConfirmationRequest.where(account_id: records.fetch(:account_id))
                         .where("metadata ->> 'medelement_provider_command_id' = ?", command_ids.first.to_s)
                         .count
    ).to eq(1)
  ensure
    2.times { release&.push(true) }
    threads&.each do |thread|
      thread.join(2)
      thread.kill if thread.alive?
    end
    cleanup_records(records) if defined?(records) && records
  end

  def create_records
    account = create(:account).tap { |record| record.enable_features!('scheduling') }
    user = create(:user, :administrator, account: account)
    contact = create(:contact, account: account, name: 'Ivanov Ivan', phone_number: '+77000000001')
    resource = create_resource(account)
    appointment = create(:scheduling_appointment, account: account, contact: contact, resource: resource)
    hook = create_hook(account)

    {
      account: account,
      account_id: account.id,
      user: user,
      user_id: user.id,
      contact: contact,
      resource: resource,
      service: appointment.service,
      appointment: appointment,
      appointment_id: appointment.id,
      hook: hook,
      hook_id: hook.id
    }
  end

  def create_resource(account)
    create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
  end

  def create_hook(account)
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
  end

  def build_service(records)
    described_class.new(
      account: Account.find(records.fetch(:account_id)),
      hook: Integrations::Hook.find(records.fetch(:hook_id)),
      appointment: Scheduling::Appointment.find(records.fetch(:appointment_id)),
      operation: 'create_reception',
      idempotency_key: 'concurrent-create',
      company_cabinet_code: 'cabinet-1',
      actor: User.find(records.fetch(:user_id))
    )
  end

  def cleanup_records(records)
    account_id = records.fetch(:account_id)
    Integrations::Medelement::ProviderCommand.where(account_id: account_id).destroy_all
    ConfirmationRequest.where(account_id: account_id).destroy_all
    %i[appointment service hook contact resource user account].each do |key|
      record = records.fetch(key)
      record.destroy! if record&.persisted?
    end
  end
end
