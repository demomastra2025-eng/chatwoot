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

  it 'keeps total_count independent from the requested limit' do
    portal = create(:portal, account: account)
    create(:article, account: account, portal: portal, author: user, title: 'Refund policy', content: 'Refund policy', status: 'published')
    create(:article, account: account, portal: portal, author: user, title: 'Refund procedure', content: 'Refund procedure', status: 'published')

    payload = JSON.parse(service.execute(query: 'Refund', limit: 1))

    expect(payload['total_count']).to eq(2)
    expect(payload['articles'].length).to eq(1)
  end

  it 'rejects an unknown category ID instead of silently returning zero results' do
    portal = create(:portal, account: account)
    create(:article, account: account, portal: portal, author: user, title: 'Новая статья', content: 'Содержание', status: 'published')

    result = service.execute(query: 'Новая статья', category_id: 1, status: 'published', limit: 10)

    expect(result).to include('ERROR: ArgumentError: Unknown category_id 1 for the current account')
  end

  describe '#normalize_runtime_arguments' do
    it 'removes a category ID that the model added to a general article search' do
      arguments = { query: 'Новая статья', category_id: 1, status: '', limit: 5 }

      normalized = service.normalize_runtime_arguments(
        arguments,
        context: { captain_v2_current_input: 'Найди статью Новая статья' }
      )

      expect(normalized).to eq(query: 'Новая статья', status: 'published', limit: 5)
    end

    it 'preserves a category ID explicitly provided by the user' do
      arguments = { query: 'Новая статья', category_id: 7, status: 'published', limit: 5 }

      normalized = service.normalize_runtime_arguments(
        arguments,
        context: { captain_v2_current_input: 'Найди статью в категории ID 7' }
      )

      expect(normalized).to eq(arguments)
    end
  end
end
