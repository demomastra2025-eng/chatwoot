RSpec.shared_context 'with active AI metering' do
  before do
    Accounts::AiUsageRollout.create!(name: Accounts::AiUsageRollout::NAME, cutoff_message_id: 0, cursor: 0,
                                     prepared_at: Time.current, activated_at: Time.current)
  end
end
