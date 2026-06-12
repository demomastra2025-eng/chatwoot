FactoryBot.define do
  factory :telephony_provisioning_run, class: 'Telephony::ProvisioningRun' do
    account
    operation { 'dry_run' }
    status { 'pending' }
    remote_commit { false }
    idempotency_key { "vpbx-#{SecureRandom.hex(8)}" }
    desired_snapshot { { provider_kind: 'sipuni', password: 'secret-value' } }
    planned_operations { [] }
  end
end
