require 'rails_helper'

# The AI analytics page of the super admin: Russian texts, Astana time, dollars with a comma.
RSpec.describe 'Super Admin AI analytics', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:page) { Nokogiri::HTML(response.body) }
  let(:moment) { Time.utc(2026, 10, 15, 12, 5, 9) }
  let(:report) do
    {
      date_range: (moment - 30.days)..moment,
      snapshot: {
        total_events: 12_450, request_count: 3000, error_count: 7, total_estimated_cost: 1234.5,
        blocked_count: 2, schema_invalid_count: 1, tool_failure_count: 4, last_event_at: moment,
        by_feature: { 'agent_reply' => 10, nil => 2 }, by_model: { 'openai/gpt-6-luna' => 12 }, by_provider: {}
      },
      top_accounts: [
        { account_id: 5, account_name: 'Клиника «Сезим»', total_events: 100, request_count: 40, error_count: 3,
          estimated_cost: 12.345, last_event_at: moment }
      ]
    }
  end

  before { sign_in(super_admin, scope: :super_admin) }

  it 'shows the figures, the top clinics and the spread in Russian' do
    allow(Llm::Monitoring::FleetSnapshot).to receive(:new).and_return(instance_double(Llm::Monitoring::FleetSnapshot, call: report))

    get '/super_admin/captain_observability'

    expect(response).to have_http_status(:ok)
    expect(page.css('[data-testid="stat"]').map { |node| node.text.squish }).to eq(
      ['События 12 450', 'Запросы в чате 3 000', 'Ошибки 7', 'Оценка стоимости $1 234,50']
    )
    expect(page.at_css('[data-testid="ai-top"]').text).to include('Клиника «Сезим»', 'Клиника №5', '$12,35', '15.10.2026 17:05')
    expect(page.at_css('[data-testid="ai-range"]').text).to include('(Астана)')
    expect(page.at_css('[data-testid="ai-spread-features"]').text).to include('agent_reply (10)', 'не указано (2)')
    expect(page.at_css('[data-testid="ai-spread-providers"]').text).to include('нет данных')
  end

  it 'says so when there was no activity' do
    allow(Llm::Monitoring::FleetSnapshot).to receive(:new).and_return(instance_double(Llm::Monitoring::FleetSnapshot, call: { snapshot: {}, top_accounts: [] }))

    get '/super_admin/captain_observability'

    expect(page.at_css('[data-testid="ai-top-empty"]').text).to include('активности ИИ не найдено')
    expect(response.body).not_to match(/No fleet|n\/a|Estimated cost|\$0\.00/)
  end

  it 'has no English words and no emoji in what it draws' do
    allow(Llm::Monitoring::FleetSnapshot).to receive(:new).and_return(instance_double(Llm::Monitoring::FleetSnapshot, call: report))

    get '/super_admin/captain_observability'

    main = page.at_css('main').text
    expect(main).not_to match(/\b(Events|Requests|Errors|Cost|Account|Models|Providers|Features|Distribution)\b/)
    expect(main).not_to match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/)
  end
end
