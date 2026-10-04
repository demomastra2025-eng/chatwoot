require 'rails_helper'

RSpec.describe Crm::Tasks::RealtimeRecipients do
  let(:account) { create(:account) }

  it 'returns private streams only for current members allowed to view personal and deal tasks' do
    plain_agent = create(:user, account: account, role: :agent)
    task_reader_role = create(:custom_role, account: account, permissions: ['crm_task_view'])
    task_reader = create(:user)
    create(:account_user, account: account, user: task_reader, custom_role: task_reader_role)
    denied_role = create(:custom_role, account: account, permissions: ['crm_deal_view'])
    denied_user = create(:user)
    create(:account_user, account: account, user: denied_user, custom_role: denied_role)
    outside_account = create(:account)
    outside_user = create(:user, account: outside_account, role: :agent)
    personal_task = create(:crm_task, account: account)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    deal_task = create(:crm_task, account: account, deal: deal, context_kind: 'sales')

    [personal_task, deal_task].each do |task|
      recipients = described_class.new(account: account, task: task)

      expect(recipients.tokens).to contain_exactly(plain_agent.pubsub_token, task_reader.pubsub_token)
      expect(recipients.tokens).not_to include(denied_user.pubsub_token, outside_user.pubsub_token)
      expect(recipients.relay_tokens).to eq(["account_#{account.id}"])
    end
  end
end
