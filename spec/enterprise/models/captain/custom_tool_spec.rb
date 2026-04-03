require 'rails_helper'

RSpec.describe Captain::CustomTool, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:endpoint_url) }
    it do
      expect(subject).to define_enum_for(:http_method).with_values(
        'GET' => 'GET',
        'POST' => 'POST',
        'PUT' => 'PUT',
        'PATCH' => 'PATCH',
        'DELETE' => 'DELETE',
        'HEAD' => 'HEAD',
        'OPTIONS' => 'OPTIONS'
      ).backed_by_column_of_type(:string)
    end

    it {
      expect(subject).to define_enum_for(:auth_type).with_values('none' => 'none', 'bearer' => 'bearer', 'basic' => 'basic',
                                                                 'api_key' => 'api_key').backed_by_column_of_type(:string).with_prefix(:auth)
    }

    describe 'slug uniqueness' do
      let(:account) { create(:account) }

      it 'validates uniqueness of slug scoped to account' do
        create(:captain_custom_tool, account: account, slug: 'custom_test_tool')
        duplicate = build(:captain_custom_tool, account: account, slug: 'custom_test_tool')

        expect(duplicate).not_to be_valid
        expect(duplicate.errors.of_kind?(:slug, :taken)).to be(true)
      end

      it 'allows same slug across different accounts' do
        account2 = create(:account)
        create(:captain_custom_tool, account: account, slug: 'custom_test_tool')
        different_account_tool = build(:captain_custom_tool, account: account2, slug: 'custom_test_tool')

        expect(different_account_tool).to be_valid
      end
    end

    describe 'param_schema validation' do
      let(:account) { create(:account) }
      let!(:contact_attribute_definition) do
        create(
          :custom_attribute_definition,
          account: account,
          attribute_model: :contact_attribute,
          attribute_key: 'vip_level',
          attribute_display_name: 'VIP Level'
        )
      end

      it 'is valid with proper param_schema' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID', 'required' => true }
                     ])

        expect(tool).to be_valid
      end

      it 'is valid with empty param_schema' do
        tool = build(:captain_custom_tool, account: account, param_schema: [])

        expect(tool).to be_valid
      end

      it 'is invalid when param_schema is missing name' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'type' => 'string', 'description' => 'Order ID' }
                     ])

        expect(tool).not_to be_valid
      end

      it 'is invalid when param_schema is missing type' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'description' => 'Order ID' }
                     ])

        expect(tool).not_to be_valid
      end

      it 'is invalid when param_schema is missing description' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string' }
                     ])

        expect(tool).not_to be_valid
      end

      it 'ignores additional properties in param_schema during normalization' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID', 'extra_field' => 'value' }
                     ])

        expect(tool).to be_valid
        expect(tool.param_schema.first).not_to have_key('extra_field')
      end

      it 'is invalid when a parameter name is blank' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => '   ', 'type' => 'string', 'description' => 'Order ID' }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include('parameter names cannot be blank')
      end

      it 'is invalid when a parameter name uses unsupported characters' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order-id', 'type' => 'string', 'description' => 'Order ID' }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include(
          'parameter order-id must use only letters, numbers, and underscores'
        )
      end

      it 'is invalid when a parameter name uses a reserved system context name' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'contact', 'type' => 'string', 'description' => 'Attempted override' }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include('parameter contact uses a reserved name')
      end

      it 'is invalid when a parameter name uses a reserved CRM context name' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'deal', 'type' => 'string', 'description' => 'Attempted deal override' },
                       { 'name' => 'task', 'type' => 'string', 'description' => 'Attempted task override' }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include('parameter deal uses a reserved name')
        expect(tool.errors[:param_schema]).to include('parameter task uses a reserved name')
      end

      it 'is invalid when parameter names are duplicated' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Primary order ID' },
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Secondary order ID' }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include('parameter order_id is duplicated')
      end

      it 'is invalid when a parameter type is unknown' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'integer', 'description' => 'Order ID' }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include('parameter order_id has an invalid type')
      end

      it 'is invalid when a parameter description is blank' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => '   ' }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include('parameter order_id must define a description')
      end

      it 'is valid when required field is omitted (defaults to optional param)' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID' }
                     ])

        expect(tool).to be_valid
      end

      it 'defaults missing sources to agent' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID' }
                     ])

        tool.validate

        expect(tool.param_schema.first['source']).to eq('agent')
      end

      it 'defaults missing required flags to false' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID' }
                     ])

        tool.validate

        expect(tool.param_schema.first['required']).to be(false)
      end

      it 'is valid with a known context field mapping' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       {
                         'name' => 'vip_level',
                         'type' => 'string',
                         'description' => 'VIP level from the current contact',
                         'source' => 'context',
                         'context_path' => 'contact.custom_attributes.vip_level'
                       }
                     ])

        expect(tool).to be_valid
      end

      it 'is invalid when a context mapping references an unknown field' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       {
                         'name' => 'vip_level',
                         'type' => 'string',
                         'description' => 'VIP level from the current contact',
                         'source' => 'context',
                         'context_path' => 'contact.custom_attributes.missing_field'
                       }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include(
          'parameter vip_level references an unknown context field'
        )
      end

      it 'is invalid when a fixed parameter has no configured value' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       {
                         'name' => 'pipeline',
                         'type' => 'string',
                         'description' => 'Destination pipeline',
                         'source' => 'fixed',
                         'fixed_value' => ''
                       }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include(
          'parameter pipeline must define a fixed value'
        )
      end

      it 'is invalid when a fixed JSON parameter cannot be parsed' do
        tool = build(:captain_custom_tool, account: account, param_schema: [
                       {
                         'name' => 'filters',
                         'type' => 'object',
                         'description' => 'Static filters',
                         'source' => 'fixed',
                         'fixed_value' => '{invalid json}'
                       }
                     ])

        expect(tool).not_to be_valid
        expect(tool.errors[:param_schema]).to include(
          'parameter filters must be valid JSON object'
        )
      end
    end

    it 'accepts the full supported HTTP method set' do
      Captain::CustomTool::HTTP_METHODS.each do |http_method|
        tool = build(:captain_custom_tool, http_method: http_method)

        expect(tool).to be_valid
      end
    end
  end

  describe 'scopes' do
    let(:account) { create(:account) }

    describe '.enabled' do
      it 'returns only enabled custom tools' do
        enabled_tool = create(:captain_custom_tool, account: account, enabled: true)
        disabled_tool = create(:captain_custom_tool, account: account, enabled: false)

        enabled_ids = described_class.enabled.pluck(:id)
        expect(enabled_ids).to include(enabled_tool.id)
        expect(enabled_ids).not_to include(disabled_tool.id)
      end
    end
  end

  describe 'slug generation' do
    let(:account) { create(:account) }

    it 'generates slug from title on creation' do
      tool = create(:captain_custom_tool, account: account, title: 'Fetch Order Status')

      expect(tool.slug).to eq('custom_fetch_order_status')
    end

    it 'adds custom_ prefix to generated slug' do
      tool = create(:captain_custom_tool, account: account, title: 'My Tool')

      expect(tool.slug).to start_with('custom_')
    end

    it 'does not override manually set slug' do
      tool = create(:captain_custom_tool, account: account, title: 'Test Tool', slug: 'custom_manual_slug')

      expect(tool.slug).to eq('custom_manual_slug')
    end

    it 'handles slug collisions by appending random suffix' do
      create(:captain_custom_tool, account: account, title: 'Test Tool', slug: 'custom_test_tool')
      tool2 = create(:captain_custom_tool, account: account, title: 'Test Tool')

      expect(tool2.slug).to match(/^custom_test_tool_[a-z0-9]{6}$/)
    end

    it 'handles multiple slug collisions' do
      create(:captain_custom_tool, account: account, title: 'Test Tool', slug: 'custom_test_tool')
      create(:captain_custom_tool, account: account, title: 'Test Tool', slug: 'custom_test_tool_abc123')
      tool3 = create(:captain_custom_tool, account: account, title: 'Test Tool')

      expect(tool3.slug).to match(/^custom_test_tool_[a-z0-9]{6}$/)
      expect(tool3.slug).not_to eq('custom_test_tool')
      expect(tool3.slug).not_to eq('custom_test_tool_abc123')
    end

    it 'does not generate slug when title is blank' do
      tool = build(:captain_custom_tool, account: account, title: nil)

      expect(tool).not_to be_valid
      expect(tool.errors.of_kind?(:title, :blank)).to be(true)
    end

    it 'parameterizes title correctly' do
      tool = create(:captain_custom_tool, account: account, title: 'Fetch Order Status & Details!')

      expect(tool.slug).to eq('custom_fetch_order_status_details')
    end

    it 'transliterates Cyrillic titles into stable ASCII slugs' do
      tool = create(:captain_custom_tool, account: account, title: 'Получить персонажей')

      expect(tool.slug).to eq('custom_poluchit_personazhey')
    end

    it 'falls back to a safe slug body when title cannot be transliterated' do
      tool = create(:captain_custom_tool, account: account, title: '你好')

      expect(tool.slug).to eq('custom_tool')
    end
  end

  describe 'factory' do
    it 'creates a valid custom tool with default attributes' do
      tool = create(:captain_custom_tool)

      expect(tool).to be_valid
      expect(tool.title).to be_present
      expect(tool.slug).to be_present
      expect(tool.endpoint_url).to be_present
      expect(tool.http_method).to eq('GET')
      expect(tool.auth_type).to eq('none')
      expect(tool.enabled).to be true
    end

    it 'creates valid tool with POST trait' do
      tool = create(:captain_custom_tool, :with_post)

      expect(tool.http_method).to eq('POST')
      expect(tool.request_template).to be_present
    end

    it 'creates valid tool with bearer auth trait' do
      tool = create(:captain_custom_tool, :with_bearer_auth)

      expect(tool.auth_type).to eq('bearer')
      expect(tool.auth_config['token']).to eq('test_bearer_token_123')
    end

    it 'creates valid tool with basic auth trait' do
      tool = create(:captain_custom_tool, :with_basic_auth)

      expect(tool.auth_type).to eq('basic')
      expect(tool.auth_config['username']).to eq('test_user')
      expect(tool.auth_config['password']).to eq('test_pass')
    end

    it 'creates valid tool with api key trait' do
      tool = create(:captain_custom_tool, :with_api_key)

      expect(tool.auth_type).to eq('api_key')
      expect(tool.auth_config['key']).to eq('test_api_key')
      expect(tool.auth_config['location']).to eq('header')
    end
  end

  describe 'Toolable concern' do
    let(:account) { create(:account) }

    describe '#build_request_url' do
      it 'returns static URL when no template variables present' do
        tool = create(:captain_custom_tool, account: account, endpoint_url: 'https://api.example.com/orders')

        expect(tool.build_request_url({})).to eq('https://api.example.com/orders')
      end

      it 'renders URL template with params' do
        tool = create(:captain_custom_tool, account: account, endpoint_url: 'https://api.example.com/orders/{{ order_id }}')

        expect(tool.build_request_url({ order_id: '12345' })).to eq('https://api.example.com/orders/12345')
      end

      it 'handles multiple template variables' do
        tool = create(:captain_custom_tool, account: account,
                                            endpoint_url: 'https://api.example.com/{{ resource }}/{{ id }}?details={{ show_details }}')

        result = tool.build_request_url({ resource: 'orders', id: '123', show_details: 'true' })
        expect(result).to eq('https://api.example.com/orders/123?details=true')
      end

      it 'renders URL template with filtered captain context variables' do
        tool = create(:captain_custom_tool, account: account,
                                            endpoint_url: 'https://api.example.com/contacts/{{ contact.phone_number }}')

        result = tool.build_request_url(
          {},
          template_context: {
            contact: {
              phone_number: '+1234567890'
            }
          }
        )

        expect(result).to eq('https://api.example.com/contacts/+1234567890')
      end
    end

    describe '#build_request_body' do
      it 'returns nil when request_template is blank' do
        tool = create(:captain_custom_tool, account: account, request_template: nil)

        expect(tool.build_request_body({})).to be_nil
      end

      it 'renders request body template with params' do
        tool = create(:captain_custom_tool, account: account,
                                            request_template: '{ "order_id": "{{ order_id }}", "source": "chatwoot" }')

        result = tool.build_request_body({ order_id: '12345' })
        expect(result).to eq('{ "order_id": "12345", "source": "chatwoot" }')
      end

      it 'renders request body with captain context variables' do
        tool = create(:captain_custom_tool, account: account,
                                            request_template: '{ "phone": "{{ contact.phone_number }}", "order_id": "{{ conversation.custom_attributes.order_id }}" }')

        result = tool.build_request_body(
          {},
          template_context: {
            contact: { phone_number: '+1234567890' },
            conversation: { custom_attributes: { order_id: 'ORD-42' } }
          }
        )

        expect(result).to eq('{ "phone": "+1234567890", "order_id": "ORD-42" }')
      end
    end

    describe '#build_auth_headers' do
      it 'returns empty hash for none auth type' do
        tool = create(:captain_custom_tool, account: account, auth_type: 'none')

        expect(tool.build_auth_headers).to eq({})
      end

      it 'returns bearer token header' do
        tool = create(:captain_custom_tool, :with_bearer_auth, account: account)

        expect(tool.build_auth_headers).to eq({ 'Authorization' => 'Bearer test_bearer_token_123' })
      end

      it 'returns API key header when location is header' do
        tool = create(:captain_custom_tool, :with_api_key, account: account)

        expect(tool.build_auth_headers).to eq({ 'X-API-Key' => 'test_api_key' })
      end

      it 'returns empty hash for API key when location is not header' do
        tool = create(:captain_custom_tool, account: account, auth_type: 'api_key',
                                            auth_config: { key: 'test_key', location: 'query', name: 'api_key' })

        expect(tool.build_auth_headers).to eq({})
      end

      it 'returns empty hash for basic auth' do
        tool = create(:captain_custom_tool, :with_basic_auth, account: account)

        expect(tool.build_auth_headers).to eq({})
      end
    end

    describe '#build_basic_auth_credentials' do
      it 'returns nil for non-basic auth types' do
        tool = create(:captain_custom_tool, account: account, auth_type: 'none')

        expect(tool.build_basic_auth_credentials).to be_nil
      end

      it 'returns username and password array for basic auth' do
        tool = create(:captain_custom_tool, :with_basic_auth, account: account)

        expect(tool.build_basic_auth_credentials).to eq(%w[test_user test_pass])
      end
    end

    describe '#format_response' do
      it 'returns raw response when no response_template' do
        tool = create(:captain_custom_tool, account: account, response_template: nil)

        expect(tool.format_response('raw response')).to eq('raw response')
      end

      it 'renders response template with JSON response' do
        tool = create(:captain_custom_tool, account: account,
                                            response_template: 'Order status: {{ response.status }}')
        raw_response = '{"status": "shipped", "tracking": "123ABC"}'

        result = tool.format_response(raw_response)
        expect(result).to eq('Order status: shipped')
      end

      it 'handles response template with multiple fields' do
        tool = create(:captain_custom_tool, account: account,
                                            response_template: 'Order {{ response.id }} is {{ response.status }}. Tracking: {{ response.tracking }}')
        raw_response = '{"id": "12345", "status": "delivered", "tracking": "ABC123"}'

        result = tool.format_response(raw_response)
        expect(result).to eq('Order 12345 is delivered. Tracking: ABC123')
      end

      it 'handles non-JSON response' do
        tool = create(:captain_custom_tool, account: account,
                                            response_template: 'Response: {{ response }}')
        raw_response = 'plain text response'

        result = tool.format_response(raw_response)
        expect(result).to eq('Response: plain text response')
      end
    end

    describe '#build_metadata_headers' do
      let(:tool) { create(:captain_custom_tool, account: account, slug: 'custom_test_tool') }
      let(:conversation) { create(:conversation, account: account) }
      let(:contact) { conversation.contact }
      let(:deal) do
        create(
          :crm_deal,
          account: account,
          originating_conversation: conversation
        )
      end
      let(:task) do
        create(
          :crm_task,
          account: account,
          originating_conversation: conversation
        )
      end
      let(:appointment) do
        create(
          :scheduling_appointment,
          account: account,
          resource: create(:scheduling_resource, account: account),
          service: create(:scheduling_service, account: account),
          contact: contact,
          conversation: conversation,
          status: 'confirmed',
          starts_at: Time.zone.parse('2026-03-29 10:00:00 UTC')
        )
      end

      let(:state) do
        {
          account_id: account.id,
          assistant_id: 123,
          conversation: {
            id: conversation.id,
            display_id: conversation.display_id
          },
          contact_inbox: {
            id: conversation.contact_inbox.id,
            hmac_verified: conversation.contact_inbox.hmac_verified
          },
          contact: {
            id: contact.id,
            email: contact.email,
            phone_number: contact.phone_number
          },
          deal: {
            id: deal.id,
            title: deal.title,
            stage_name: deal.stage.name
          },
          task: {
            id: task.id,
            title: task.title,
            status_name: task.status.name
          },
          appointment: {
            id: appointment.id,
            status: appointment.status,
            starts_at: appointment.starts_at.iso8601
          }
        }
      end

      it 'includes account and assistant metadata' do
        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Account-Id']).to eq(account.id.to_s)
        expect(headers['X-Chatwoot-Assistant-Id']).to eq('123')
      end

      it 'includes tool slug' do
        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Tool-Slug']).to eq('custom_test_tool')
      end

      it 'includes conversation metadata when present' do
        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Conversation-Id']).to eq(conversation.id.to_s)
        expect(headers['X-Chatwoot-Conversation-Display-Id']).to eq(conversation.display_id.to_s)
      end

      it 'includes contact metadata when present' do
        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Contact-Id']).to eq(contact.id.to_s)
        expect(headers['X-Chatwoot-Contact-Email']).to eq(contact.email)
      end

      it 'includes deal metadata when present' do
        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Deal-Id']).to eq(deal.id.to_s)
        expect(headers['X-Chatwoot-Deal-Title']).to eq(deal.title)
        expect(headers['X-Chatwoot-Deal-Stage']).to eq(deal.stage.name)
      end

      it 'includes task metadata when present' do
        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Task-Id']).to eq(task.id.to_s)
        expect(headers['X-Chatwoot-Task-Title']).to eq(task.title)
        expect(headers['X-Chatwoot-Task-Status']).to eq(task.status.name)
      end

      it 'includes appointment metadata when present' do
        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Appointment-Id']).to eq(appointment.id.to_s)
        expect(headers['X-Chatwoot-Appointment-Status']).to eq('confirmed')
        expect(headers['X-Chatwoot-Appointment-Starts-At']).to eq('2026-03-29T10:00:00Z')
      end

      it 'prefers prompt_context metadata when present' do
        state[:prompt_context] = {
          contact: {
            id: contact.id,
            phone_number: '+1987654321'
          }
        }

        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Contact-Id']).to eq(contact.id.to_s)
        expect(headers['X-Chatwoot-Contact-Phone']).to eq('+1987654321')
        expect(headers['X-Chatwoot-Contact-Email']).to be_nil
      end

      it 'prefers filtered appointment metadata from prompt_context when present' do
        state[:prompt_context] = {
          appointment: {
            id: appointment.id
          }
        }

        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Appointment-Id']).to eq(appointment.id.to_s)
        expect(headers['X-Chatwoot-Appointment-Status']).to be_nil
        expect(headers['X-Chatwoot-Appointment-Starts-At']).to be_nil
      end

      it 'prefers filtered deal and task metadata from prompt_context when present' do
        state[:prompt_context] = {
          deal: {
            id: deal.id
          },
          task: {
            id: task.id
          }
        }

        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Deal-Id']).to eq(deal.id.to_s)
        expect(headers['X-Chatwoot-Deal-Title']).to be_nil
        expect(headers['X-Chatwoot-Deal-Stage']).to be_nil
        expect(headers['X-Chatwoot-Task-Id']).to eq(task.id.to_s)
        expect(headers['X-Chatwoot-Task-Title']).to be_nil
        expect(headers['X-Chatwoot-Task-Status']).to be_nil
      end

      it 'includes contact inbox verification metadata when present' do
        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Contact-Inbox-Id']).to eq(conversation.contact_inbox.id.to_s)
        expect(headers['X-Chatwoot-Contact-Inbox-Verified']).to eq(conversation.contact_inbox.hmac_verified.to_s)
      end

      it 'handles missing conversation gracefully' do
        state[:conversation] = nil

        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Conversation-Id']).to be_nil
        expect(headers['X-Chatwoot-Conversation-Display-Id']).to be_nil
        expect(headers['X-Chatwoot-Account-Id']).to eq(account.id.to_s)
      end

      it 'handles missing contact gracefully' do
        state[:contact] = nil

        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Contact-Id']).to be_nil
        expect(headers['X-Chatwoot-Contact-Email']).to be_nil
        expect(headers['X-Chatwoot-Account-Id']).to eq(account.id.to_s)
      end

      it 'handles missing contact inbox gracefully' do
        state[:contact_inbox] = nil

        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Contact-Inbox-Id']).to be_nil
        expect(headers['X-Chatwoot-Contact-Inbox-Verified']).to eq('false')
      end

      it 'handles empty state' do
        headers = tool.build_metadata_headers({})

        expect(headers).to be_a(Hash)
        expect(headers['X-Chatwoot-Tool-Slug']).to eq('custom_test_tool')
        expect(headers['X-Chatwoot-Contact-Inbox-Verified']).to eq('false')
      end

      it 'omits contact email header when email is blank' do
        state[:contact][:email] = ''

        headers = tool.build_metadata_headers(state)

        expect(headers).not_to have_key('X-Chatwoot-Contact-Email')
      end

      it 'omits contact phone header when phone number is blank' do
        state[:contact][:phone_number] = ''

        headers = tool.build_metadata_headers(state)

        expect(headers).not_to have_key('X-Chatwoot-Contact-Phone')
      end

      it 'includes contact inbox verified header when false' do
        state[:contact_inbox][:hmac_verified] = false

        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Contact-Inbox-Verified']).to eq('false')
      end

      it 'defaults contact inbox verified header to false when value is nil' do
        state[:contact_inbox][:hmac_verified] = nil

        headers = tool.build_metadata_headers(state)

        expect(headers['X-Chatwoot-Contact-Inbox-Verified']).to eq('false')
      end
    end

    describe '#to_tool_metadata' do
      it 'returns tool metadata hash with custom flag' do
        tool = create(:captain_custom_tool, account: account,
                                            slug: 'custom_test-tool',
                                            title: 'Test Tool',
                                            description: 'A test tool')

        metadata = tool.to_tool_metadata
        expect(metadata).to eq({
                                 id: 'custom_test-tool',
                                 title: 'Test Tool',
                                 description: 'A test tool',
                                 group_name: nil,
                                 custom: true
                               })
      end
    end

    describe '#tool' do
      let(:assistant) { create(:captain_assistant, account: account) }

      it 'returns HttpTool instance' do
        tool = create(:captain_custom_tool, account: account)

        tool_instance = tool.tool(assistant)
        expect(tool_instance).to be_a(Captain::Tools::HttpTool)
      end

      it 'sets description on the tool class' do
        tool = create(:captain_custom_tool, account: account, description: 'Fetches order data')

        tool_instance = tool.tool(assistant)
        expect(tool_instance.description).to eq('Fetches order data')
      end

      it 'sets parameters on the tool class' do
        tool = create(:captain_custom_tool, :with_params, account: account)

        tool_instance = tool.tool(assistant)
        params = tool_instance.parameters

        expect(params.keys).to contain_exactly(:order_id, :include_details)
        expect(params[:order_id].name).to eq(:order_id)
        expect(params[:order_id].type).to eq('string')
        expect(params[:order_id].description).to eq('The order ID')
        expect(params[:order_id].required).to be true

        expect(params[:include_details].name).to eq(:include_details)
        expect(params[:include_details].required).to be false
      end

      it 'treats agent parameters without an explicit required flag as optional' do
        tool = create(:captain_custom_tool, account: account, param_schema: [
                        {
                          'name' => 'order_id',
                          'type' => 'string',
                          'description' => 'The order ID',
                          'source' => 'agent'
                        }
                      ])

        tool_instance = tool.tool(assistant)

        expect(tool_instance.parameters[:order_id].required).to be(false)
        expect(tool.parameter_definitions.first['required']).to be(false)
      end

      it 'works with empty param_schema' do
        tool = create(:captain_custom_tool, account: account, param_schema: [])

        tool_instance = tool.tool(assistant)
        expect(tool_instance.parameters).to be_empty
      end
    end

    describe '#copilot_tool' do
      let(:assistant) { create(:captain_assistant, account: account) }

      it 'returns the native copilot custom http tool wrapper' do
        tool = create(:captain_custom_tool, account: account)

        tool_instance = tool.copilot_tool(assistant)

        expect(tool_instance).to be_a(Captain::Tools::Copilot::CustomHttpTool)
        expect(tool_instance.name).to eq(tool.slug)
      end
    end
  end
end
