# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join 'spec/models/concerns/access_tokenable_shared.rb'

RSpec.describe PlatformApp do
  let(:platform_app) { create(:platform_app) }

  context 'with validations' do
    it { is_expected.to validate_presence_of(:name) }
  end

  context 'with associations' do
    it { is_expected.to have_many(:platform_app_permissibles) }
  end

  describe 'with concerns' do
    it_behaves_like 'access_tokenable'
  end

  describe 'with factories' do
    it { expect(platform_app).present? }
  end

  describe 'what the partner owns' do
    let(:account) { create(:account) }
    let(:user) { create(:user) }

    before do
      create(:platform_app_permissible, platform_app: platform_app, permissible: account)
      create(:platform_app_permissible, platform_app: platform_app, permissible: user)
    end

    it 'lists its accounts and its users, and counts them' do
      other_app = create(:platform_app)
      create(:platform_app_permissible, platform_app: other_app, permissible: create(:account))

      expect(platform_app.accounts).to contain_exactly(account)
      expect(platform_app.users).to contain_exactly(user)
      expect(platform_app).to have_attributes(accounts_count: 1, users_count: 1)
    end

    it 'owns a super admin only when it was recorded as a user permissible, which the API no longer does' do
      super_admin = create(:super_admin)
      expect(platform_app.owns?(super_admin)).to be(false)

      create(:platform_app_permissible, platform_app: platform_app, permissible: super_admin)
      expect(platform_app.owns?(super_admin)).to be(true)
      expect(platform_app.users).to include(super_admin.becomes(User))
    end

    it 'owns what it created and nothing else' do
      expect(platform_app.owns?(account)).to be(true)
      expect(platform_app.owns?(user)).to be(true)
      expect(platform_app.owns?(create(:account))).to be(false)
      expect(platform_app.owns?(nil)).to be(false)
    end
  end

  describe '#token_hint' do
    it 'is the last 4 characters of the token behind dots' do
      expect(platform_app.token_hint).to eq("••••#{platform_app.access_token.token.last(4)}")
      expect(platform_app.token_hint).not_to include(platform_app.access_token.token)
    end
  end
end
