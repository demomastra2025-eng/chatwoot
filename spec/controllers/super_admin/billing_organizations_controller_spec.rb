require 'rails_helper'

RSpec.describe 'Super Admin billing organizations', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/billing_organizations' do
    it 'redirects unauthenticated users' do
      get '/super_admin/billing_organizations'

      expect(response).to have_http_status(:redirect)
    end

    it 'lists billing organizations for an authenticated super admin' do
      organization = create(:billing_organization)
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/billing_organizations'

      expect(response).to have_http_status(:success)
      expect(response.body).to include(organization.name)
    end
  end

  describe 'POST /super_admin/billing_organizations' do
    it 'creates a billing organization' do
      sign_in(super_admin, scope: :super_admin)

      expect do
        post '/super_admin/billing_organizations', params: {
          billing_organization: { name: 'Clinic network', status: 'active' }
        }
      end.to change(BillingOrganization, :count).by(1)

      expect(response).to redirect_to(super_admin_billing_organization_path(BillingOrganization.last))
    end
  end

  describe 'DELETE /super_admin/billing_organizations/:id' do
    it 'redirects unauthenticated users without deleting the organization' do
      organization = create(:billing_organization)

      expect do
        delete "/super_admin/billing_organizations/#{organization.id}"
      end.not_to change(BillingOrganization, :count)

      expect(response).to have_http_status(:redirect)
    end

    it 'does not delete an organization with workspaces' do
      organization = create(:billing_organization)
      account = create(:account, billing_organization: organization)
      sign_in(super_admin, scope: :super_admin)

      expect do
        delete "/super_admin/billing_organizations/#{organization.id}"
      end.not_to change(BillingOrganization, :count)

      expect(response).to redirect_to(super_admin_billing_organizations_path)
      expect(account.reload.billing_organization).to eq(organization)
    end

    it 'deletes an organization without workspaces' do
      organization = create(:billing_organization)
      sign_in(super_admin, scope: :super_admin)

      expect do
        delete "/super_admin/billing_organizations/#{organization.id}"
      end.to change(BillingOrganization, :count).by(-1)

      expect(response).to redirect_to(super_admin_billing_organizations_path)
    end
  end
end
