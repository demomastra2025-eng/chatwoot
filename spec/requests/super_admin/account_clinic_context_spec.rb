require 'rails_helper'

# The clinic context of an account (the "# Clinic" block of every external AI agent): edited only by the platform team, on the
# edit form of the account, and shown on its card.
RSpec.describe 'Super Admin, the clinic context of an account', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account, name: 'МО Әлия') }
  let(:text) { "Клиника:\n- МО «Әлия», г. Актобе.\n- ИИН пациента в карточке: [ИИН пациента](field://contact.identifier)" }

  before { sign_in(super_admin, scope: :super_admin) }

  def page = Nokogiri::HTML(response.body)

  def squished(node) = node.text.squish

  def flashes = squished(page.at_css('.flashes'))

  def field = page.at_css('textarea[name="account[captain_clinic_context]"]')

  def drawn_form_state
    get "/super_admin/accounts/#{account.id}/edit"
    %w[main limits features ai].index_with { |section| page.at_css("input[type=hidden][name='form_state[#{section}]']")['value'] }
  end

  def save(value, state: nil)
    params = { account: { name: account.name, captain_clinic_context: value } }
    params[:form_state] = state if state
    patch "/super_admin/accounts/#{account.id}", params: params
  end

  describe 'the edit form' do
    it 'has the text in the section «ИИ», with its label and its rules' do
      account.update!(captain_clinic_context: text)

      get "/super_admin/accounts/#{account.id}/edit"

      expect(field.text.delete_prefix("\n")).to eq(text)
      expect(squished(field.ancestors('fieldset').first.at_css('legend'))).to eq('ИИ')
      expect(squished(page.at_css('label[for="account_captain_clinic_context"]'))).to eq('Контекст клиники')
      expect(response.body).to include('До 6 000 символов', 'клиника его не видит')
      expect(response.body).not_to include('translation missing')
    end

    it 'saves the text into internal_attributes' do
      save(text, state: drawn_form_state)

      expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
      expect(account.reload.captain_clinic_context).to eq(text)
      expect(account.internal_attributes['captain_clinic_context']).to eq(text)
    end

    it 'clears it when the field is emptied' do
      account.update!(captain_clinic_context: text)

      save('', state: drawn_form_state)

      expect(account.reload.internal_attributes).not_to have_key('captain_clinic_context')
    end

    it 'refuses a link to a tool and saves nothing of the form' do
      save('Запись: [@Запись](tool://create_appointment).', state: drawn_form_state)

      expect(response).to have_http_status(:unprocessable_content)
      expect(squished(page.at_css('#error_explanation'))).to include('Контекст клиники не может ссылаться на инструменты и навыки')
      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'refuses a field that is not a contact field and a text over 6 000 characters' do
      save('Сделка: [Сделка](field://deal.title).')
      expect(squished(page.at_css('#error_explanation'))).to include('может ссылаться только на поля контакта')

      save('я' * 6001)
      expect(squished(page.at_css('#error_explanation'))).to include('Контекст клиники слишком длинное (максимум 6000 символов)')
      expect(account.reload.captain_clinic_context).to eq('')
    end

    it 'does not put the old text back when the rake wrote a newer one while the form was open, and says so' do
      account.update!(captain_clinic_context: text)
      state = drawn_form_state
      account.update!(captain_clinic_context: "#{text}\n- Новый факт.")

      patch "/super_admin/accounts/#{account.id}",
            params: { account: { name: 'МО Әлия (новое)', captain_clinic_context: text }, form_state: state }
      follow_redirect!

      expect(account.reload).to have_attributes(name: 'МО Әлия (новое)', captain_clinic_context: "#{text}\n- Новый факт.")
      expect(flashes).to include('Пока форма была открыта, в аккаунте изменилось: контекст клиники.')
    end

    it 'keeps working for a page drawn before the section existed, which posts no token and no field of it' do
      state = drawn_form_state.except('ai')
      account.update!(captain_clinic_context: text)

      patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'МО Әлия (новое)' }, form_state: state }
      follow_redirect!

      expect(account.reload).to have_attributes(name: 'МО Әлия (новое)', captain_clinic_context: text)
      expect(flashes).not_to include('Пока форма была открыта')
    end
  end

  describe 'the card' do
    def row = squished(page.at_css('[data-testid="ai-block"] [data-ai-row="clinic-context"]'))

    it 'says that the clinic has no clinic context' do
      get "/super_admin/accounts/#{account.id}"

      expect(row).to eq('Контекст клиники не задан')
      expect(page.at_css('[data-testid="clinic-context"]')).to be_nil
    end

    it 'gives the length and the text, collapsed' do
      account.update!(captain_clinic_context: text)

      get "/super_admin/accounts/#{account.id}"

      expect(row).to eq('Контекст клиники 102 символа из 6 000')
      expect(page.at_css('details[data-testid="clinic-context"] pre').text).to eq(text)
    end
  end
end
