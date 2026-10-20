# frozen_string_literal: true

require 'rails_helper'

# The limits of an account as three plain choices (Accounts::LimitSettings): «Как в тарифе», «Без ограничений», «Своё число».
# They are drawn on the card (a form of its own) and on the edit form, saved through the normal update of the account, and every
# change is written to the audit log in words.
RSpec.describe 'Super Admin limits of an account', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account, name: 'Аккаунт Алатау') }
  let(:card_path) { "/super_admin/accounts/#{account.id}" }
  let(:max) { ChatwootApp.max_limit }
  let(:marks_key) { Accounts::LimitSettings::KEY }
  let(:keys) { SuperAdmin::LimitWords::SCREEN_ORDER }

  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def row(key) = page.at_css("[data-testid='limit-rows'] [data-limit='#{key}']")

  def choice_of(key) = row(key).at_css('input[type=radio][checked]')&.[]('value')

  def apply_plan!(modules: [])
    Accounts::ApplyPlan.new(account: account, modules: modules).call
  end

  # What the browser posts from a row: the radio button and the field of the number
  def choices(**choices)
    kinds = choices.transform_values { |choice| choice.is_a?(Array) ? choice.first : choice }
    values = choices.select { |_key, choice| choice.is_a?(Array) }.transform_values(&:last)
    { limit_choices: kinds, limit_values: values }
  end

  def save_from_card(account_params, extra = {})
    get card_path
    tokens = %w[main limits features].index_with { |section| page.at_css("input[name='form_state[#{section}]']")['value'] }
    patch card_path, params: { account: account_params, form_state: tokens, return_to: 'card' }.merge(extra)
  end

  # What a browser sends for a form: every successful control as it is drawn (the checked radio buttons, the hidden fields, the number of
  # every row), with `overrides` ({ 'account[name]' => 'New' }) for what the person changed
  def drawn_body(form, overrides = {})
    pairs = form.css('input, select, textarea').filter_map do |node|
      name = node['name']
      next if name.blank? || node['disabled']

      value = drawn_value(node)
      [name, overrides.fetch(name, value)] unless value.nil?
    end
    URI.encode_www_form(pairs)
  end

  def drawn_value(node)
    case node.name
    when 'select' then selected_value(node)
    when 'textarea' then node.text
    else input_value(node)
    end
  end

  def selected_value(select)
    option = select.at_css('option[selected]') || select.at_css('option')
    option && (option['value'] || option.text)
  end

  # nil: the control is not sent (a button, a radio button or a checkbox that is not checked)
  def input_value(input)
    type = (input['type'] || 'text').downcase
    return if %w[submit button image file].include?(type)
    return if %w[radio checkbox].include?(type) && !input['checked']

    input['value'] || (type == 'checkbox' ? 'on' : '')
  end

  def send_drawn(form, overrides)
    post form['action'], params: drawn_body(form, overrides), headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
  end

  def save_edit_form_as_drawn(overrides = {})
    get "/super_admin/accounts/#{account.id}/edit"
    send_drawn(page.at_css('form.form'), overrides)
  end

  def save_card_as_drawn(overrides = {})
    get card_path
    send_drawn(page.at_css('form#limits-form'), overrides)
  end

  def limit_audits = Audited::Audit.where(action: 'update_limits')

  before do
    sign_in(super_admin, scope: :super_admin)
    GlobalConfig.clear_cache
  end

  describe 'the card' do
    before { apply_plan! }

    it 'has one row per limit, in order, each with the three choices' do
      get card_path

      expect(page.css("[data-testid='limit-rows'] [data-limit]").map { |node| node['data-limit'] }).to eq(keys)
      keys.each do |key|
        radios = row(key).css('input[type=radio]')
        expect(radios.map { |radio| radio['value'] }).to eq(%w[plan unlimited custom])
        expect(radios.map { |radio| radio['name'] }.uniq).to eq(["account[limit_choices][#{key}]"])
        expect(row(key).at_css("input[name='account[limit_values][#{key}]']")).to be_present
      end
      expect(row('agents').at_css('input[name="account[limit_values][agents]"]')['type']).to eq('number')
      expect(response.body).not_to include('translation missing')
    end

    it 'names the choices in plain words and says what «как в тарифе» gives now' do
      get card_path

      expect(text(row('conversations').at_css('.admin-limit__choices'))).to eq('Как в тарифе сейчас: без ограничений Без ограничений Своё число')
      expect(text(row('agents').at_css('.admin-limit__choices'))).to include('Как в тарифе сейчас: без ограничений')
    end

    it 'says what applies now in words' do
      account.update!(limits: account.limits.merge('agents' => 5, 'storage_bytes' => 50.gigabytes))

      get card_path

      expect(text(row('agents').at_css('[data-testid="limit-now"]'))).to eq('Сейчас: 5 операторов')
      expect(text(row('storage_bytes').at_css('[data-testid="limit-now"]'))).to eq('Сейчас: 50 ГБ')
      expect(text(row('conversations').at_css('[data-testid="limit-now"]'))).to eq('Сейчас: без ограничений')
    end

    it 'speaks Russian plural forms' do
      account.update!(limits: account.limits.merge('agents' => 2, 'inboxes' => 1, 'emails' => 21, 'captain_tokens' => 5))

      get card_path

      expect(text(row('agents').at_css('[data-testid="limit-now"]'))).to eq('Сейчас: 2 оператора')
      expect(text(row('inboxes').at_css('[data-testid="limit-now"]'))).to eq('Сейчас: 1 канал')
      expect(text(row('emails').at_css('[data-testid="limit-now"]'))).to eq('Сейчас: 21 письмо в день')
      expect(text(row('captain_tokens').at_css('[data-testid="limit-now"]'))).to eq('Сейчас: 5 токенов ИИ')
    end

    it 'checks «Как в тарифе» for an account that has chosen nothing' do
      get card_path

      expect(keys.map { |key| choice_of(key) }.uniq).to eq(['plan'])
    end

    it 'checks the choice made for each limit, and fills the field of the number only for «Своё число»' do
      account.update!(limits: account.limits.merge('agents' => 5, 'storage_bytes' => 1.5.gigabytes, 'inboxes' => max),
                      custom_attributes: account.custom_attributes.merge(marks_key => { 'agents' => 5, 'storage_bytes' => 1.5.gigabytes.to_i,
                                                                                        'inboxes' => 'unlimited' }))

      get card_path

      expect(choice_of('agents')).to eq('custom')
      expect(row('agents').at_css('input[type=number]')['value']).to eq('5')
      expect(choice_of('storage_bytes')).to eq('custom')
      expect(row('storage_bytes').at_css('input[name="account[limit_values][storage_bytes]"]')['value']).to eq('1.5')
      expect(text(row('storage_bytes').at_css('.admin-limit__value'))).to include('ГБ')
      expect(choice_of('inboxes')).to eq('unlimited')
      expect(choice_of('conversations')).to eq('plan')
    end

    it 'never shows the number that stands for no limit' do
      account.update!(limits: account.limits.merge('inboxes' => max, 'storage_bytes' => max * 1.gigabyte, 'captain_tokens' => max * 1_000_000))

      get card_path

      block = page.at_css("[data-testid='usage-block']")
      expect(block.to_html).not_to match(/100[  ]?000/)
      expect(block.to_html).not_to include((max * 1.gigabyte).to_s, (max * 1_000_000).to_s)
      expect(choice_of('inboxes')).to eq('unlimited')
      expect(choice_of('storage_bytes')).to eq('unlimited')
      expect(text(row('storage_bytes').at_css('.admin-limit__usage'))).to include('Без ограничений')
    end

    it 'keeps what is used and the meter next to each limit' do
      account.update!(limits: account.limits.merge('agents' => 10))
      create_list(:user, 2, account: account)

      get card_path

      expect(text(row('agents').at_css('.admin-limit__usage'))).to include('2 из 10')
      expect(row('agents').at_css('.admin-meter')).to be_present
      expect(row('conversations').at_css('.admin-meter')).to be_nil # no limit, nothing to fill
      expect(page.css("[data-testid='limit-rows'] .admin-limit__hint").size).to eq(9)
    end

    it 'says that a limit with the older number of the plan will be updated when the plan is applied' do
      allow(Accounts::Plans).to(receive(:limits_for).and_wrap_original { |original, *args| original.call(*args).merge('conversations' => 1000) })

      get card_path

      drift = text(row('conversations').at_css('[data-testid="limit-drift"]'))
      expect(drift).to include('Сейчас действует без ограничений, а по тарифу — 1 000 диалогов')
      expect(text(row('conversations').at_css('.admin-limit__choices'))).to include('Как в тарифе сейчас: 1 000 диалогов')
      expect(row('agents').at_css('[data-testid="limit-drift"]')).to be_nil
    end

    it 'does not blame the plan for the zero a trial left' do
      account.update!(limits: account.limits.merge('agents' => 5, 'inboxes' => 3))
      account.activate_trial!(3)
      account.expire_trial!

      get card_path

      expect(text(row('agents').at_css('[data-testid="limit-now"]'))).to include('Сейчас: 0 операторов')
      expect(choice_of('agents')).to eq('plan')
      expect(row('agents').at_css('[data-testid="limit-drift"]')).to be_nil
    end

    it 'says why a limit is 0 when the end of a trial put it there, and says nothing for the others' do
      account.update!(limits: account.limits.merge('agents' => 5, 'inboxes' => 3))
      account.activate_trial!(3)
      account.expire_trial!

      get card_path

      note = 'Пробный период закончился и закрыл этот лимит (0). Он вернётся, когда вы примените тариф.'
      expect(text(row('agents').at_css('[data-testid="limit-held"]'))).to eq(note)
      expect(text(row('inboxes').at_css('[data-testid="limit-held"]'))).to eq(note)
      expect(row('conversations').at_css('[data-testid="limit-held"]')).to be_nil
    end

    it 'says the storage with the decimals of its field, and takes the comma in a text field made for it' do
      account.update!(limits: account.limits.merge('storage_bytes' => 5_000_000_000))

      get card_path

      field = row('storage_bytes').at_css('input[name="account[limit_values][storage_bytes]"]')
      expect(field['type']).to eq('text')
      expect(field['inputmode']).to eq('decimal')
      expect(field['value']).to eq('4.66')
      expect(text(row('storage_bytes').at_css('[data-testid="limit-now"]'))).to eq('Сейчас: 4,66 ГБ')
      expect(text(row('storage_bytes').at_css('.admin-limit__value'))).to include('ГБ')
    end
  end

  describe 'an account without a plan' do
    it 'says that «как в тарифе» then means the general values of the platform' do
      get card_path

      expect(text(page.at_css('[data-testid="limits-no-plan"]'))).to include('Тариф не назначен')
    end

    it 'shows the general value of the platform as what «как в тарифе» gives' do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with('ACCOUNT_CONVERSATIONS_LIMIT').and_return('ACCOUNT_CONVERSATIONS_LIMIT' => 500)

      get card_path

      expect(text(row('conversations').at_css('.admin-limit__choices'))).to include('Как в тарифе сейчас: 500 диалогов')
    end

    it 'reads the numbers the account holds as «своё число», without writing anything' do
      account.update!(limits: { 'agents' => 12, 'storage_bytes' => 50.gigabytes })
      stored = Account.find(account.id).attributes

      get card_path

      expect(choice_of('agents')).to eq('custom')
      expect(choice_of('storage_bytes')).to eq('custom')
      expect(choice_of('inboxes')).to eq('plan')
      expect(Account.find(account.id).attributes).to eq(stored)
    end
  end

  describe 'an account from before the choices, with a plan' do
    it 'reads a number that equals the plan one as «как в тарифе» and any other number as «своё число»' do
      apply_plan!
      account.update!(custom_attributes: account.custom_attributes.except(marks_key),
                      limits: { 'conversations' => max, 'non_web_inboxes' => 3, 'agents' => 7 })

      get card_path

      expect(choice_of('conversations')).to eq('plan')
      expect(choice_of('non_web_inboxes')).to eq('custom')
      expect(row('non_web_inboxes').at_css('input[type=number]')['value']).to eq('3')
      expect(choice_of('agents')).to eq('custom')
    end
  end

  describe 'the edit form' do
    before { apply_plan! }

    it 'has the same rows in the section «Лимиты», and no bare numbers to type' do
      get "/super_admin/accounts/#{account.id}/edit"

      expect(response).to have_http_status(:ok)
      expect(page.css('fieldset.form-section > legend').map { |legend| text(legend) }).to eq(['Основное', 'Лимиты', 'Тонкая настройка'])
      expect(page.css("[data-testid='limit-rows'] [data-limit]").map { |node| node['data-limit'] }).to eq(keys)
      expect(page.css('input[name^="account[limits]"]')).to be_empty
      expect(page.css('input[name^="account[limit_choices]"][type=radio]').size).to eq(27)
      expect(response.body).to include('У каждого лимита три варианта')
    end

    it 'shows the spend with meters in the rows' do
      get "/super_admin/accounts/#{account.id}/edit"

      expect(page.css('[data-limit] .admin-limit__usage').size).to eq(9)
      expect(response.body).not_to match(/Unlimited|Usage is read-only|Resettable counters|Leave a field blank|Outbound|Captain responses/)
    end

    it 'is one form: the rows are saved with the name and the functions' do
      get "/super_admin/accounts/#{account.id}/edit"

      form = page.at_css('form.form')
      expect(form.css('[data-limit]').size).to eq(9)
      expect(form.at_css('input[name="account[name]"]')).to be_present
    end

    it 'saves the choices with the rest of the form' do
      patch card_path,
            params: { account: { name: 'Аккаунт Алатау 2' }.merge(choices(agents: %w[custom 12], storage_bytes: ['custom', '1,5'],
                                                                          emails: 'unlimited')) }

      expect(response).to redirect_to(card_path)
      account.reload
      expect(account.name).to eq('Аккаунт Алатау 2')
      expect(account.limits).to include('agents' => 12, 'storage_bytes' => 1.5.gigabytes.to_i, 'emails' => max)
    end
  end

  describe 'saving' do
    before { apply_plan! }

    it '«Своё число» writes the number and lists the limit as chosen' do
      save_from_card(choices(agents: %w[custom 8]))

      expect(response).to redirect_to(card_path)
      account.reload
      expect(account.limits).to include('agents' => 8)
      expect(account.custom_attributes[marks_key]).to eq('agents' => 8)
    end

    it '«Без ограничений» writes the number that stands for no limit of that limit' do
      save_from_card(choices(agents: 'unlimited', storage_bytes: 'unlimited', captain_tokens: 'unlimited'))

      account.reload
      expect(account.limits).to include('agents' => max, 'storage_bytes' => max * 1.gigabyte, 'captain_tokens' => max * 1_000_000)
      expect(account.custom_attributes[marks_key]).to eq('agents' => 'unlimited', 'storage_bytes' => 'unlimited', 'captain_tokens' => 'unlimited')
    end

    it '«Как в тарифе» takes the number of the limit back to the plan, and off the list' do
      account.update!(limits: account.limits.merge('inboxes' => 7),
                      custom_attributes: account.custom_attributes.merge(marks_key => { 'inboxes' => 7 }))

      save_from_card(choices(inboxes: 'plan', conversations: 'plan'))

      account.reload
      expect(account.limits).not_to have_key('inboxes')
      expect(account.limits).to include('conversations' => max)
      expect(Accounts::LimitSettings.marks_in(account.custom_attributes)).to eq({})
    end

    it 'turns gigabytes into bytes, with a comma or a dot' do
      save_from_card(choices(storage_bytes: ['custom', '1,5']))
      expect(account.reload.limits['storage_bytes']).to eq(1.5.gigabytes.to_i)

      save_from_card(choices(storage_bytes: %w[custom 50]))
      expect(account.reload.limits['storage_bytes']).to eq(50.gigabytes)
      expect(account.custom_attributes[marks_key]).to eq('storage_bytes' => 50.gigabytes)

      save_from_card(choices(storage_bytes: ['custom', '0.25']))
      expect(account.reload.limits['storage_bytes']).to eq(0.25.gigabytes.to_i)
    end

    it 'takes a number as big as the no-limit one for «без ограничений»' do
      save_from_card(choices(agents: ['custom', max.to_s]))

      expect(account.reload.limits['agents']).to eq(max)
      expect(account.custom_attributes[marks_key]).to eq('agents' => 'unlimited')
    end

    it 'allows 0: the action is forbidden' do
      save_from_card(choices(inboxes: %w[custom 0]))

      expect(account.reload.limits['inboxes']).to eq(0)
      expect(account.custom_attributes[marks_key]).to eq('inboxes' => 0)
    end

    it 'does not read the field of the number unless «Своё число» is chosen' do
      save_from_card(choices(agents: %w[plan 99]))

      expect(account.reload.limits).not_to have_key('agents')
    end

    it 'leaves the name, the language and the functions alone when the card form is saved' do
      account.update!(name: 'Другое имя')
      sla = account.feature_enabled?('sla')

      save_from_card(choices(agents: %w[custom 3]))

      expect(account.reload.name).to eq('Другое имя')
      expect(account.feature_enabled?('sla')).to eq(sla)
    end

    it 'writes one entry in the audit log, in words, from → to' do
      account.update!(limits: account.limits.merge('inboxes' => 4),
                      custom_attributes: account.custom_attributes.merge(marks_key => { 'inboxes' => 4 }))

      expect { save_from_card(choices(agents: %w[custom 8], inboxes: 'plan', storage_bytes: 'unlimited', conversations: 'plan')) }
        .to change { Audited::Audit.where(action: 'update_limits').count }.by(1)

      audit = Audited::Audit.where(action: 'update_limits').last
      expect(audit).to have_attributes(auditable_id: account.id, auditable_type: 'Account', user_id: super_admin.id)
      expect(audit.audited_changes['limits'].keys).to eq(%w[agents inboxes storage_bytes])
      expect(audit.audited_changes['limits']['agents']).to eq('label' => 'Операторы', 'from' => 'как в тарифе (без ограничений)',
                                                              'to' => 'своё число (8 операторов)')
      expect(audit.audited_changes['limits']['inboxes']).to eq('label' => 'Каналы', 'from' => 'своё число (4 канала)',
                                                               'to' => 'как в тарифе (без ограничений)')
      expect(audit.audited_changes['limits']['storage_bytes']).to include('to' => 'без ограничений')
    end

    it 'says what was saved, and writes no entry when nothing changed' do
      save_from_card(choices(agents: %w[custom 8]))
      follow_redirect!
      expect(text(page.at_css('.flashes'))).to include('Лимиты сохранены: изменён 1 лимит.')

      expect { save_from_card(choices(agents: %w[custom 8])) }.not_to(change { Audited::Audit.where(action: 'update_limits').count })
    end

    it 'shows the entry in the audit log in Russian' do
      save_from_card(choices(agents: %w[custom 8]))

      get '/super_admin/audits'

      expect(response.body).to include('Изменение лимитов аккаунта')
    end

    it 'still takes the numbers an older form posted (a blank one follows the plan)' do
      account.update!(limits: account.limits.merge('emails' => 9, 'inboxes' => 4))

      patch card_path, params: { account: { limits: { agents: '12', storage_bytes: '1.5', emails: '', conversations: '0' } } }

      account.reload
      expect(account.limits).to include('agents' => 12, 'storage_bytes' => 1.5.gigabytes.to_i, 'conversations' => 0)
      expect(account.limits).not_to include('emails', 'inboxes')
      expect(account.custom_attributes[marks_key]).to eq('agents' => 12, 'storage_bytes' => 1.5.gigabytes.to_i, 'conversations' => 0)
    end

    it 'leaves the limits alone for a request that says nothing about them' do
      account.update!(limits: account.limits.merge('agents' => 5))

      patch card_path, params: { account: { name: 'Новое имя' } }

      expect(account.reload.limits).to include('agents' => 5)
    end
  end

  describe 'a mistake in the form' do
    before { apply_plan! }

    it 'sends the card back with nothing saved when «Своё число» has no number', :aggregate_failures do
      account.update!(limits: account.limits.merge('agents' => 3), custom_attributes: account.custom_attributes.merge(marks_key => { 'agents' => 3 }))

      save_from_card(choices(agents: ['custom', ''], inboxes: %w[custom 5]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(text(page.at_css('.flashes'))).to include('Лимит «Операторы»: выбрано «Своё число», но число не указано.')
      expect(account.reload.limits).to include('agents' => 3)
      expect(account.limits).not_to have_key('inboxes')
      # what was typed is still there, and the row with the mistake is marked
      expect(choice_of('inboxes')).to eq('custom')
      expect(row('inboxes').at_css('input[type=number]')['value']).to eq('5')
      expect(choice_of('agents')).to eq('custom')
      expect(row('agents').has_attribute?('data-problem')).to be(true)
      expect(row('inboxes').has_attribute?('data-problem')).to be(false)
    end

    it 'refuses something that is not a number, a fraction of a count and a negative number' do
      save_from_card(choices(agents: %w[custom много]))
      expect(response).to have_http_status(:unprocessable_content)
      expect(text(page.at_css('.flashes'))).to include('Лимит «Операторы»: введите целое число не меньше 0, например 5.')

      save_from_card(choices(agents: ['custom', '2.5']))
      expect(response).to have_http_status(:unprocessable_content)

      save_from_card(choices(agents: ['custom', '-1']))
      expect(response).to have_http_status(:unprocessable_content)

      expect(account.reload.limits).not_to have_key('agents')
    end

    it 'asks for gigabytes in the storage' do
      save_from_card(choices(storage_bytes: %w[custom мало]))

      expect(text(page.at_css('.flashes'))).to include('Лимит «Хранилище»: введите число гигабайт не меньше 0, например 50 или 1,5.')
    end

    it 'refuses a choice that is none of the three' do
      save_from_card(limit_choices: { agents: 'forever' })

      expect(response).to have_http_status(:unprocessable_content)
      expect(text(page.at_css('.flashes'))).to include('Лимит «Операторы»: выберите один из трёх вариантов.')
    end

    it 'sends the edit form back with the choices typed when the request came from it' do
      patch card_path, params: { account: { name: 'Новое имя' }.merge(choices(agents: ['custom', ''])) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload.name).to eq('Аккаунт Алатау')
      expect(page.css('fieldset.form-section > legend').map { |legend| text(legend) }).to include('Лимиты')
      expect(choice_of('agents')).to eq('custom')
    end

    it 'does not take an array or a hash for a number' do
      save_from_card(limit_choices: { agents: 'custom' }, limit_values: { agents: ['5'] })

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'a form drawn before somebody changed the limits' do
    before { apply_plan! }

    it 'does not save the limits over the change, and says so' do
      get card_path
      tokens = %w[main limits features].index_with { |section| page.at_css("input[name='form_state[#{section}]']")['value'] }
      account.update!(limits: account.limits.merge('agents' => 50),
                      custom_attributes: account.custom_attributes.merge(marks_key => { 'agents' => 50 }))

      patch card_path, params: { account: choices(agents: %w[custom 3]), form_state: tokens, return_to: 'card' }

      expect(response).to redirect_to(card_path)
      expect(account.reload.limits['agents']).to eq(50)
      follow_redirect!
      expect(text(page.at_css('.flashes'))).to include('лимиты')
    end

    it 'notices a change of the choice alone (the list), not only of the numbers' do
      get card_path
      tokens = %w[main limits features].index_with { |section| page.at_css("input[name='form_state[#{section}]']")['value'] }
      account.update!(custom_attributes: account.custom_attributes.merge(marks_key => { 'agents' => 0 }))

      expect(SuperAdmin::AccountFormState.stale_sections(account.reload, tokens)).to eq(['limits'])
    end
  end

  # The browser sends every row, the ones nobody touched included. Saving the name, or one row, must leave every other limit as it is:
  # a zero an ended trial put on a limit, a number the plan has changed since, a number a partner wrote, a size of odd bytes.
  describe 'a form saved as the browser draws it' do
    before { apply_plan! }

    context 'when an ended trial holds the operator and channel limits at 0' do
      before do
        account.update!(limits: account.limits.merge('agents' => 5, 'inboxes' => 3))
        account.reload.activate_trial!(3)
        account.expire_trial!
      end

      it 'keeps the zeros when only the name is saved on the edit form, and writes no entry about the limits' do
        expect(account.reload.limits).to include('agents' => 0, 'inboxes' => 0)

        save_edit_form_as_drawn('account[name]' => 'Аккаунт переименован')

        expect(response).to redirect_to(card_path)
        expect(account.reload.name).to eq('Аккаунт переименован')
        expect(account.limits).to include('agents' => 0, 'inboxes' => 0)
        expect(account.trial_held_limits.keys).to contain_exactly('agents', 'inboxes')
        expect(limit_audits).to be_empty
        follow_redirect!
        expect(text(page.at_css('.flashes'))).not_to include('Лимиты сохранены')
      end

      it 'changes only the row that was changed on the card, and says so' do
        save_card_as_drawn('account[limit_choices][emails]' => 'custom', 'account[limit_values][emails]' => '50')

        expect(account.reload.limits).to include('agents' => 0, 'inboxes' => 0, 'emails' => 50)
        expect(limit_audits.last.audited_changes['limits'].keys).to eq(['emails'])
        follow_redirect!
        expect(text(page.at_css('.flashes'))).to include('Лимиты сохранены: изменён 1 лимит.')
      end

      it 'gives a zero back when its row is set to another choice' do
        save_card_as_drawn('account[limit_choices][agents]' => 'custom', 'account[limit_values][agents]' => '4')

        expect(account.reload.limits).to include('agents' => 4, 'inboxes' => 0)
        expect(limit_audits.last.audited_changes['limits'].keys).to eq(['agents'])
      end
    end

    context 'when the plan has changed a number since it was applied' do
      before do
        allow(Accounts::Plans).to(receive(:limits_for).and_wrap_original { |original, *args| original.call(*args).merge('conversations' => 1000) })
      end

      it 'keeps the old number when only the name is saved, and still says that the plan will change it' do
        save_edit_form_as_drawn('account[name]' => 'Аккаунт переименован')

        expect(account.reload.limits['conversations']).to eq(max)
        expect(limit_audits).to be_empty
        get card_path
        expect(choice_of('conversations')).to eq('plan')
        expect(row('conversations').at_css('[data-testid="limit-drift"]')).to be_present
      end

      it 'keeps it when another row is saved on the card' do
        save_card_as_drawn('account[limit_choices][agents]' => 'custom', 'account[limit_values][agents]' => '9')

        expect(account.reload.limits).to include('conversations' => max, 'agents' => 9)
      end

      it 'takes the new number of the plan only when the plan is applied' do
        Accounts::ApplyPlan.new(account: account.reload, modules: []).call

        expect(account.reload.limits['conversations']).to eq(1000)
      end
    end

    context 'when a partner wrote a number through the Platform API' do
      before { account.update!(limits: account.limits.merge('conversations' => 1000)) }

      it 'shows it as «Своё число» and keeps it when only the name is saved' do
        get card_path
        expect(choice_of('conversations')).to eq('custom')
        expect(row('conversations').at_css('input[type=number]')['value']).to eq('1000')

        save_edit_form_as_drawn('account[name]' => 'Аккаунт переименован')

        expect(account.reload.limits['conversations']).to eq(1000)
        expect(limit_audits).to be_empty
      end

      it 'keeps it when a plan is applied' do
        Accounts::ApplyPlan.new(account: account.reload, modules: []).call

        expect(account.reload.limits['conversations']).to eq(1000)
      end
    end

    context 'when the size of the storage is not a round number of gigabytes' do
      before { account.update!(limits: account.limits.merge('storage_bytes' => 5_000_000_000)) }

      it 'keeps the exact bytes when only the name is saved, on the card and on the edit form' do
        save_edit_form_as_drawn('account[name]' => 'Аккаунт переименован')
        expect(account.reload.limits['storage_bytes']).to eq(5_000_000_000)

        save_card_as_drawn('account[limit_choices][emails]' => 'unlimited')
        expect(account.reload.limits).to include('storage_bytes' => 5_000_000_000, 'emails' => max)
        expect(limit_audits.map { |audit| audit.audited_changes['limits'].keys }).to eq([['emails']])
      end

      it 'changes it when a different size is typed' do
        save_card_as_drawn('account[limit_choices][storage_bytes]' => 'custom', 'account[limit_values][storage_bytes]' => '4,7')

        expect(account.reload.limits['storage_bytes']).to eq((BigDecimal('4.7') * 1.gigabyte).round(0).to_i)
        expect(limit_audits.last.audited_changes['limits']['storage_bytes'])
          .to include('from' => 'своё число (4,66 ГБ)', 'to' => 'своё число (4,7 ГБ)')
      end
    end

    context 'when the account is from before the choices (no list of any kind), with numbers of its own' do
      before do
        account.update!(custom_attributes: account.custom_attributes.except(*Accounts::LimitSettings::ATTRIBUTE_KEYS),
                        limits: { 'agents' => 7, 'inboxes' => 3, 'conversations' => 500, 'storage_bytes' => 10.gigabytes, 'emails' => 200 })
      end

      it 'changes nothing about the limits, and writes no list, when only the name is saved' do
        stored = account.reload.limits.dup

        save_edit_form_as_drawn('account[name]' => 'Аккаунт переименован')

        expect(response).to redirect_to(card_path)
        expect(account.reload.name).to eq('Аккаунт переименован')
        expect(account.limits).to eq(stored)
        expect(account.custom_attributes).not_to include(*Accounts::LimitSettings::ATTRIBUTE_KEYS)
        expect(limit_audits).to be_empty
      end
    end

    it 'saves the whole form of an account that follows the plan without a single change of the limits' do
      stored = account.reload.attributes.slice('limits', 'custom_attributes')

      save_card_as_drawn

      expect(response).to redirect_to(card_path)
      expect(account.reload.attributes.slice('limits', 'custom_attributes')).to eq(stored)
      expect(limit_audits).to be_empty
    end
  end

  describe 'the list of accounts' do
    it 'exports the storage limit of an account without the number that stands for no limit' do
      apply_plan!
      account.update!(limits: account.limits.merge('storage_bytes' => max * 1.gigabyte))

      get '/super_admin/accounts/export'

      expect(response.body).not_to include((max * 1.gigabyte).to_s)
      expect(response.body).not_to include('107374182400')
    end
  end
end
