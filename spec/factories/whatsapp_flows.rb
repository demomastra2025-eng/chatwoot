FactoryBot.define do
  factory :whatsapp_flow, class: 'Whatsapp::Flow' do
    account { inbox&.account || create(:account) }
    inbox { create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox }
    sequence(:provider_flow_id) { |n| "flow-#{n}" }
    sequence(:name) { |n| "lead_qualification_#{n}" }
    title { 'Lead qualification' }
    status { 'published' }
    mode { 'published' }
    flow_json { { 'version' => '6.0', 'screens' => [] } }
    metadata { {} }
  end

  factory :whatsapp_flow_session, class: 'Whatsapp::FlowSession' do
    flow { association(:whatsapp_flow) }
    account { flow.account }
    inbox { flow.inbox }
    conversation { nil }
    message { nil }
    response_message { nil }
    status { 'pending' }
    request_payload { {} }
    response_payload { {} }
    metadata { {} }
  end
end
