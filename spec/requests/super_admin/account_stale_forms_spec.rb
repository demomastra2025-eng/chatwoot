# frozen_string_literal: true

require 'rails_helper'

# The edit form of an account and the organization block of its card are drawn from the state of the account at that
# moment. A save that finds the account changed by somebody else must not put the old values back: the organization is
# refused when it is not where the page saw it (SuperAdmin::OrganizationLinks `expected_holder`), and a section of the
# edit form (основное, лимиты, функции) whose state moved is left out of the save (SuperAdmin::AccountFormState).
RSpec.describe 'Super Admin forms drawn from an earlier state of an account', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:alatau) { create(:organization, name: 'Алатау') }
  let(:nur) { create(:organization, name: 'Нур') }
  let(:third) { create(:organization, name: 'Третья') }
  let(:account) { create(:account, name: 'Филиал 1', organization: alatau, limits: { 'agents' => 10 }) }

  def page = Nokogiri::HTML(response.body)

  def flashes = page.at_css('.flashes').text.squish

  def hidden(name) = page.at_css("input[type=hidden][name='#{name}']")&.[]('value')

  # What the browser would post back: the hidden tokens of the edit form as drawn
  def drawn_form_state
    get "/super_admin/accounts/#{account.id}/edit"
    %w[main limits features].index_with { |section| hidden("form_state[#{section}]") }
  end

  def move_meanwhile(organization)
    account.update_columns(organization_id: organization&.id) # rubocop:disable Rails/SkipsModelValidations
  end

  def link_audits = Audited::Audit.where(action: %w[link_organization unlink_organization])

  before { sign_in(super_admin, scope: :super_admin) }

  describe 'the edit form' do
    it 'carries the organization it was drawn with and a token for each section' do
      get "/super_admin/accounts/#{account.id}/edit"

      expect(hidden('expected_organization_id')).to eq(alatau.id.to_s)
      expect(%w[main limits features].map { |section| hidden("form_state[#{section}]") }).to all(match(/\A\h{16}\z/))
    end

    it 'carries an empty organization for an account that has none' do
      free = create(:account)

      get "/super_admin/accounts/#{free.id}/edit"

      expect(hidden('expected_organization_id')).to eq('')
    end

    it 'gives the same tokens until the account changes' do
      first = drawn_form_state
      expect(drawn_form_state).to eq(first)

      account.update!(name: 'Филиал 1 (новый)')
      changed = drawn_form_state

      expect(changed['main']).not_to eq(first['main'])
      expect(changed.values_at('limits', 'features')).to eq(first.values_at('limits', 'features'))
    end

    it 'keeps the tokens and the organization it was first drawn with when it comes back with errors' do
      state = drawn_form_state
      account.update!(limits: { 'agents' => 99 })

      patch "/super_admin/accounts/#{account.id}",
            params: { account: { name: '', organization_id: nur.id }, expected_organization_id: alatau.id, form_state: state }

      expect(response).to have_http_status(:unprocessable_content)
      expect(hidden('expected_organization_id')).to eq(alatau.id.to_s)
      expect(%w[main limits features].index_with { |section| hidden("form_state[#{section}]") }).to eq(state)
    end
  end

  describe 'the organization of the edit form' do
    def save(organization_id, expected: alatau.id.to_s, name: 'Филиал 1')
      patch "/super_admin/accounts/#{account.id}",
            params: { account: { name: name, organization_id: organization_id }, expected_organization_id: expected }
      follow_redirect!
    end

    it 'moves the account when it is still where the form saw it' do
      save(nur.id)

      expect(account.reload.organization).to eq(nur)
      expect(flashes).to include('Аккаунт перенесён в организацию «Нур».')
    end

    it 'refuses the move, and says who holds the account, when somebody moved it meanwhile' do
      move_meanwhile(third)

      save(nur.id, name: 'Филиал 1 (новый)')

      expect(account.reload).to have_attributes(organization: third, name: 'Филиал 1 (новый)')
      expect(flashes).to include('Аккаунт сохранён.', 'Организация аккаунта уже изменена: сейчас — «Третья».')
      expect(link_audits).to be_empty
    end

    it 'does not put the old organization back when the select was left as drawn' do
      move_meanwhile(third)

      save(alatau.id, name: 'Филиал 1 (новый)')

      expect(account.reload).to have_attributes(organization: third, name: 'Филиал 1 (новый)')
      expect(flashes).not_to include('организац')
      expect(link_audits).to be_empty
    end

    it 'does not unlink an account somebody moved to another organization' do
      move_meanwhile(third)

      save('')

      expect(account.reload.organization).to eq(third)
      expect(flashes).to include('сейчас — «Третья»')
      expect(link_audits).to be_empty
    end

    it 'accepts «Без организации» for an account somebody has already unlinked' do
      move_meanwhile(nil)

      save('')

      expect(account.reload.organization).to be_nil
      expect(flashes).not_to include('Организация аккаунта уже изменена')
      expect(link_audits).to be_empty
    end

    it 'refuses to link an account that had none when somebody linked it elsewhere meanwhile' do
      account.update_columns(organization_id: nil) # rubocop:disable Rails/SkipsModelValidations
      move_meanwhile(third)

      save(nur.id, expected: '')

      expect(account.reload.organization).to eq(third)
      expect(flashes).to include('сейчас — «Третья»')
    end

    it 'says the account has none when it was unlinked meanwhile and a move was asked for' do
      move_meanwhile(nil)

      save(nur.id)

      expect(account.reload.organization).to be_nil
      expect(flashes).to include('сейчас — без организации')
    end

    it 'refuses a change when the organization the form was drawn with does not exist or is not a number' do
      %w[0 abc].each do |expected|
        save(nur.id, expected: expected)

        expect(account.reload.organization).to eq(alatau)
        expect(flashes).to include('Организация аккаунта уже изменена')
      end
      patch "/super_admin/accounts/#{account.id}",
            params: { account: { name: 'Филиал 1', organization_id: nur.id }, expected_organization_id: [alatau.id] }
      follow_redirect!
      expect(account.reload.organization).to eq(alatau)
      expect(link_audits).to be_empty
    end

    it 'keeps the old behaviour for a request that does not say what it was drawn with' do
      move_meanwhile(third)

      patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1', organization_id: nur.id } }

      expect(account.reload.organization).to eq(nur)
    end
  end

  describe 'the organization block of the card' do
    it 'carries the organization it was drawn with' do
      get "/super_admin/accounts/#{account.id}"

      expect(hidden('expected_organization_id')).to eq(alatau.id.to_s)
    end

    it 'moves the account when it is where the card saw it' do
      post "/super_admin/accounts/#{account.id}/link_organization", params: { organization_id: nur.id, expected_organization_id: alatau.id }
      follow_redirect!

      expect(account.reload.organization).to eq(nur)
      expect(flashes).to include('Аккаунт перенесён в организацию «Нур».')
    end

    it 'refuses to move it when somebody moved it meanwhile, even to the organization the card showed' do
      move_meanwhile(third)

      post "/super_admin/accounts/#{account.id}/link_organization", params: { organization_id: alatau.id, expected_organization_id: alatau.id }
      follow_redirect!

      expect(account.reload.organization).to eq(third)
      expect(flashes).to include('Организация аккаунта уже изменена: сейчас — «Третья».')
      expect(link_audits).to be_empty
    end

    it 'refuses to unlink it when somebody moved it meanwhile' do
      move_meanwhile(third)

      post "/super_admin/accounts/#{account.id}/link_organization", params: { organization_id: '', expected_organization_id: alatau.id }
      follow_redirect!

      expect(account.reload.organization).to eq(third)
      expect(flashes).to include('сейчас — «Третья»')
    end

    it 'moves the account from wherever it is for a request that does not say what it was drawn with' do
      move_meanwhile(third)

      post "/super_admin/accounts/#{account.id}/link_organization", params: { organization_id: nur.id }

      expect(account.reload.organization).to eq(nur)
    end
  end

  describe 'the sections of the edit form' do
    def save(state, account_params: {}, features: nil)
      params = { account: { name: 'Филиал 1', locale: 'ru', status: 'active' }.merge(account_params), form_state: state }
      params[:enabled_features] = features if features
      patch "/super_admin/accounts/#{account.id}", params: params
      follow_redirect!
    end

    it 'saves every section when nothing changed since the form was drawn' do
      state = drawn_form_state

      save(state, account_params: { name: 'Филиал 1 (новый)', limits: { agents: '12' } }, features: { feature_sla: 'true' })

      expect(account.reload).to have_attributes(name: 'Филиал 1 (новый)')
      expect(account.limits).to include('agents' => 12)
      expect(account).to be_feature_enabled('sla')
      expect(flashes).not_to include('Пока форма была открыта')
    end

    it 'leaves the limits as they are when somebody changed them meanwhile, and saves the rest' do
      state = drawn_form_state
      account.update!(limits: { 'agents' => 50 })

      save(state, account_params: { name: 'Филиал 1 (новый)', limits: { agents: '10' } }, features: { feature_sla: 'true' })

      expect(account.reload).to have_attributes(name: 'Филиал 1 (новый)')
      expect(account.limits).to eq('agents' => 50)
      expect(account).to be_feature_enabled('sla')
      expect(flashes).to include('Аккаунт сохранён.', 'Пока форма была открыта, в аккаунте изменилось: лимиты.')
    end

    it 'leaves the excluded users with the limits' do
      state = drawn_form_state
      account.update!(limits: { 'agents' => 50 })

      save(state, account_params: { limit_counter_excluded_user_ids_raw: '4, 5' })

      expect(account.reload.custom_attributes['limit_counter_excluded_user_ids']).to be_blank
    end

    it 'leaves the functions as they are when somebody changed them meanwhile, and saves the rest' do
      state = drawn_form_state
      account.enable_features!('sla')

      save(state, account_params: { name: 'Филиал 1 (новый)' }, features: { feature_sla: 'false' })

      expect(account.reload).to have_attributes(name: 'Филиал 1 (новый)')
      expect(account).to be_feature_enabled('sla')
      expect(flashes).to include('в аккаунте изменилось: функции.')
    end

    it 'does not write a change of the owner decision switches that was dropped, nor audit it' do
      state = drawn_form_state
      account.enable_features!('sla')

      expect { save(state, features: { feature_sla: 'false', feature_communication_threads: 'true' }) }
        .not_to change(Audited::Audit.where(action: 'update_service_flags'), :count)
      expect(account.reload).not_to be_feature_enabled('communication_threads')
    end

    it 'leaves the name, the language and the status as they are when somebody changed them meanwhile' do
      state = drawn_form_state
      account.update!(status: :suspended, name: 'Филиал 1 (другое имя)')

      language = account.locale

      save(state, account_params: { name: 'Филиал 1 (новый)', locale: 'kk', status: 'active' })

      expect(account.reload).to have_attributes(name: 'Филиал 1 (другое имя)', status: 'suspended', locale: language)
      expect(flashes).to include('в аккаунте изменилось: основное.')
    end

    it 'names every section that changed' do
      state = drawn_form_state
      account.update!(limits: { 'agents' => 50 }, name: 'Другое имя')
      account.enable_features!('sla')

      save(state, account_params: { name: 'Новое имя' }, features: { feature_sla: 'false' })

      expect(flashes).to include('в аккаунте изменилось: основное, лимиты, функции.')
    end

    it 'saves nothing from the sections when the tokens cannot be read' do
      patch "/super_admin/accounts/#{account.id}",
            params: { account: { name: 'Филиал 1 (новый)', limits: { agents: '1' } }, form_state: { main: 'x' } }
      follow_redirect!

      expect(account.reload).to have_attributes(name: 'Филиал 1')
      expect(account.limits).to eq('agents' => 10)
      expect(flashes).to include('в аккаунте изменилось: основное, лимиты, функции.')
    end

    it 'does not check a request without tokens (a script or a page opened before the update)' do
      account.update!(limits: { 'agents' => 50 })

      patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1 (новый)', limits: { agents: '12' } } }

      expect(account.reload).to have_attributes(name: 'Филиал 1 (новый)')
      expect(account.limits).to include('agents' => 12)
    end

    it 'does not check the switches of the fine tuning of the card, which post no form state' do
      patch "/super_admin/accounts/#{account.id}", params: { enabled_features: { feature_sla: 'true' } }

      expect(account.reload).to be_feature_enabled('sla')
    end
  end

  describe SuperAdmin::AccountFormState do
    it 'has a token of 16 characters for each section that depends only on what the section holds' do
      tokens = described_class.new(account).tokens
      account.update!(status: :suspended)
      changed = described_class.new(account).tokens

      expect(tokens.keys).to eq(%w[main limits features])
      expect(changed['main']).not_to eq(tokens['main'])
      expect(changed.values_at('limits', 'features')).to eq(tokens.values_at('limits', 'features'))
    end

    it 'does not mix the organization into any token (it has its own guard)' do
      tokens = described_class.new(account).tokens
      account.update_columns(organization_id: nur.id) # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.new(account.reload).tokens).to eq(tokens)
    end

    it 'finds no stale section without tokens' do
      expect(described_class.stale_sections(account, nil)).to eq([])
    end
  end
end
