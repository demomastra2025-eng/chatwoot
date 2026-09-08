require 'rails_helper'

RSpec.describe SuperAdmin::BillingAccountsController, type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:payer) { create(:billing_account, metadata: { 'internal_flag' => true }, tax_id: 'OLD-TAX') }
  let(:path) { "/super_admin/billing_accounts/#{payer.id}" }
  let(:details) do
    {
      name: 'QA Payer', status: 'active', default_currency: 'KZT', default_locale: 'ru',
      payer_type: 'business', legal_name: 'Example LLP', tax_id: '123456789012',
      billing_contact_name: 'QA Contact', billing_email: 'billing@example.test',
      billing_phone: '+77000000000', billing_address: 'QA address', billing_country: 'kz'
    }
  end

  it 'requires SuperAdmin authentication' do
    patch path, params: { billing_account: { tax_id: 'NEW-TAX' } }

    expect(response).to redirect_to(new_super_admin_session_path)
    expect(payer.reload.tax_id).to eq('OLD-TAX')
  end

  context 'when authenticated as SuperAdmin' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'exposes every payer field on the new form and does not load the unused SDK' do
      get '/super_admin/billing_accounts/new'

      expect(response).to have_http_status(:ok)
      BillingAccount::PAYER_ATTRIBUTES.each do |field|
        expect(response.body).to include("billing_account[#{field}]")
      end
      expect(response.body).not_to include('/packs/js/sdk.js', 'chatwoot:ready')
    end

    it 'persists and audits all permitted payer details on creation' do
      post '/super_admin/billing_accounts', params: { billing_account: details.merge(metadata: { hacked: true }) }

      expect(response).to have_http_status(:redirect)
      created = BillingAccount.find_by!(name: 'QA Payer')
      expect(created).to have_attributes(legal_name: 'Example LLP', billing_country: 'KZ', tax_id: '123456789012')
      expect(created.metadata).not_to have_key('hacked')
      expect(created.audit_events.last).to have_attributes(super_admin_id: super_admin.id, action: 'billing_account_created')
      expect(created.audit_events.last.details).to include('billing_email' => 'billing@example.test', 'tax_id' => '123456789012')
    end

    it 'changes one field, preserves unrelated metadata, and audits before and after' do
      patch path, params: { billing_account: { tax_id: 'NEW-TAX', metadata: { internal_flag: false } } }

      expect(response).to redirect_to(path)
      expect(payer.reload.tax_id).to eq('NEW-TAX')
      expect(payer.metadata['internal_flag']).to be(true)
      expect(payer.audit_events.last.details).to include(
        'before' => include('tax_id' => 'OLD-TAX'), 'after' => include('tax_id' => 'NEW-TAX')
      )
      expect(payer.audit_events.last.details.to_json).not_to include('internal_flag')
    end

    it 'rejects invalid email without saving changes or audit events' do
      patch path, params: { billing_account: { billing_email: 'invalid', tax_id: 'NEW-TAX' } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(payer.reload.tax_id).to eq('OLD-TAX')
      expect(payer.audit_events).to be_empty
    end

    it 'shows escaped payer details on the account page' do
      payer.update!(legal_name: '<script>alert(1)</script>')
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
      expect(response.body).not_to include('<script>alert(1)</script>')
    end

    it 'shows a suspended subscription without allocation forms' do
      create(:billing_account_workspace, billing_account: payer)
      create(:billing_subscription, billing_account: payer, status: 'suspended')
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('suspended')
      expect(response.body).not_to include('No subscription has been assigned.', 'allocation[agents]')
    end

    it 'preserves the selected plan and price when only subscription status is submitted' do
      create(:billing_plan, name: 'A other plan')
      plan = create(:billing_plan, name: 'Z current plan')
      subscription = create(:billing_subscription, billing_account: payer, billing_plan: plan)
      get path
      html = Nokogiri::HTML(response.body)
      selected_plan = html.at_css('select[name="subscription[plan_id]"] option[selected]')['value']
      selected_price = html.at_css('select[name="subscription[price_id]"] option[selected]')['value']

      post "#{path}/assign_subscription", params: {
        subscription: { plan_id: selected_plan, price_id: selected_price, status: 'suspended' }
      }

      expect(response).to redirect_to(path)
      expect(payer.subscriptions.count).to eq(1)
      expect(subscription.reload).to have_attributes(status: 'suspended', billing_plan_id: plan.id)
      expect(subscription.billing_plan_price_id.to_s).to eq(selected_price)
    end
  end
end
