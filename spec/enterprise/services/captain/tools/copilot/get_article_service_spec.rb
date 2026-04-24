require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetArticleService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('get_article')
    end
  end

  describe '#active?' do
    context 'when user is an admin' do
      let(:user) { create(:user, :administrator, account: account) }

      it 'returns true' do
        expect(service.active?).to be true
      end
    end

    context 'when user has custom role without knowledge_base_manage permission' do
      let(:custom_role) { create(:custom_role, account: account, permissions: []) }

      before do
        account_user = AccountUser.find_by(user: user, account: account)
        account_user.update(role: :agent, custom_role: custom_role)
      end

      it 'returns false' do
        expect(service.active?).to be false
      end
    end
  end

  describe '#execute' do
    it 'returns not found message when article is missing' do
      expect(service.execute(article_id: 999)).to eq('Article not found')
    end

    it 'returns a normalized article payload' do
      portal = create(:portal, account: account)
      article = create(:article, account: account, portal: portal, author: user, title: 'Test Article', content: 'Content')

      payload = JSON.parse(service.execute(article_id: article.id))

      expect(payload['article']).to include(
        'id' => article.id,
        'title' => 'Test Article',
        'content' => 'Content',
        'portal_id' => portal.id,
        'author_id' => user.id,
        'author_name' => user.name
      )
    end
  end
end
