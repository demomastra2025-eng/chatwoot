require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateCompanyService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }

  it 'returns normalized company payload wrapper' do
    payload = JSON.parse(execute_confirmed(name: 'OneLink', domain: 'onelink.kz', description: 'CRM'))

    expect(payload).to include('action' => 'create_company', 'company_id' => payload.dig('company', 'id'))
    expect(payload['company']).to include(
      'account_id' => account.id,
      'name' => 'OneLink',
      'domain' => 'onelink.kz',
      'description' => 'CRM'
    )
  end

  def execute_confirmed(**arguments)
    first_result = service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    return first_result unless first_payload.dig('data', 'confirmation_required')

    confirmation_token = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}" }
    )

    service.execute(**arguments)
  end
end
