require 'rails_helper'

# «Заблокировать» / «Разблокировать» in the header of the card of an account: it asks first (with a reason and a comment, both
# optional), writes the audit log, and the card says when, by whom and why the account was blocked. The status is not edited in the
# form of the account any more.
RSpec.describe 'Super Admin blocking an account', type: :request do
  let(:super_admin) { create(:super_admin, name: 'Айдар Админ') }
  let(:account) { create(:account, name: 'Аккаунт Алатау') }
  let(:card_path) { "/super_admin/accounts/#{account.id}" }

  before { sign_in(super_admin, scope: :super_admin) }

  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def panel(key) = page.at_css("[data-testid='confirm-#{key}']")

  def audits(action) = Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: action)

  describe 'the header of the card' do
    it 'offers «Заблокировать» for an account that works, with a panel that asks for the reason and a comment', :aggregate_failures do
      get card_path

      node = panel('block')
      expect(text(node.at_css('summary'))).to eq('Заблокировать')
      expect(text(node.at_css('.admin-ask__title'))).to eq('Заблокировать аккаунт «Аккаунт Алатау»?')
      expect(text(node.at_css('.admin-ask__panel')))
        .to include('Операторы не смогут работать в аккаунте', 'Сообщения клиентов из WhatsApp, Telegram, почты и чата на сайте',
                    'не сохранятся', 'сохранённые данные не удаляются', 'журнал аудита')
      expect(node.at_css('form')['action']).to eq("#{card_path}/suspend")
      expect(node.css('select[name="reason"] option').map { |option| [text(option), option['value']] })
        .to eq([['Не указана', ''], %w[Неоплата non_payment], ['По просьбе клиента', 'client_request'], %w[Другое other]])
      expect(node.at_css('textarea[name="note"]')['maxlength']).to eq('300')
      expect(text(node.at_css('button[type="submit"]'))).to eq('Да, заблокировать')
      expect(panel('unblock')).to be_nil
      expect(page.at_css('[data-testid="block-banner"]')).to be_nil
    end

    it 'offers «Разблокировать» for a blocked account instead, and a strip that says it is blocked' do
      account.update!(status: :suspended)

      get card_path

      node = panel('unblock')
      expect(text(node.at_css('summary'))).to eq('Разблокировать')
      expect(text(node.at_css('.admin-ask__title'))).to eq('Разблокировать аккаунт «Аккаунт Алатау»?')
      expect(node.at_css('form')['action']).to eq("#{card_path}/activate")
      expect(panel('block')).to be_nil
      expect(text(page.at_css('[data-testid="block-banner"]')))
        .to include('Аккаунт заблокирован', 'Операторы не могут работать в аккаунте', 'новые сообщения клиентов', 'не принимаются')
      expect(text(page.at_css('[data-testid="account-status"]'))).to eq('Заблокирован')
    end

    it 'offers neither for an account that is being deleted: the deletion is cancelled first' do
      account.update!(status: :suspended, custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })

      get card_path

      expect(panel('block')).to be_nil
      expect(panel('unblock')).to be_nil
      expect(page.at_css('[data-testid="block-banner"]')).to be_nil
    end

    it 'has no browser pop-up question on the buttons of the header' do
      get card_path

      expect(page.css('header [data-confirm]')).to be_empty
    end
  end

  describe 'blocking' do
    it 'blocks the account and writes the reason, the comment and who did it' do
      post "#{card_path}/suspend", params: { reason: 'non_payment', note: 'счёт за октябрь не оплачен' }

      expect(response).to redirect_to(card_path)
      expect(flash[:notice]).to eq('Аккаунт «Аккаунт Алатау» заблокирован.')
      expect(account.reload).to be_suspended
      audit = audits('suspend_account').last
      expect(audit).to have_attributes(associated_id: account.id, user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to eq('status' => %w[active suspended], 'reason' => 'non_payment', 'note' => 'счёт за октябрь не оплачен')
    end

    it 'blocks without a reason and without a comment, which are both optional' do
      post "#{card_path}/suspend"

      expect(account.reload).to be_suspended
      expect(audits('suspend_account').last.audited_changes).to eq('status' => %w[active suspended])
    end

    it 'does not take a reason the list does not offer, and cuts a long comment' do
      post "#{card_path}/suspend", params: { reason: 'because', note: "#{'я' * 400}\n  второй   абзац" }

      audit = audits('suspend_account').last
      expect(audit.audited_changes).not_to include('reason')
      expect(audit.audited_changes['note'].length).to eq(SuperAdmin::AccountBlocking::NOTE_LIMIT)
      expect(audit.audited_changes['note']).to end_with('...')
    end

    it 'leaves only the entry that says why: the automatic «Изменение» entry is not written' do
      post "#{card_path}/suspend", params: { reason: 'other' }

      expect(Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: 'update')).to be_empty
    end

    it 'says so and writes nothing when the account is blocked already' do
      account.update!(status: :suspended)

      expect { post "#{card_path}/suspend", params: { reason: 'other' } }.not_to(change { audits('suspend_account').count })

      expect(flash[:alert]).to eq('Аккаунт «Аккаунт Алатау» уже заблокирован.')
    end

    it 'refuses an account that is being deleted' do
      account.update!(custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })

      post "#{card_path}/suspend", params: { reason: 'other' }

      expect(account.reload).to be_active
      expect(flash[:alert]).to eq('Аккаунт назначен на удаление: сначала отмените удаление.')
      expect(audits('suspend_account')).to be_empty
    end

    it 'is not open to a visitor who has not signed in' do
      sign_out(:super_admin)

      post "#{card_path}/suspend"

      expect(response).to have_http_status(:redirect)
      expect(account.reload).to be_active
    end
  end

  describe 'the strip of a blocked account' do
    it 'says when it was blocked, by whom, why and with what comment' do
      post "#{card_path}/suspend", params: { reason: 'client_request', note: 'клиент попросил приостановить' }

      get card_path

      strip = page.at_css('[data-testid="block-banner"]')
      expect(text(strip)).to include('Аккаунт заблокирован', 'Айдар Админ')
      expect(text(strip)).to include(SuperAdmin::DisplayHelper.format_time(audits('suspend_account').last.created_at))
      expect(text(strip.at_css('[data-testid="block-reason"]'))).to eq('Причина: По просьбе клиента. Комментарий: клиент попросил приостановить')
    end

    it 'says only that the account is blocked when nothing explains it (it was blocked before the entries existed)' do
      account.update!(status: :suspended)

      get card_path

      strip = page.at_css('[data-testid="block-banner"]')
      expect(text(strip.at_css('span'))).to eq('Аккаунт заблокирован')
      expect(strip.at_css('[data-testid="block-reason"]')).to be_nil
    end

    it 'shows a block made on the list with many accounts, which has no reason' do
      SuperAdmin::BulkAccounts.new(action: 'suspend', ids: [account.id], actor: super_admin).apply

      get card_path

      strip = page.at_css('[data-testid="block-banner"]')
      expect(text(strip)).to include('Аккаунт заблокирован')
      expect(strip.at_css('[data-testid="block-reason"]')).to be_nil
    end
  end

  describe 'unblocking' do
    before { account.update!(status: :suspended) }

    it 'unblocks the account and writes who did it' do
      post "#{card_path}/activate"

      expect(response).to redirect_to(card_path)
      expect(flash[:notice]).to eq('Аккаунт «Аккаунт Алатау» разблокирован.')
      expect(account.reload).to be_active
      audit = audits('activate_account').last
      expect(audit).to have_attributes(associated_id: account.id, user_id: super_admin.id)
      expect(audit.audited_changes).to eq('status' => %w[suspended active])
    end

    it 'takes the strip away, and the next block does not inherit the old reason' do
      post "#{card_path}/suspend", params: { reason: 'non_payment' }
      post "#{card_path}/activate"
      get card_path
      expect(page.at_css('[data-testid="block-banner"]')).to be_nil

      post "#{card_path}/suspend"
      get card_path
      expect(page.at_css('[data-testid="block-reason"]')).to be_nil
    end

    it 'says so and writes nothing when the account works already' do
      account.update!(status: :active)

      expect { post "#{card_path}/activate" }.not_to(change { audits('activate_account').count })

      expect(flash[:alert]).to eq('Аккаунт «Аккаунт Алатау» уже работает.')
    end

    it 'refuses an account that is being deleted' do
      account.update!(custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })

      post "#{card_path}/activate"

      expect(account.reload).to be_suspended
      expect(flash[:alert]).to eq('Аккаунт назначен на удаление: сначала отмените удаление.')
    end
  end

  describe 'the form of the account' do
    it 'does not edit the status any more: no list of statuses, and a status that is sent is not taken' do
      get "#{card_path}/edit"

      expect(page.css('[name="account[status]"]')).to be_empty
      expect(page.css('label[for="account_status"]')).to be_empty

      patch card_path, params: { account: { name: 'Аккаунт Алатау 2', status: 'suspended' } }

      expect(account.reload).to have_attributes(name: 'Аккаунт Алатау 2', status: 'active')
    end

    it 'is not made stale by a block or an unblock made while it was open' do
      get "#{card_path}/edit"
      form_state = page.css('input[name^="form_state"]').to_h { |input| [input['name'][/\[(\w+)\]/, 1], input['value']] }

      post "#{card_path}/suspend"
      patch card_path, params: { account: { name: 'Аккаунт Алатау 2' }, form_state: form_state }

      expect(account.reload.name).to eq('Аккаунт Алатау 2')
      expect(flash[:alert].to_s).not_to include('изменил')
    end
  end

  describe 'the audit log page' do
    it 'names the entries in Russian and offers them in the filter' do
      post "#{card_path}/suspend", params: { reason: 'other' }
      post "#{card_path}/activate"

      get '/super_admin/audits', params: { account_id: account.id }

      expect(page.css('tbody .admin-badge').map { |badge| text(badge) }).to include('Блокировка аккаунта', 'Разблокировка аккаунта')
      expect(page.css('select[name="audit_action"] option').map { |option| option['value'] }).to include('suspend_account', 'activate_account')
    end
  end
end
