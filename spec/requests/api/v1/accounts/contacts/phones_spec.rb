require 'rails_helper'

RSpec.describe 'Contact Phones & Global Patient Context API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:auth_headers) { agent.create_new_auth_token }

  describe 'POST /api/v1/accounts/:account_id/contacts/:contact_id/phones' do
    context 'when adding a free second personal phone (Case A)' do
      let!(:contact) { create(:contact, account: account, name: 'Алия', phone_number: '+77010001122') }

      it 'adds the second owned phone, allows swapping primary, and promotes remaining owned phone on delete', :aggregate_failures do
        post "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/phones",
             params: { phone_number: '8 (705) 000-33-44', label: 'Beeline' },
             headers: auth_headers,
             as: :json

        expect(response).to have_http_status(:created)
        payload = response.parsed_body['payload']
        expect(payload['phone_number']).to eq('+77010001122')
        expect(payload['phone_numbers'].size).to eq(2)

        primary_entry, secondary_entry = payload['phone_numbers']
        expect(primary_entry).to include('phone_number' => '+77010001122', 'primary' => true, 'shared' => false)
        expect(secondary_entry).to include('phone_number' => '+77050003344', 'primary' => false, 'shared' => false, 'label' => 'Beeline')

        # Promote second personal phone to primary while keeping the first phone owned
        patch "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/phones/#{secondary_entry['id']}/set_primary",
              headers: auth_headers,
              as: :json

        expect(response).to have_http_status(:ok)
        swapped = response.parsed_body['payload']
        expect(swapped['phone_number']).to eq('+77050003344')
        expect(swapped['phone_numbers'].map { |p| [p['phone_number'], p['primary'], p['shared']] }).to eq(
          [['+77050003344', true, false], ['+77010001122', false, false]]
        )

        # Delete new primary -> automatically promotes remaining owned phone back to primary
        delete "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/phones/#{secondary_entry['id']}",
               headers: auth_headers,
               as: :json

        expect(response).to have_http_status(:ok)
        after_delete = response.parsed_body['payload']
        expect(after_delete['phone_number']).to eq('+77010001122')
        expect(after_delete['phone_numbers'].size).to eq(1)
        expect(after_delete['phone_numbers'].first).to include('phone_number' => '+77010001122', 'primary' => true, 'shared' => false)
      end

      it 'blocks another contact from claiming a secondary owned phone as primary (Iron Rule)' do
        post "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/phones",
             params: { phone_number: '+77050003344' },
             headers: auth_headers,
             as: :json
        expect(response).to have_http_status(:created)

        other = build(:contact, account: account, name: 'Другой', phone_number: '+77050003344')
        expect(other).not_to be_valid
        expect(other.errors[:phone_number]).to be_present
      end

      it 'enforces ContactPolicy RBAC (blocks custom role without contact_manage, allows with contact_manage)' do
        restricted_role = create(:custom_role, account: account, permissions: ['conversation_manage'])
        restricted_user = create(:user)
        create(:account_user, account: account, user: restricted_user, role: :agent, custom_role: restricted_role)

        post "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/phones",
             params: { phone_number: '+77050003344' },
             headers: restricted_user.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:unauthorized)

        allowed_role = create(:custom_role, account: account, permissions: %w[conversation_manage contact_manage])
        allowed_user = create(:user)
        create(:account_user, account: account, user: allowed_user, role: :agent, custom_role: allowed_role)

        post "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/phones",
             params: { phone_number: '+77050003344' },
             headers: allowed_user.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:created)
      end
    end

    context 'when adding an occupied phone belonging to another contact (Case B)' do
      let!(:wife) { create(:contact, account: account, name: 'Алия', phone_number: '+77020001122') }
      let!(:husband) { create(:contact, account: account, name: 'Серик', phone_number: '+77010009988') }
      let!(:child) { create(:contact, account: account, name: 'Арман', phone_number: nil) }

      it 'returns 409 first, then links husband as shared card on wife number without merging chats', :aggregate_failures do
        post "/api/v1/accounts/#{account.id}/contacts/#{husband.id}/phones",
             params: { phone_number: '+77020001122' },
             headers: auth_headers,
             as: :json

        expect(response).to have_http_status(:conflict)
        conflict = response.parsed_body
        expect(conflict['code']).to eq('PHONE_OWNED_BY_OTHER_CONTACT')
        expect(conflict['can_link_shared']).to be(true)
        expect(conflict['owner_contact']).to include('id' => wife.id, 'name' => 'Алия')

        # Confirm shared family link
        post "/api/v1/accounts/#{account.id}/contacts/#{husband.id}/phones",
             params: { phone_number: '+77020001122', link_shared: true },
             headers: auth_headers,
             as: :json

        expect(response).to have_http_status(:created)
        husband_payload = response.parsed_body['payload']
        expect(husband_payload['phone_number']).to eq('+77010009988')
        shared_entry = husband_payload['phone_numbers'].find { |p| p['phone_number'] == '+77020001122' }
        expect(shared_entry).to include('primary' => false, 'shared' => true, 'owner_contact_id' => wife.id)
        expect(shared_entry['owner_contact']).to include('id' => wife.id, 'name' => 'Алия')

        # Wife's contact page shows husband in shared_contacts
        get "/api/v1/accounts/#{account.id}/contacts/#{wife.id}",
            headers: auth_headers,
            as: :json
        wife_entry = response.parsed_body['payload']['phone_numbers'].find { |p| p['phone_number'] == '+77020001122' }
        expect(wife_entry['shared_contacts']).to include({ 'id' => husband.id, 'name' => 'Серик' })

        # Wife's chat header patient context includes [Wife, Husband], while husband's own +7701 chat stays 1-card
        account.disable_features!('scheduling')
        get "/api/v1/accounts/#{account.id}/scheduling/contacts/#{wife.id}/patients",
            headers: auth_headers,
            as: :json
        expect(response).to have_http_status(:ok)
        wife_patients = response.parsed_body.dig('payload', 'patients')
        expect(wife_patients.map { |p| p['id'] }).to eq([wife.id, husband.id])
        expect(wife_patients.second['selectable_patient']).to be(true)

        get "/api/v1/accounts/#{account.id}/scheduling/contacts/#{husband.id}/patients",
            headers: auth_headers,
            as: :json
        expect(response.parsed_body.dig('payload', 'patients').map { |p| p['id'] }).to eq([husband.id])

        # Automated notifications to husband still route to husband's own personal +7701
        expect(Contacts::SharedPhone.route_contact(husband.reload)).to eq(husband)

        # ActionCable contact push_event_data omits phone_numbers by default (message/conversation)
        # and includes full owner_contact / shared_contacts when include_phone_relations: true
        expect(husband.push_event_data).not_to have_key(:phone_numbers)
        ac_payload = husband.push_event_data(include_phone_relations: true)
        ac_shared = ac_payload[:phone_numbers].find { |p| p[:phone_number] == '+77020001122' }
        expect(ac_shared[:owner_contact]).to eq({ id: wife.id, name: 'Алия' })
      end

      it 'links a child without own phone to mom number, keeps child phone_numbers non-empty, and routes child notifications via mom (Subcase B2)' do
        post "/api/v1/accounts/#{account.id}/contacts/#{child.id}/phones",
             params: { phone_number: '+77020001122', link_shared: true },
             headers: auth_headers,
             as: :json

        expect(response).to have_http_status(:created)
        child_payload = response.parsed_body['payload']
        expect(child_payload['phone_number']).to be_nil
        expect(child_payload['phone_numbers'].size).to eq(1)
        expect(child_payload['phone_numbers'].first).to include(
          'phone_number' => '+77020001122',
          'primary' => false,
          'shared' => true,
          'owner_contact_id' => wife.id,
          'owner_contact' => { 'id' => wife.id, 'name' => 'Алия' }
        )
        expect(child.reload.conversations.count).to eq(0)
        expect(Contacts::SharedPhone.route_contact(child)).to eq(wife)

        get "/api/v1/accounts/#{account.id}/scheduling/contacts/#{wife.id}/patients",
            headers: auth_headers,
            as: :json
        expect(response.parsed_body.dig('payload', 'patients').map { |p| p['id'] }).to include(wife.id, child.id)
      end
    end
  end

  describe 'POST /api/v1/accounts/:account_id/scheduling/contacts/:id/patients when scheduling feature is disabled' do
    let!(:owner) { create(:contact, account: account, name: 'Мама', phone_number: '+77017778899') }

    it 'creates a family card and populates shared contact_phones even when scheduling calendar feature is off' do
      account.disable_features!('scheduling')

      post "/api/v1/accounts/#{account.id}/scheduling/contacts/#{owner.id}/patients",
           params: {
             first_name: 'Димаш',
             last_name: 'Сериков',
             birth_date: '2019-05-12',
             gender: 'male',
             idempotency_key: 'stage2-global-create-1'
           },
           headers: auth_headers,
           as: :json

      expect(response).to have_http_status(:created)
      created_payload = response.parsed_body['payload']
      expect(created_payload['full_name']).to include('Димаш')
      expect(created_payload['phone']).to eq('+77017778899')
      expect(created_payload['phone_numbers'].first).to include(
        'phone_number' => '+77017778899',
        'shared' => true,
        'owner_contact_id' => owner.id
      )
    end
  end
end
