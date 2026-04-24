require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchArticlesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  it 'returns normalized articles payload with filters and total_count' do
    portal = create(:portal, account: account)
    category = create(:category, portal: portal, account: account)
    create(:article, account: account, portal: portal, author: user, category: category, title: 'Refund policy', content: 'Refund in 14 days',
                     status: 'published')
    create(:article, account: account, portal: portal, author: user, title: 'Shipping', content: 'Delivery terms', status: 'draft')

    payload = JSON.parse(service.execute(query: 'Refund', category_id: category.id, status: 'published', limit: 5))

    expect(payload['filters']).to include('query' => 'Refund', 'category_id' => category.id, 'status' => 'published')
    expect(payload['total_count']).to eq(1)
    expect(payload['articles'].first).to include(
      'title' => 'Refund policy',
      'category_id' => category.id,
      'status' => 'published'
    )
  end
end
