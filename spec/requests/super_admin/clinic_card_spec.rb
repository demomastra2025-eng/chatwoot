require 'rails_helper'

RSpec.describe 'Super Admin clinic card', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account, name: 'Клиника Алатау') }
  let(:card_path) { "/super_admin/accounts/#{account.id}" }

  before { sign_in(super_admin, scope: :super_admin) }

  # Parsed again for every call, so a spec can open the card twice
  def page
    Nokogiri::HTML(response.body)
  end

  def text(node)
    node.text.squish
  end

  def block(testid)
    page.at_css("[data-testid='#{testid}']")
  end

  def open_card
    get card_path
    expect(response).to have_http_status(:ok)
  end

  describe 'the whole page' do
    it 'has no missing translations, no emoji and no prices' do
      open_card

      expect(response.body).not_to include('translation missing')
      expect(response.body).not_to match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/)
      expect(response.body).not_to match(/₸|тенге|KZT|\bруб\b/i)
    end

    it 'titles the page with the name of the clinic' do
      open_card

      expect(page.at_css('title').text).to include('Клиника Алатау')
    end

    it 'lays the blocks out as a main column and a side column' do
      open_card

      layout = page.at_css('.admin-card-layout')
      main, side = layout.element_children
      expect(main.css('[data-testid]').map { |node| node['data-testid'] }).to include(
        'plan-block', 'usage-block', 'channels-block', 'fine-tuning-block', 'users-block', 'technical-block'
      )
      expect(side.css('[data-testid]').map { |node| node['data-testid'] }).to eq(%w[trial-block info-block maintenance-block])
    end
  end

  describe 'the header' do
    it 'shows the name, the status, #id and the creation date in Astana time' do
      account.update_columns(created_at: Time.utc(2026, 10, 15, 20, 0)) # rubocop:disable Rails/SkipsModelValidations

      open_card

      expect(text(page.at_css('h1'))).to eq('Клиника Алатау')
      expect(text(block('account-status'))).to eq('Активна')
      expect(text(block('account-meta'))).to eq("##{account.id} · создана 16.10.2026")
    end

    it 'shows the status of a suspended clinic and of one that is being deleted' do
      account.update!(status: :suspended)
      open_card
      expect(text(block('account-status'))).to eq('Заблокирована')

      account.update!(custom_attributes: account.custom_attributes.merge('marked_for_deletion_at' => 3.days.from_now.iso8601))
      open_card
      expect(text(block('account-status'))).to eq('На удаление')
    end

    it 'links back to the list' do
      open_card

      expect(page.at_css('nav a[href="/super_admin/accounts"]')).to be_present
    end

    it 'offers «Редактировать» and, when the clinic has a user, «Войти в аккаунт» (a POST, so no token is minted by looking)' do
      create(:user, account: account, role: :administrator)

      open_card

      expect(text(page.at_css("a[href='#{card_path}/edit']"))).to eq('Редактировать')
      enter = page.at_css("form[action='#{card_path}/impersonate']")
      expect(enter['method']).to eq('post')
      expect(text(enter)).to eq('Войти в аккаунт')
      expect(response.body).not_to include('sso_auth_token')
    end

    it 'has no sign-in button for a clinic without users' do
      open_card

      expect(page.at_css("form[action='#{card_path}/impersonate']")).to be_nil
    end
  end

  describe 'the plan block' do
    def modules_form
      block('plan-block').at_css('form[data-plan-form]')
    end

    def module_inputs
      modules_form.css('input[name="modules[]"]')
    end

    context 'when the clinic has no plan' do
      before { open_card }

      it 'says «Тариф не назначен» and offers «Назначить базу»' do
        expect(text(block('plan-label'))).to eq('Не назначен')
        expect(text(block('plan-unassigned'))).to include('Тариф не назначен')
        expect(text(modules_form.at_css('button[data-plan-submit]'))).to eq('Назначить базу')
        expect(modules_form['data-assigned']).to eq('false')
      end

      it 'shows the base as a card that is always included and four module switches' do
        base = block('plan-block').at_css('[data-plan-card="base"]')
        expect(text(base)).to include('База', 'Всегда включена')
        expect(base.at_css('input')).to be_nil

        expect(module_inputs.map { |input| input['value'] }).to eq(%w[ai_agents broadcasts quality extensions])
        expect(module_inputs.map { |input| input['checked'] }).to all(be_nil)
        expect(module_inputs.map { |input| input['type'] }.uniq).to eq(['checkbox'])
      end

      it 'names every module and what it includes in Russian' do
        cards = block('plan-block').css('[data-plan-card]').map { |card| text(card) }.join(' ')

        expect(cards).to include('ИИ-агенты', 'Рассылки', 'Контроль качества', 'Расширения')
        expect(cards).to include('Входит: ИИ-агенты')
        expect(cards).to include('SLA')
      end

      it 'does not show a drift notice' do
        expect(block('plan-drift')).to be_nil
      end
    end

    context 'when the clinic has the base and a module' do
      before do
        Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents]).call
        open_card
      end

      it 'shows the plan, the chosen module and the apply button' do
        expect(text(block('plan-label'))).to eq('База + ИИ-агенты')
        expect(block('plan-unassigned')).to be_nil
        expect(text(modules_form.at_css('button[data-plan-submit]'))).to eq('Применить')
        expect(module_inputs.select { |input| input['checked'] }.map { |input| input['value'] }).to eq(%w[ai_agents])
      end

      it 'posts the modules to apply_plan and knows where to ask for the preview' do
        expect(modules_form['action']).to eq("#{card_path}/apply_plan")
        expect(modules_form['method']).to eq('post')
        expect(modules_form['data-assigned']).to eq('true')
        expect(JSON.parse(modules_form['data-initial-modules'])).to eq(%w[ai_agents])
        expect(modules_form['data-preview-url']).to eq("#{card_path}/plan_preview")
        expect(block('plan-block').at_css('[data-plan-preview]')).to be_present
      end

      it 'has no drift notice right after the plan was applied' do
        expect(block('plan-drift')).to be_nil
      end
    end

    context 'when the clinic was changed by hand' do
      before do
        Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents]).call
        account.enable_features!('sla')
        account.disable_features!('crm')
        open_card
      end

      it 'says how far it moved from the plan and what changed' do
        notice = text(block('plan-drift'))

        expect(notice).to include(I18n.t('super_admin.plans.drift.summary', extra: 1, missing: 1, plan: 'База + ИИ-агенты'))
        expect(notice).to include('Включены сверх тарифа: SLA.')
        expect(notice).to include('Выключены, хотя тариф их включает: CRM.')
      end

      it 'resets to the plan with a button that applies the same modules again' do
        form = block('plan-drift').at_css('form')

        expect(form['action']).to eq("#{card_path}/apply_plan")
        expect(text(form)).to eq('Сбросить к тарифу')
        expect(form.css('input[name="modules[]"]').map { |input| input['value'] }).to eq(%w[ai_agents])

        post "#{card_path}/apply_plan", params: { modules: %w[ai_agents] }

        expect(account.reload.feature_enabled?('sla')).to be(false)
        expect(account.feature_enabled?('crm')).to be(true)
        get card_path
        expect(Nokogiri::HTML(response.body).at_css("[data-testid='plan-drift']")).to be_nil
      end
    end

    context 'when the clinic is on a trial and was changed by hand' do
      let(:trial_flags) { Accounts::Plans.module_features('ai_agents') }

      before do
        Accounts::ApplyPlan.new(account: account, modules: []).call
        account.activate_trial!(3)
        account.enable_features!('sla')
      end

      it 'counts only the change made by hand, not the functions of the trial' do
        open_card

        expect(text(block('plan-drift'))).to include(I18n.t('super_admin.plans.drift.summary', extra: 1, missing: 0, plan: 'База'))
        expect(text(block('plan-drift'))).to include('Включены сверх тарифа: SLA.')
      end

      it 'resets to the plan without switching off the functions the trial granted, and the notice goes away' do
        post "#{card_path}/apply_plan", params: { modules: [] }

        account.reload
        expect(account.trial_active?).to be(true)
        expect(account.feature_enabled?('sla')).to be(false)
        trial_flags.each { |flag| expect(account.feature_enabled?(flag)).to be(true) }
        get card_path
        expect(Nokogiri::HTML(response.body).at_css("[data-testid='plan-drift']")).to be_nil
      end

      it 'does not list the functions of the trial in the preview of the reset' do
        get "#{card_path}/plan_preview", params: { fragment: 1, modules: [] }

        disable = text(Nokogiri::HTML.fragment(response.body).at_css('[data-preview="disable"]'))
        expect(disable).to include('Выключится: 1', 'SLA')
        expect(disable).not_to include('ИИ-агенты')
      end
    end

    context 'when a module is applied from the card while the trial runs' do
      before do
        Accounts::ApplyPlan.new(account: account, modules: []).call
        account.activate_trial!(3)
        post "#{card_path}/apply_plan", params: { modules: %w[ai_agents] }
      end

      it 'stays switched on when the trial ends, and the clinic is not shown as changed by hand' do
        expect(account.reload.expire_trial!).to be(true)

        account.reload
        Accounts::Plans.module_features('ai_agents').each { |flag| expect(account.feature_enabled?(flag)).to be(true) }
        open_card
        expect(block('plan-label').text.squish).to eq('База + ИИ-агенты')
        expect(block('plan-drift')).to be_nil
      end

      it 'is not switched off when the trial is ended with the button of the card either' do
        post "#{card_path}/expire_trial"

        expect(account.reload.feature_enabled?('captain_integration')).to be(true)
      end
    end
  end

  describe 'the plan preview fragment' do
    def preview(modules, target = account)
      get "/super_admin/accounts/#{target.id}/plan_preview", params: { fragment: 1, modules: modules }
    end

    it 'is an HTML fragment, not a page' do
      preview(%w[ai_agents])

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      expect(response.body).not_to include('<html')
      expect(Nokogiri::HTML.fragment(response.body).at_css('[data-testid="plan-preview"]')['data-changed']).to eq('true')
    end

    it 'says what would change, in Russian' do
      account.enable_features!('scheduling_finance')

      preview(%w[ai_agents])

      fragment = Nokogiri::HTML.fragment(response.body)
      expect(text(fragment.at_css('span.font-medium'))).to eq('Клинике будет назначен тариф «База + ИИ-агенты». Что изменится:')
      expect(text(fragment.at_css('[data-preview="enable"]'))).to include('Включится:', 'ИИ-агенты', 'CRM')
      expect(text(fragment.at_css('[data-preview="disable"]'))).to include('Выключится: 1', 'Финансы записи')
      expect(text(fragment.at_css('[data-preview="limits"]'))).to include('Диалоги за 30 дней', 'Не ограничено')
    end

    it 'writes nothing' do
      expect { preview(%w[ai_agents]) }.not_to change(Audited::Audit, :count)
      expect(account.reload.custom_attributes).not_to have_key('plan')
    end

    it 'shows the change of a clinic that already has a plan' do
      Accounts::ApplyPlan.new(account: account, modules: []).call

      preview(%w[quality])

      expect(text(Nokogiri::HTML.fragment(response.body))).to include('Тариф «База» сменится на «База + Контроль качества»')
    end

    it 'tells when nothing but the record of the plan would change' do
      Accounts::ApplyPlan.new(account: account, modules: []).call

      preview([])

      fragment = Nokogiri::HTML.fragment(response.body)
      expect(fragment.at_css('[data-testid="plan-preview"]')['data-changed']).to eq('false')
      expect(text(fragment)).to include('Тариф «База» будет применён заново', 'уже совпадают с тарифом')
    end

    it 'warns that the clinic is on a trial, and that its end will block operators and channels' do
      account.activate_trial!(3)

      preview(%w[quality])

      fragment = Nokogiri::HTML.fragment(response.body)
      active_note = text(fragment.at_css('[data-preview-note="trial_active"]'))
      expect(active_note).to include('отключатся функции, которые дал пробный период и которых нет в тарифе')
      expect(text(fragment.at_css('[data-preview-note="trial_locks_limits"]'))).to include('лимиты операторов и каналов станут нулевыми')
    end

    it 'does not warn about the limits when the trial was started by a super admin and keeps them' do
      account.activate_trial!(3, keep_limits: true)

      preview(%w[quality])

      fragment = Nokogiri::HTML.fragment(response.body)
      expect(fragment.at_css('[data-preview-note="trial_active"]')).to be_present
      expect(fragment.at_css('[data-preview-note="trial_locks_limits"]')).to be_nil
    end

    it 'still answers JSON when no fragment is asked for' do
      get "#{card_path}/plan_preview", params: { modules: %w[quality] }

      expect(response.media_type).to eq('application/json')
      expect(response.parsed_body).to include('plan' => 'base', 'modules' => %w[quality])
    end

    it 'refuses an unknown module' do
      preview(%w[ghost])

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'the trial block' do
    it 'offers to start a trial for a clinic that never had one' do
      open_card

      expect(text(block('trial-block'))).to include('Пробный период', 'Не запускался')
      form = block('trial-block').at_css("form[action='#{card_path}/extend_trial']")
      expect(text(form)).to eq('Запустить на 3 дн.')
      expect(form.at_css('input[name="start"]')['value']).to eq('true')
    end

    it 'shows what is left of a running trial, the end in Astana time, and offers to extend or end it' do
      account.activate_trial!(3)

      open_card

      trial = block('trial-block')
      expect(trial['data-trial-state']).to eq('active')
      expect(text(trial)).to include('Идёт', 'Осталось:')
      expect(text(trial)).to include("До: #{SuperAdmin::DisplayHelper.format_time(account.reload.trial_expires_at)}")
      expect(text(trial.at_css("form[action='#{card_path}/extend_trial']"))).to eq('Продлить на 3 дн.')
      expect(text(trial.at_css("form[action='#{card_path}/expire_trial']"))).to eq('Завершить сейчас')
    end

    it 'shows when a trial ended and still offers to reopen it' do
      account.activate_trial!(3)
      account.expire_trial!

      open_card

      trial = block('trial-block')
      expect(trial['data-trial-state']).to eq('expired')
      expect(text(trial)).to include('Закончился', 'Пробный период завершён')
      expect(trial.at_css("form[action='#{card_path}/extend_trial']")).to be_present
    end

    it 'does not offer to end a trial that has already ended (it would always fail)' do
      account.activate_trial!(3)
      account.expire_trial!

      open_card

      expect(block('trial-block').at_css("form[action='#{card_path}/expire_trial']")).to be_nil
    end

    it 'does not offer to end or extend a trial typed in by hand, and says why' do
      account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.from_now.iso8601 })

      open_card

      trial = block('trial-block')
      expect(text(trial)).to include('задан вручную')
      expect(trial.at_css("form[action='#{card_path}/expire_trial']")).to be_nil
      expect(text(trial.at_css("form[action='#{card_path}/extend_trial']"))).to eq('Запустить на 3 дн.')
    end

    it 'tells what starting a trial does to a trial typed in by hand: the present functions stay after it ends' do
      account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.from_now.iso8601 })

      open_card

      expect(text(block('trial-block'))).to include('запомнит нынешние функции клиники как её собственные', 'останутся включёнными')
    end

    it 'says that a clinic without a plan loses its operator and channel limits when the trial ends' do
      open_card

      trial = block('trial-block')
      expect(text(trial)).to include('Лимиты операторов и каналов при этом станут нулевыми')
      expect(trial.at_css('form[action$="/extend_trial"] button')['data-confirm']).to include('лимиты операторов и каналов станут нулевыми')
    end

    it 'says that a clinic with a plan keeps its limits when the trial ends' do
      Accounts::ApplyPlan.new(account: account, modules: []).call

      open_card

      trial = block('trial-block')
      expect(text(trial)).to include('Лимиты клиники при этом не меняются')
      expect(trial.at_css('form[action$="/extend_trial"] button')['data-confirm']).to include('лимиты клиники не изменятся')
    end

    it 'asks before ending a running trial and says what happens to the limits of a clinic with a plan and a trial a super admin started' do
      Accounts::ApplyPlan.new(account: account, modules: []).call
      account.activate_trial!(3, keep_limits: true)

      open_card

      confirm = block('trial-block').at_css("form[action='#{card_path}/expire_trial'] button")['data-confirm']
      expect(confirm).to include('остальные функции и лимиты клиники не изменятся')
      expect(confirm).not_to include('станут нулевыми')
      expect(text(block('trial-block').at_css('[data-testid="trial-end-note"]'))).to include('Лимиты клиники при этом не меняются')
    end

    it 'says that the end of a trial nobody chose for the clinic (self-registration) blocks operators and channels, plan or not' do
      Accounts::ApplyPlan.new(account: account, modules: []).call
      account.activate_trial!(3)

      open_card

      confirm = block('trial-block').at_css("form[action='#{card_path}/expire_trial'] button")['data-confirm']
      expect(confirm).to include('лимиты операторов и каналов станут нулевыми')
      expect(text(block('trial-block').at_css('[data-testid="trial-end-note"]'))).to include('Лимиты операторов и каналов при этом станут нулевыми')
    end
  end

  describe 'the limits and spend block' do
    let(:limits) do
      { 'agents' => 10, 'inboxes' => 20, 'conversations' => 1000, 'non_web_inboxes' => 5, 'storage_bytes' => 50.gigabytes,
        'captain_responses' => 100, 'captain_documents' => 10, 'captain_tokens' => 1000, 'emails' => 50 }
    end

    it 'lists every limit with a Russian name, in order' do
      account.update!(limits: limits)

      open_card

      keys = block('usage-block').css('[data-usage]').map { |row| row['data-usage'] }
      expect(keys).to eq(%w[agents inboxes conversations non_web_inboxes storage captain_responses captain_documents captain_tokens emails])
      labels = block('usage-block').css('[data-usage]').map { |row| text(row.at_css('span')) }
      expect(labels).to eq(
        ['Операторы', 'Каналы', 'Диалоги за 30 дней', 'Основные каналы', 'Хранилище', 'Ответы ИИ', 'Документы ИИ', 'Токены ИИ', 'Письма в день']
      )
    end

    it 'shows used and limit with sizes in ГБ and a meter for each' do
      account.update!(limits: limits)
      create_list(:user, 2, account: account)

      open_card

      expect(text(block('usage-block').at_css('[data-usage="agents"]'))).to include('2 из 10')
      expect(text(block('usage-block').at_css('[data-usage="storage"]'))).to include('0 Б из 50 ГБ')
      expect(block('usage-block').css('[data-usage] .admin-meter').size).to eq(9)
    end

    it 'says «Не ограничено» instead of Unlimited when a limit is not set' do
      account.update!(limits: {})
      GlobalConfig.clear_cache

      open_card

      expect(block('usage-block').text).to include('Не ограничено')
      expect(response.body).not_to include('Unlimited')
    end

    it 'gives every limit a hint' do
      open_card

      hints = block('usage-block').css('[data-usage] .text-xs').map { |hint| text(hint) }
      expect(hints.size).to eq(9)
      expect(hints).to all(match(/\p{Cyrillic}/))
    end

    it 'has no English labels of the old page' do
      open_card

      expect(block('usage-block').text).not_to match(/Captain|Users|Channels|Conversations|Outbound|Tokens/)
    end

    it 'does not break on a storage snapshot that has no breakdown' do
      key = "account:#{account.id}:storage_overview_v1"
      Redis::Alfred.set(key, JSON.generate(limits: { total_count: 100, consumed: 10, current_available: 90, unlimited: false }))

      begin
        open_card
      ensure
        Redis::Alfred.delete(key)
      end

      expect(block('usage-block').at_css('[data-testid="storage-breakdown"]')).to be_present
      expect(text(block('usage-block'))).to include('Объём хранилища рассчитывается')
    end

    it 'shows «Не ограничено» for the no-limit value a plan writes (the maximum limit)' do
      account.update!(limits: { 'conversations' => ChatwootApp.max_limit })

      open_card

      row = block('usage-block').at_css('[data-usage="conversations"]')
      expect(text(row)).to include('Не ограничено')
      expect(row.at_css('.admin-meter')).to be_nil
    end

    it 'shows where the storage goes and the buttons that reset the counters' do
      open_card

      expect(block('usage-block').at_css('[data-testid="storage-breakdown"]')).to be_present
      resets = block('usage-block').css('[data-testid="counter-resets"] form').to_h { |form| [form['action'], text(form)] }
      expect(resets).to eq(
        "#{card_path}/reset_captain_responses_usage" => 'Сбросить ответы ИИ',
        "#{card_path}/reset_captain_tokens_usage" => 'Сбросить токены ИИ',
        "#{card_path}/reset_email_usage" => 'Сбросить счётчик писем'
      )
    end
  end

  describe 'the channels block' do
    it 'keeps the per-clinic switches of the channels' do
      open_card

      channels = block('channels-block')
      expect(channels.at_css("form[action='#{card_path}/channel_overrides']")).to be_present
      expect(channels.css('tbody tr').size).to eq(Channels::Catalog.entries.size)
      expect(channels.css('select').map { |select| select['name'] }).to include('overrides[website]', 'overrides[api]')
      expect(channels.css('.admin-badge').size).to eq(Channels::Catalog.entries.size)
    end
  end

  describe 'the «Тонкая настройка» block' do
    before { Accounts::ApplyPlan.new(account: account, modules: []).call }

    def fine_tuning
      page.at_css('details#fine-tuning')
    end

    def switch_names
      fine_tuning.css('input[type="checkbox"]').map { |input| input['name'] }
    end

    it 'is collapsed' do
      open_card

      expect(fine_tuning).to be_present
      expect(fine_tuning['open']).to be_nil
      expect(text(fine_tuning.at_css('summary'))).to include('Тонкая настройка')
    end

    it 'has a switch for every function a plan can switch, and none for the dangerous or internal ones' do
      open_card

      expected = SuperAdmin::FineTuning.new(account).flag_names.map { |name| "enabled_features[feature_#{name}]" }
      expect(switch_names).to match_array(expected)
      expect(switch_names).not_to include(
        'enabled_features[feature_agent_management]', 'enabled_features[feature_team_management]', 'enabled_features[feature_custom_roles]',
        'enabled_features[feature_saml]', 'enabled_features[feature_scheduling_finance]', 'enabled_features[feature_chatwoot_v4]'
      )
    end

    it 'groups the switches and names them in Russian' do
      open_card

      headings = fine_tuning.css('h3').map { |heading| text(heading) }
      expect(headings).to include('Каналы и почта', 'Телефония', 'CRM и запись', 'ИИ-агенты', 'Рассылки')
      expect(text(fine_tuning)).to include('Телефония', 'Звонки WhatsApp', 'Журнал аудита', 'Запись на приём')
    end

    it 'shows the state of each function and marks the ones changed by hand' do
      account.enable_features!('sla')

      open_card

      expect(fine_tuning.at_css('input#feature-sla')['checked']).to be_present
      expect(fine_tuning.at_css('input#feature-crm')['checked']).to be_present
      expect(fine_tuning.at_css('input#feature-campaigns')['checked']).to be_nil
      expect(text(fine_tuning.at_css('[data-flag="sla"] [data-manual]'))).to eq('вручную')
      expect(fine_tuning.at_css('[data-flag="crm"] [data-manual]')).to be_nil
    end

    it 'sends an unchecked switch too (a hidden «false» before the checkbox)' do
      open_card

      hidden = fine_tuning.at_css('input[type="hidden"][name="enabled_features[feature_sla]"]')
      expect(hidden['value']).to eq('false')
      expect(fine_tuning.at_css('input[type="checkbox"][name="enabled_features[feature_sla]"]')['value']).to eq('true')
    end

    it 'saves through the normal update of the clinic and keeps its limits' do
      account.update!(limits: { 'agents' => 5 })
      open_card
      form = fine_tuning.at_css('form')
      expect(form['action']).to eq(card_path)
      expect(form.at_css('input[name="_method"]')['value']).to eq('patch')

      patch card_path, params: { account: { name: account.name }, enabled_features: { feature_sla: 'true', feature_crm: 'false' } }

      expect(response).to redirect_to(card_path)
      account.reload
      expect(account.feature_enabled?('sla')).to be(true)
      expect(account.feature_enabled?('crm')).to be(false)
      expect(account.limits).to eq('agents' => 5)
      expect(flash[:notice]).to eq('Клиника сохранена.')
    end

    it 'posts only the switches, without the name, so a rename made elsewhere in the meantime is not undone' do
      account.update!(limits: { 'agents' => 5 })
      open_card
      expect(fine_tuning.at_css('form').css('[name^="account"]')).to be_empty

      account.update!(name: 'Клиника Новая') # renamed in another tab while this page was open
      patch card_path, params: { enabled_features: { feature_sla: 'true', feature_crm: 'false' } }

      expect(response).to redirect_to(card_path)
      account.reload
      expect(account.name).to eq('Клиника Новая')
      expect(account.feature_enabled?('sla')).to be(true)
      expect(account.feature_enabled?('crm')).to be(false)
      expect(account.limits).to eq('agents' => 5)
      expect(flash[:notice]).to eq('Клиника сохранена.')
    end

    it 'does not touch the functions it does not show' do
      account.enable_features!('inbox_view', 'scheduling_finance')

      patch card_path, params: { account: { name: account.name }, enabled_features: { feature_sla: 'true' } }

      account.reload
      expect(account.feature_enabled?('inbox_view')).to be(true)
      expect(account.feature_enabled?('scheduling_finance')).to be(true)
      expect(account.feature_enabled?('agent_management')).to be(true)
    end

    it 'shows what is always on and what is never on' do
      open_card

      note = text(fine_tuning)
      expect(note).to include('Всегда включены: Управление операторами')
      expect(note).to include('Никогда не включаются:', 'Роли доступа', 'Единый вход SAML')
    end

    it 'does not offer the owner decisions here: they have their own block «Служебные»' do
      open_card

      expect(fine_tuning.at_css('input#feature-communication_threads')).to be_nil
      expect(text(fine_tuning)).not_to include('Решения владельца для отдельной клиники', 'разработчик')
      expect(page.at_css('details#service-flags input#service-communication_threads')).to be_present
    end
  end

  describe 'the users block' do
    it 'lists the members with Russian roles, e-mail and the last sign-in in Astana time' do
      admin = create(:user, account: account, role: :administrator, name: 'Айгерим')
      agent = create(:user, account: account, role: :agent, name: 'Мерей')
      admin.update_columns(current_sign_in_at: Time.utc(2026, 10, 15, 12, 0)) # rubocop:disable Rails/SkipsModelValidations

      open_card

      users = block('users-block')
      expect(text(users)).to include('Всего: 2')
      rows = users.css('tbody tr').to_h { |row| [row['data-user-id'].to_i, row.css('td').map { |cell| text(cell) }] }
      expect(rows[admin.id]).to eq(['Айгерим', admin.email, 'Администратор', '15.10.2026 17:00', 'Убрать из клиники'])
      expect(rows[agent.id]).to eq(['Мерей', agent.email, 'Оператор', '—', 'Убрать из клиники'])
      expect(users.at_css("a[href='/super_admin/users/#{admin.id}']")).to be_present
    end

    it 'has the form that adds a member, collapsed' do
      open_card

      details = block('users-block').at_css('details')
      expect(details['open']).to be_nil
      expect(details.at_css('form[action="/super_admin/account_users"]')).to be_present
      expect(details.at_css('input[type="hidden"][name="account_user[account_id]"]')['value']).to eq(account.id.to_s)
    end

    it 'says so when the clinic has no users' do
      open_card

      expect(text(block('users-block'))).to include('В клинике пока нет пользователей')
    end
  end

  describe 'the technical data block' do
    before do
      account.update!(custom_attributes: {
                        'plan' => 'base', 'plan_modules' => %w[ai_agents], 'tour_done' => true, 'note' => nil,
                        'limit_counter_excluded_user_ids' => [12, 15]
                      })
      open_card
    end

    it 'is collapsed' do
      expect(block('technical-block')['open']).to be_nil
      expect(block('technical-block').name).to eq('details')
    end

    it 'shows the attributes as a list of keys and values' do
      list = block('technical-block').at_css('[data-testid="custom-attributes"]')

      expect(list.name).to eq('dl')
      expect(text(list.at_css('[data-attribute="plan"]'))).to eq('plan base')
      expect(text(list.at_css('[data-attribute="tour_done"]'))).to eq('tour_done Да')
      expect(text(list.at_css('[data-attribute="note"]'))).to eq('note —')
    end

    it 'shows a list or a hash as readable JSON, not as a Ruby hash' do
      list = block('technical-block').at_css('[data-testid="custom-attributes"]')

      expect(list.at_css('[data-attribute="plan_modules"] pre').text).to include('"ai_agents"')
      expect(block('technical-block').text).not_to include('=>')
    end

    it 'lists the users the operator limit does not count' do
      expect(text(block('technical-block').at_css('[data-testid="excluded-ids"]'))).to eq('12, 15')
    end

    it 'says so when the clinic has no excluded users' do
      account.update!(custom_attributes: {})
      open_card

      expect(text(block('technical-block').at_css('[data-testid="excluded-ids"]'))).to eq('Нет')
    end
  end

  describe 'the side column' do
    it 'shows the basic facts in Astana time' do
      Accounts::ApplyPlan.new(account: account, modules: []).call

      open_card

      info = text(block('info-block'))
      expect(info).to include('Язык', 'Создана', 'Тариф применён', "версия #{Accounts::Plans.version}")
      expect(info).to include(SuperAdmin::DisplayHelper.format_time(account.reload.created_at))
    end

    it 'has the maintenance actions, each asking first' do
      open_card

      maintenance = block('maintenance-block')
      forms = maintenance.css('form').index_by { |form| form['action'] }
      expect(forms.keys).to contain_exactly("#{card_path}/reset_cache", "#{card_path}/seed", card_path)
      expect(maintenance.css('button').map { |button| button['data-confirm'] }).to all(be_present)
      destroy = forms[card_path]
      expect(destroy.at_css('input[name="_method"]')['value']).to eq('delete')
      expect(destroy.at_css('button')['data-confirm']).to include('Клиника Алатау')
    end
  end
end
