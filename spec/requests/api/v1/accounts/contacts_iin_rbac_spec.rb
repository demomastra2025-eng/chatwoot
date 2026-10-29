require 'rails_helper'
require 'csv'

RSpec.describe 'Contact IIN RBAC masking & anti-enumeration (contact_iin_view)', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:plain_agent) { create(:user, account: account, role: :agent) }

  let(:marketer_role) do
    CustomRole.create!(
      account: account,
      name: 'Маркетолог / Аналитик',
      description: 'Работа со сделками и контактами без доступа к ИИН',
      permissions: %w[contact_manage conversation_manage crm_deal_view]
    )
  end
  let(:coordinator_role) do
    CustomRole.create!(
      account: account,
      name: 'Старший координатор',
      description: 'Доступ к контактам и просмотру ИИН',
      permissions: %w[contact_manage contact_iin_view conversation_manage crm_deal_view]
    )
  end

  let(:marketer) do
    user = create(:user, account: account, role: :agent)
    user.account_users.find_by!(account: account).update!(custom_role: marketer_role)
    user
  end
  let(:coordinator) do
    user = create(:user, account: account, role: :agent)
    user.account_users.find_by!(account: account).update!(custom_role: coordinator_role)
    user
  end

  let(:real_iin) { '900101300123' }
  let!(:patient_contact) do
    create(
      :contact,
      account: account,
      name: 'Айгуль Серикова',
      phone_number: '+77015554433',
      email: 'aigul@example.com',
      identifier: real_iin,
      custom_attributes: {
        'iin' => real_iin,
        'medelement_iin' => real_iin,
        'city' => 'Алматы'
      },
      additional_attributes: {
        'iin' => real_iin,
        'description' => 'VIP пациент'
      }
    )
  end
  let!(:external_uuid_contact) do
    create(
      :contact,
      account: account,
      name: 'Корпоративный клиент',
      phone_number: '+77019998877',
      identifier: 'ext-crm-uuid-42'
    )
  end

  before do
    account.enable_features!('scheduling')
  end

  describe 'read masking across contact & scheduling endpoints' do
    it 'shows full IIN to administrators, plain agents, and custom roles with contact_iin_view' do
      [admin, plain_agent, coordinator].each do |actor|
        get "/api/v1/accounts/#{account.id}/contacts/#{patient_contact.id}",
            headers: actor.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['payload']).to include(
          'identifier' => real_iin,
          'custom_attributes' => include('iin' => real_iin, 'medelement_iin' => real_iin),
          'additional_attributes' => include('iin' => real_iin)
        )
      end
    end

    it 'masks IIN in contact show while keeping non-IIN fields and external UUIDs intact' do
      headers = marketer.create_new_auth_token
      masked = Contacts::IinPrivacy::MASKED_IIN

      get "/api/v1/accounts/#{account.id}/contacts/#{patient_contact.id}", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(real_iin)
      expect(response.parsed_body['payload']).to include(
        'identifier' => masked,
        'custom_attributes' => include('iin' => masked, 'medelement_iin' => masked, 'city' => 'Алматы'),
        'additional_attributes' => include('iin' => masked)
      )

      get "/api/v1/accounts/#{account.id}/contacts/#{external_uuid_contact.id}", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'identifier')).to eq('ext-crm-uuid-42')
    end

    it 'masks IIN in scheduling contacts for custom roles without contact_iin_view' do
      get "/api/v1/accounts/#{account.id}/scheduling/contacts",
          headers: marketer.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(real_iin)
      patient_row = response.parsed_body['payload'].find { |row| row['id'] == patient_contact.id }
      expect(patient_row).to include(
        'identifier' => Contacts::IinPrivacy::MASKED_IIN,
        'custom_attributes' => include('iin' => Contacts::IinPrivacy::MASKED_IIN)
      )
    end

    it 'masks IIN in conversation messages API and ActionCable realtime payloads for restricted roles' do
      inbox = create(:inbox, account: account)
      create(:inbox_member, user: marketer, inbox: inbox)
      conv = create(:conversation, account: account, inbox: inbox, contact: patient_contact)
      create(:message, account: account, inbox: inbox, conversation: conv, sender: patient_contact, message_type: :incoming)

      get "/api/v1/accounts/#{account.id}/conversations/#{conv.display_id}/messages",
          headers: marketer.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(real_iin)

      membership = marketer.account_users.find_by!(account: account)
      realtime = Contacts::IinPrivacy.mask_realtime_payload(
        { 'event' => 'contact.updated', 'data' => { 'id' => patient_contact.id, 'identifier' => real_iin, 'iin' => real_iin } },
        account_user: membership
      )
      expect(realtime['data']).to include(
        'identifier' => Contacts::IinPrivacy::MASKED_IIN,
        'iin' => Contacts::IinPrivacy::MASKED_IIN
      )
    end

    it 'returns empty directory envelope for IIN query and masks iin_masked in MedElement Hash results' do
      hook = Integrations::Hook.new(account: account, app_id: 'medelement')
      directory = instance_double(
        Integrations::Medelement::PatientDirectorySearch,
        search: { patients: [{ full_name: 'Серикова Айгуль', iin_masked: '••••0123' }], truncated: false }
      )
      allow(Scheduling::ProviderCommands::Registry).to receive(:resolve!).and_return(Struct.new(:hook).new(hook))
      allow(Integrations::Medelement::PatientDirectorySearch).to receive(:new).and_return(directory)
      headers = marketer.create_new_auth_token.merge('CONTENT_TYPE' => 'application/json')

      post "/api/v1/accounts/#{account.id}/scheduling/medelement_patients/search",
           params: { query: real_iin }.to_json, headers: headers
      expect(response.parsed_body['payload']).to eq('patients' => [], 'reason' => 'unsupported', 'truncated' => false)

      post "/api/v1/accounts/#{account.id}/scheduling/medelement_patients/search",
           params: { query: 'Серикова' }.to_json, headers: headers
      expect(response.body).not_to include('0123')
      expect(response.parsed_body.dig('payload', 'patients', 0, 'iin_masked')).to eq(Contacts::IinPrivacy::MASKED_IIN)
    end
  end

  describe 'anti-enumeration on search and filter endpoints' do
    let!(:inbox) { create(:inbox, account: account) }

    before do
      create(:conversation, account: account, inbox: inbox, contact: patient_contact)
      create(:inbox_member, user: marketer, inbox: inbox)
      create(:inbox_member, user: coordinator, inbox: inbox)
    end

    it 'blocks 12-digit IIN lookup across contact, global, and scheduling search endpoints' do
      headers = marketer.create_new_auth_token

      get "/api/v1/accounts/#{account.id}/contacts/search", params: { q: real_iin }, headers: headers
      expect(response.parsed_body['payload']).to be_empty

      get "/api/v1/accounts/#{account.id}/search/contacts", params: { q: real_iin }, headers: headers
      expect(response.parsed_body.dig('payload', 'contacts')).to be_empty

      get "/api/v1/accounts/#{account.id}/search/conversations", params: { q: real_iin }, headers: headers
      expect(response.parsed_body.dig('payload', 'conversations')).to be_empty

      get "/api/v1/accounts/#{account.id}/scheduling/contacts", params: { search: real_iin }, headers: headers
      expect(response.parsed_body['payload']).to be_empty
    end

    it 'blocks partial 6-digit IIN prefix and zero-width Unicode IIN lookup while finding external UUIDs' do
      headers = marketer.create_new_auth_token

      get "/api/v1/accounts/#{account.id}/contacts/search", params: { q: '900101' }, headers: headers
      expect(response.parsed_body['payload']).to be_empty

      get "/api/v1/accounts/#{account.id}/search/contacts", params: { q: '900101' }, headers: headers
      expect(response.parsed_body.dig('payload', 'contacts')).to be_empty

      get "/api/v1/accounts/#{account.id}/scheduling/contacts", params: { search: '900101' }, headers: headers
      expect(response.parsed_body['payload']).to be_empty

      get "/api/v1/accounts/#{account.id}/contacts/search", params: { q: "900101\u200B300123" }, headers: headers
      expect(response.parsed_body['payload']).to be_empty

      get "/api/v1/accounts/#{account.id}/contacts/search", params: { q: 'ext-crm-uuid' }, headers: headers
      expect(response.parsed_body['payload'].pluck('id')).to include(external_uuid_contact.id)
    end

    it 'blocks IIN filter rules while allowing phone search with masked IIN payload' do
      headers = marketer.create_new_auth_token
      filter_rule = { attribute_key: 'identifier', filter_operator: 'equal_to', values: [real_iin], query_operator: nil }

      post "/api/v1/accounts/#{account.id}/contacts/filter",
           params: { payload: [filter_rule] },
           headers: headers,
           as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['payload']).to be_empty

      get "/api/v1/accounts/#{account.id}/contacts/search", params: { q: '+77015554433' }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['payload'].pluck('id')).to include(patient_contact.id)
      expect(response.body).not_to include(real_iin)
    end

    it 'allows 12-digit IIN lookup for custom roles with contact_iin_view' do
      get "/api/v1/accounts/#{account.id}/contacts/search",
          params: { q: real_iin },
          headers: coordinator.create_new_auth_token

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['payload'].pluck('id')).to include(patient_contact.id)
    end
  end

  describe 'round-trip write & export protection' do
    it 'preserves stored real IIN when a user without contact_iin_view updates contact or destroys custom attributes' do
      headers = marketer.create_new_auth_token
      masked = Contacts::IinPrivacy::MASKED_IIN

      patch "/api/v1/accounts/#{account.id}/contacts/#{patient_contact.id}",
            params: {
              name: 'Айгуль Обновлённая',
              identifier: masked,
              custom_attributes: { 'iin' => masked, 'medelement_iin' => masked, 'city' => 'Астана' }
            },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(patient_contact.reload).to have_attributes(
        name: 'Айгуль Обновлённая',
        identifier: real_iin,
        custom_attributes: include('iin' => real_iin, 'medelement_iin' => real_iin, 'city' => 'Астана')
      )

      post "/api/v1/accounts/#{account.id}/contacts/#{patient_contact.id}/destroy_custom_attributes",
           params: { custom_attributes: %w[iin medelement_iin city] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(patient_contact.reload.custom_attributes).to include('iin' => real_iin, 'medelement_iin' => real_iin)
      expect(patient_contact.custom_attributes).not_to have_key('city')
    end

    it 'keeps canonical unmasked IIN in shared ActionCable broadcasts when restricted user updates contact' do
      broadcast_payloads = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) do |_tokens, _event_name, data|
        broadcast_payloads << data
      end

      patch "/api/v1/accounts/#{account.id}/contacts/#{patient_contact.id}",
            params: { custom_attributes: { 'city' => 'Караганда' } },
            headers: marketer.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(real_iin)
      expect(broadcast_payloads.last).to include(
        identifier: real_iin,
        custom_attributes: include('iin' => real_iin, 'medelement_iin' => real_iin, 'city' => 'Караганда')
      )
    end

    it 'guards authorized admin updates against masked placeholder overwrite' do
      masked = Contacts::IinPrivacy::MASKED_IIN
      patch "/api/v1/accounts/#{account.id}/contacts/#{patient_contact.id}",
            params: {
              identifier: masked,
              custom_attributes: { 'iin' => masked, 'medelement_iin' => masked, 'city' => 'Шымкент' },
              additional_attributes: { 'iin' => masked, 'description' => 'Обновлено админом' }
            },
            headers: admin.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(patient_contact.reload).to have_attributes(
        identifier: real_iin,
        custom_attributes: include('iin' => real_iin, 'medelement_iin' => real_iin, 'city' => 'Шымкент'),
        additional_attributes: include('iin' => real_iin, 'description' => 'Обновлено админом')
      )
    end

    it 'masks cross-account RoomChannel payloads per target account_id and fails closed when membership is absent' do
      second_account = create(:account)
      third_account = create(:account)
      second_role = CustomRole.create!(
        account: second_account, name: 'Аналитик филиала 2', description: 'Без ИИН',
        permissions: %w[contact_manage conversation_manage]
      )
      AccountUser.create!(account: second_account, user: admin, role: :agent, custom_role: second_role)

      channel = RoomChannel.allocate
      channel.instance_variable_set(:@current_user, admin)
      channel.instance_variable_set(:@current_account, account)
      build_event = ->(acc_id) { { 'event' => 'contact.updated', 'data' => { 'account_id' => acc_id, 'identifier' => real_iin, 'iin' => real_iin } } }

      expect(channel.send(:mask_payload_for_recipient, build_event.call(account.id))['data']['identifier']).to eq(real_iin)
      expect(channel.send(:mask_payload_for_recipient, build_event.call(second_account.id))['data']).to include(
        'identifier' => Contacts::IinPrivacy::MASKED_IIN, 'iin' => Contacts::IinPrivacy::MASKED_IIN
      )
      third_masked = channel.send(:mask_payload_for_recipient, build_event.call(third_account.id))
      expect(third_masked['data']['identifier']).to eq(Contacts::IinPrivacy::MASKED_IIN)
    end

    it 'masks IIN in Account::ContactsExportJob when triggered for a user without contact_iin_view' do
      Account::ContactsExportJob.perform_now(
        account.id,
        marketer.id,
        %w[id name identifier custom_attributes],
        {}
      )

      exported_csv = account.reload.contacts_export.download.force_encoding('UTF-8')
      expect(exported_csv).not_to include(real_iin)
      expect(exported_csv).to include(Contacts::IinPrivacy::MASKED_IIN)
    end
  end
end
